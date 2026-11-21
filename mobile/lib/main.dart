import 'dart:convert';
import 'room.dart';
import 'study_widgets.dart';
import 'campus_style.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const plum = Color(0xFF65356F);
const lavender = Color(0xFFA88BDB);
const cream = Color(0xFFFFF8FB);
const packagedServer = String.fromEnvironment('API_BASE_URL', defaultValue: 'https://campusvibe-monu-pilot.onrender.com');
String api = packagedServer;
String httpsOrigin(String value) {
  final u = Uri.tryParse(value.trim());
  if (u == null ||
      u.scheme != 'https' ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment ||
      (u.path.isNotEmpty && u.path != '/'))
    throw const FormatException(
        'Enter the public HTTPS address supplied by your campus.');
  return u.origin;
}

Future<Map<String, dynamic>> serverConfig(String base) async {
  final r = await http
      .get(Uri.parse('$base/mobile/config'))
      .timeout(const Duration(seconds: 75));
  if (r.statusCode != 200)
    throw const FormatException(
        'Campus server unavailable. Try again after a minute.');
  final v = jsonDecode(r.body);
  if (v is! Map<String, dynamic> ||
      v['app'] != 'CampusVibe' ||
      v['version'] != 3)
    throw const FormatException('This server does not support CampusVibe 0.3.');
  return v;
}

const storage = FlutterSecureStorage();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final previous = await storage.read(key: 'pilot');
  api = httpsOrigin(packagedServer);
  if (previous != null && previous != api || previous == null) {
    await storage.deleteAll();
  }
  if (api.isNotEmpty) await storage.write(key: 'pilot', value: api);
  final token = await storage.read(key: 'token');
  final welcomed = await storage.read(key: 'welcomed') == 'yes';
  runApp(CampusVibe(initialToken: token, showWelcome: !welcomed));
}

class CampusVibe extends StatelessWidget {
  final String? initialToken;
  final bool showWelcome;
  const CampusVibe({super.key, this.initialToken, this.showWelcome = false});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CampusVibe',
        debugShowCheckedModeBanner: false,
        theme: campusTheme(Brightness.light),
        home: initialToken == null
            ? (showWelcome ? Builder(builder:(ctx)=>WelcomePage(onContinue:() async {
                  await storage.write(key:"welcomed",value:"yes");
                  if(ctx.mounted)Navigator.pushReplacement(ctx,MaterialPageRoute(builder:(_)=>const EntryPage()));
                })) : const EntryPage())
            : HomePage(token: initialToken!),
        darkTheme: campusTheme(Brightness.dark),
      );
}

class EntryPage extends StatefulWidget {
  const EntryPage({super.key});
  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> {
  bool busy = false;
  String error = '';
  String googleId = '';

  final email = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  bool registering = false;
  bool hidePassword=true;

  @override
  void initState() {
    super.initState();
    if (api.isNotEmpty) configure();
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> configure() async {
    try {
      final config = await serverConfig(api);
      if (mounted) setState(() => googleId = config['google_client_id'] as String? ?? '');
    } catch (_) {
      // Email sign-in works independently of Google provider discovery.
    }
  }

  Future<void> withEmail() async {
    if (busy) return;
    final address = email.text.trim();
    final secret = password.text;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(address) ||
        secret.isEmpty || (registering && (name.text.trim().length < 2 || secret.length < 10))) {
      setState(() => error = registering
          ? 'Enter your name, email and a password of at least 10 characters.'
          : 'Enter your email and password.');
      return;
    }
    setState(() { busy = true; error = ''; });
    final credentials = {'email': address, 'password': secret};
    Future<http.Response> post(String path, Map<String, String> body) =>
        http.post(Uri.parse('$api/auth/$path'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body)).timeout(const Duration(seconds: 90));
    try {
      if (registering) {
        final created = await post('register', {...credentials, 'name': name.text.trim()});
        if (created.statusCode != 201) {
          if (mounted) setState(() => error = created.statusCode == 409 ?
            'An account with this email already exists. Sign in below.' :
            'Could not create the account. Check your details and try again.');
          return;
        }
        if (!mounted) return;
        setState(() => registering = false);
      }
      final result = await post('login', credentials);
      if (result.statusCode != 200) {
        if (mounted) setState(() => error = result.statusCode == 401
            ? 'Email or password is incorrect.' : 'Sign-in unavailable. Try again shortly.');
        return;
      }
      final token = jsonDecode(result.body)['access_token'] as String;
      await storage.write(key: 'token', value: token);
      if (mounted) Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => HomePage(token: token)));
    } catch (_) {
      if (mounted) setState(() => error = 'Could not reach CampusVibe. Check your internet and retry.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> withGoogle() async {
    if (googleId.isEmpty || busy) return;
    setState(() { busy = true; error = ''; });
    try {
      final google = GoogleSignIn(serverClientId: googleId);
      final account = await google.signIn();
      if (account == null) return;
      final idToken = (await account.authentication).idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const FormatException('Google did not return an ID token.');
      }
      final response = await http.post(
        Uri.parse('$api/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': idToken}),
      ).timeout(const Duration(seconds: 75));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200 || data is! Map<String, dynamic> ||
          data['access_token'] is! String) {
        throw const FormatException('Campus server rejected Google login.');
      }
      final token = data['access_token'] as String;
      await storage.write(key: 'token', value: token);
      if (mounted) {
        Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => HomePage(token: token)));
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Google sign-in failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ClipRRect(borderRadius:BorderRadius.circular(18),child:Image.asset('assets/waves.webp',width:420,height:80,fit:BoxFit.cover)),
              const SizedBox(height:18),
              Align(alignment:Alignment.centerLeft,child:Text(registering?'Create your account':'Welcome back 👋',style:Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight:FontWeight.w800))),
              const SizedBox(height:4),
              Align(alignment:Alignment.centerLeft,child:Text(registering?'Join your campus community':'Sign in to your CampusVibe account')),
              const SizedBox(height:18),
              SizedBox(width:double.infinity,child:SegmentedButton<bool>(showSelectedIcon:false,segments:const [
                ButtonSegment(value:false,label:Text('Login')),ButtonSegment(value:true,label:Text('Sign Up'))],
                selected:{registering},onSelectionChanged:busy?null:(v)=>setState((){registering=v.first;error='';}))),
              const SizedBox(height:20),
              if (registering) ...[
                TextField(controller: name, enabled: !busy, maxLength: 120,
                    decoration: const InputDecoration(labelText: 'Full name')),
                const SizedBox(height: 12),
              ],
              TextField(controller: email, enabled: !busy, autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline))),
              const SizedBox(height: 12),
              TextField(controller: password, enabled: !busy, obscureText: hidePassword,
                  maxLength: registering ? 128 : null,
                  onSubmitted: (_) => withEmail(),
                  decoration: InputDecoration(labelText: 'Password', prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon:IconButton(tooltip:hidePassword?'Show password':'Hide password',icon:Icon(hidePassword?Icons.visibility_outlined:Icons.visibility_off_outlined),onPressed:()=>setState(()=>hidePassword=!hidePassword)),
                    helperText: registering ? 'Use at least 10 characters' : null)),
              if (error.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: busy ? null : withEmail,
                child: Text(busy ? 'Please wait…' : registering ? 'Create account' : 'Sign in with email'))),
              TextButton(onPressed: busy ? null : () => setState(() {
                registering = !registering; error = '';
              }), child: Text(registering ? 'Already registered? Sign in' : 'New here? Create an account')),
              if (googleId.isNotEmpty) OutlinedButton.icon(onPressed: busy ? null : withGoogle,
                icon: const Icon(Icons.account_circle_outlined), label: const Text('Sign in with Google')),
            ]),
          ),
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  final String token;
  const HomePage({super.key, required this.token});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  int discoveryMode=0;
  Map<String, dynamic>? profile;
  final college = TextEditingController();
  final branch = TextEditingController();
  final bio = TextEditingController();
  String message = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await http.get(Uri.parse('$api/profile/me'), headers: {
        'Authorization': 'Bearer ${widget.token}'
      }).timeout(const Duration(seconds: 10));
      if (r.statusCode == 401) {
        await logout();
        return;
      }
      if (r.statusCode != 200) throw Exception('Profile unavailable');
      await storage.write(key: 'profile', value: r.body);
    } catch (e) {
      if (mounted)
        setState(
            () => message = 'Offline. Showing saved profile when available.');
    }
    final saved = await storage.read(key: 'profile');
    if (saved != null && mounted) {
      final p = jsonDecode(saved);
      setState(() {
        profile = p;
        college.text = p['college'] ?? '';
        branch.text = p['branch'] ?? '';
        bio.text = p['bio'] ?? '';
      });
    }
  }

  Future<void> logout() async {
    await storage.deleteAll();
    await storage.write(key: "pilot", value: api);
    if (mounted)
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const EntryPage()));
  }

  Future<void> deleteAccount() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Permanently delete your account?'),
                content: const Text(
                    'This removes your profile, connections and conversations.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(d, true),
                      child: const Text('Delete account'))
                ]));
    if (ok != true) return;
    try {
      final r = await http.delete(Uri.parse('$api/account'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      if (r.statusCode != 200) throw Exception(r.body);
      await logout();
    } catch (e) {
      notify('$e');
    }
  }

  Future<void> studyAssistant() async {
    final prompt = TextEditingController();
    String answer = '';
    bool working = false;
    await showDialog(
        context: context,
        builder: (d) => StatefulBuilder(
            builder: (d, update) => AlertDialog(
                    title: const Text('AI study assistant'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      Image.asset('assets/bot.webp',height:88),
                      const Text('Your personal study companion',style:TextStyle(fontWeight:FontWeight.w700)),
                      Wrap(spacing:6,children:[for(final topic in ['Explain a concept','Create a quiz','Summarize notes']) ActionChip(label:Text(topic),onPressed:()=>prompt.value=TextEditingValue(text:'$topic: ',selection:TextSelection.collapsed(offset:topic.length+2)))]),
                      TextField(
                          controller: prompt,
                          maxLines: 3,
                          maxLength: 3000,
                          decoration: const InputDecoration(
                              labelText: 'Question or notes to share with AI')),
                      if (answer.isNotEmpty) SelectableText(answer)
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d),
                          child: const Text('Close')),
                      FilledButton(
                          onPressed: working
                              ? null
                              : () async {
                                  update(() => working = true);
                                  try {
                                    final r = await http.post(
                                        Uri.parse('$api/study/assistant'),
                                        headers: {
                                          'Authorization':
                                              'Bearer ${widget.token}',
                                          'Content-Type': 'application/json'
                                        },
                                        body: jsonEncode(
                                            {'question': prompt.text}));
                                    final data = jsonDecode(r.body);
                                    answer = r.statusCode == 200
                                        ? data['answer']
                                        : '${data["detail"]}';
                                  } catch (e) {
                                    answer = 'Provider unavailable';
                                  } finally {
                                    if (d.mounted)
                                      update(() => working = false);
                                  }
                                },
                          child:
                              Text(working ? 'Thinking…' : 'Send to provider'))
                    ])));
  }

  Future<void> privateNote() async {
    final ctl =
        TextEditingController(text: await storage.read(key: 'note') ?? '');
    if (!mounted) return;
    await showDialog(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Private study note'),
                content:
                    TextField(controller: ctl, maxLines: 6, maxLength: 6000),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        await storage.write(key: 'note', value: ctl.text);
                        if (d.mounted) Navigator.pop(d);
                      },
                      child: const Text('Save on phone'))
                ]));
  }

  Future<void> emailCode() async {
    final code = TextEditingController();
    await showDialog(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Verify email'),
                content: TextField(
                    controller: code,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Six-digit code')),
                actions: [
                  TextButton(
                      onPressed: () async {
                        try {
                          await postData('/email/send', {});
                          notify(
                              'Check your email for the verification code.');
                        } catch (e) {
                          notify('$e');
                        }
                      },
                      child: const Text('Send code')),
                  FilledButton(
                      onPressed: () async {
                        try {
                          await postData(
                              '/email/confirm', {'code': code.text.trim()});
                          if (d.mounted) Navigator.pop(d);
                          await load();
                        } catch (e) {
                          notify('$e');
                        }
                      },
                      child: const Text('Verify'))
                ]));
  }

  Future<void> openEvents() async {
    try {
      final rows = await getData('/events') as List;
      if (!mounted) return;
      final create = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Campus events'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (rows.isEmpty) const Text('No upcoming meetups.'),
                    for (final e in rows)
                      Card(child:ListTile(leading:const Icon(Icons.calendar_today_outlined),title:Text(e['title']),
                        subtitle:Text(e['place']),trailing:const Icon(Icons.chevron_right),onTap:() async {
                          final going=await Navigator.push<bool>(d,MaterialPageRoute(builder:(page)=>Scaffold(
                            appBar:AppBar(title:const Text('Event details')),
                            body:ListView(padding:const EdgeInsets.all(20),children:[
                              ClipRRect(borderRadius:BorderRadius.circular(20),child:Image.asset('assets/campus_evening.webp',height:180,fit:BoxFit.cover)),
                              const SizedBox(height:18),Text(e['title'],style:Theme.of(page).textTheme.headlineMedium),
                              ListTile(leading:const Icon(Icons.schedule),title:Text(DateTime.parse(e['starts']).toLocal().toString().split('.').first)),
                              ListTile(leading:const Icon(Icons.location_on_outlined),title:Text(e['place'])),
                              FilledButton(onPressed:e['going']==true?null:() async{
                                try{await postData('/events/${e["id"]}/rsvp',{});if(page.mounted)Navigator.pop(page,true);}
                                catch(err){notify('$err');}
                              },child:Text(e['going']==true?'Going':'RSVP now'))
                            ]))));
                          if(going==true && d.mounted){Navigator.pop(d);notify('RSVP saved');}
                        }))
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Close')),
                    FilledButton(
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('New meetup'))
                  ]));
      if (create != true || !mounted) return;
      final title = TextEditingController(),
          place = TextEditingController(),
          time = TextEditingController();
      await showDialog(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Plan campus meetup'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: title,
                        decoration: const InputDecoration(labelText: 'Title')),
                    TextField(
                        controller: place,
                        decoration: const InputDecoration(
                            labelText: 'Public campus location')),
                    TextField(
                        controller: time,
                        decoration: const InputDecoration(
                            labelText: 'Local time YYYY-MM-DD HH:MM'))
                  ])),
                  actions: [
                    FilledButton(
                        onPressed: () async {
                          try {
                            await postData('/events', {
                              'title': title.text,
                              'place': place.text,
                              'starts': DateTime.parse(time.text)
                                  .toUtc()
                                  .toIso8601String()
                            });
                            if (d.mounted) Navigator.pop(d);
                            notify('Meetup created');
                          } catch (e) {
                            notify('$e');
                          }
                        },
                        child: const Text('Create'))
                  ]));
    } catch (e) {
      notify('$e');
    }
  }

  Future<void> preferences() async {
    final v = Map<String, dynamic>.from(profile?['verification'] ?? {});
    final dob = TextEditingController(text: v['dob'] ?? '');
    final tags =
        TextEditingController(text: (profile?['interests'] ?? []).join(', '));
    String gender = v['gender'] ?? 'Prefer not to say';
    final pref = Set<String>.from(v['preferences'] ?? []);
    bool dating = v['dating'] ?? false;
    await showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('Verify your college'),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Center(child:Image.asset('assets/college.webp',height:90)),
                          Text(v['college_ok'] == true
                              ? 'Enrollment verified'
                              : 'Save your college in Profile, then submit for moderator review.'),
                          TextField(
                              controller: dob,
                              decoration: const InputDecoration(
                                  labelText: 'Date of birth (YYYY-MM-DD)')),
                          TextField(
                              controller: tags,
                              decoration: const InputDecoration(
                                  labelText: 'Interests, separated by commas')),
                          DropdownButton<String>(
                              value: gender,
                              items: [
                                'Man',
                                'Woman',
                                'Non-binary',
                                'Self-describe',
                                'Prefer not to say'
                              ]
                                  .map((g) => DropdownMenuItem(
                                      value: g, child: Text(g)))
                                  .toList(),
                              onChanged: (g) => update(() => gender = g!)),
                          const Text('Dating preferences'),
                          Wrap(children: [
                            for (final g in [
                              'Man',
                              'Woman',
                              'Non-binary',
                              'Self-describe',
                              'Everyone'
                            ])
                              FilterChip(
                                  label: Text(g),
                                  selected: pref.contains(g),
                                  onSelected: (on) => update(() {
                                        if (on) {
                                          pref.add(g);
                                        } else {
                                          pref.remove(g);
                                        }
                                      }))
                          ]),
                          SwitchListTile(
                              title: const Text('Opt into dating'),
                              value: dating,
                              onChanged: v['adult_checked'] == true
                                  ? (b) => update(() => dating = b)
                                  : null)
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              for (final entry in {
                                '/profile/preferences': {
                                  'dob': dob.text.trim(),
                                  'gender': gender,
                                  'preferences': pref.toList(),
                                  'dating': dating
                                },
                                '/interests': {'labels': tags.text.split(',')}
                              }.entries) {
                                final r = await http.put(
                                    Uri.parse('$api${entry.key}'),
                                    headers: {
                                      'Authorization': 'Bearer ${widget.token}',
                                      'Content-Type': 'application/json'
                                    },
                                    body: jsonEncode(entry.value));
                                if (r.statusCode != 200)
                                  throw Exception(r.body);
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                              await load();
                              notify('Preferences saved');
                            } catch (e) {
                              notify('$e');
                            }
                          },
                          child: const Text('Save'))
                    ])));
  }

  Future<void> save() async {
    final r = await http.patch(Uri.parse('$api/profile/me'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(
            {'college': college.text, 'branch': branch.text, 'bio': bio.text}));
    setState(() => message = r.statusCode == 200
        ? 'Profile saved successfully'
        : 'Save failed: ${r.body}');
    if (r.statusCode == 200) load();
  }

  Future<dynamic> getData(String path) async {
    final canCache = path == '/books' || path == '/connections';
    http.Response r;
    try {
      r = await http.get(Uri.parse('$api$path'), headers: {
        'Authorization': 'Bearer ${widget.token}'
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (canCache) {
        final old = await storage.read(key: path);
        if (old != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            notify('Offline · saved results');
          });
          return jsonDecode(old);
        }
      }
      rethrow;
    }
    if (r.statusCode != 200) throw Exception(r.body);
    if (canCache) await storage.write(key: path, value: r.body);
    return jsonDecode(r.body);
  }

  Future<void> postData(String path, Map<String, dynamic> data) async {
    final r = await http.post(Uri.parse('$api$path'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(data));
    if (r.statusCode < 200 || r.statusCode >= 300) throw Exception(r.body);
  }

  void notify(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> addBook() async {
    final title = TextEditingController(),
        author = TextEditingController(),
        price = TextEditingController(text: '0');
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('List a book'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: title,
                      decoration:
                          const InputDecoration(labelText: 'Book title')),
                  TextField(
                      controller: author,
                      decoration: const InputDecoration(labelText: 'Author')),
                  TextField(
                      controller: price,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Price ₹'))
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        try {
                          await postData('/books', {
                            'title': title.text,
                            'author': author.text,
                            'price': int.tryParse(price.text) ?? 0
                          });
                          if (ctx.mounted) Navigator.pop(ctx);
                          setState(() {});
                          notify('Book listed');
                        } catch (e) {
                          notify('$e');
                        }
                      },
                      child: const Text('Publish'))
                ]));
  }

  Future<void> sendRequest(int id, String kind) async {
    try {
      await postData('/connections', {'receiver_id': id, 'kind': kind});
      notify('Request sent');
    } catch (e) {
      notify('$e');
    }
  }

  Widget tile(IconData icon, String title, String subtitle,
          {VoidCallback? action}) =>
      Card(
          child: ListTile(
              onTap: action,
              leading: CircleAvatar(
                  backgroundColor: const Color(0xFFEBD8F3),
                  child: Icon(icon, color: plum)),
              title: Text(title),
              subtitle: Text(subtitle),
              trailing: action == null
                  ? null
                  : IconButton(
                      onPressed: action,
                      icon: const Icon(Icons.arrow_forward_ios, size: 17))));
  Widget discoverPage() => DefaultTabController(
      length: 3,initialIndex:discoveryMode,
      child: Column(children: [
        Padding(padding:const EdgeInsets.symmetric(vertical:8),child:DecoratedBox(decoration:BoxDecoration(color:Theme.of(context).colorScheme.surfaceContainerHigh,borderRadius:BorderRadius.circular(30)),child:const TabBar(tabs: [
          Tab(text: 'Study'),
          Tab(text: 'Friends'),
          Tab(text: 'Dating')
        ]))),
        Expanded(
            child: TabBarView(children: [
          for (final mode in ['study', 'friend', 'dating'])
            if(mode=='study' && profile?['study_visible']!=true) Center(child:FilledButton.icon(onPressed:editStudy,icon:const Icon(Icons.school_outlined),label:const Text('Set up study profile'))) else FutureBuilder<dynamic>(
                future: getData('/discover?kind=$mode'),
                builder: (context, snapshot) {
                  if (!snapshot.hasData)
                    return Center(
                        child: Text(snapshot.hasError
                            ? 'Unable to load students: ${snapshot.error}'
                            : 'Loading...'));
                  final students = snapshot.data as List;
                  if (students.isEmpty)
                    return const Center(
                        child: Text(
                            'No matching profiles here yet. Invite a classmate from your college.'));
                  return ListView.builder(
                      itemCount: students.length,
                      itemBuilder: (context, i) {
                        final p = students[i];
                        final shared = List<String>.from(p['shared_interests'] ?? []);
                        return Card(clipBehavior:Clip.antiAlias,margin:const EdgeInsets.symmetric(vertical:8,horizontal:4),
                          child:Padding(padding:const EdgeInsets.all(18),child:Column(
                            crossAxisAlignment:CrossAxisAlignment.start,children:[
                              ClipRRect(borderRadius:BorderRadius.circular(14),child:portrait(p,mode)),
                              const SizedBox(height:12),
                              Row(children:[CircleAvatar(radius:24,backgroundColor:const Color(0xffedd9f1),
                                child:Text((p['name'] as String? ?? '').characters.take(1).toString(),style:const TextStyle(color:plum))),
                                const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                                  Text(p['name'] ?? '',style:Theme.of(context).textTheme.titleLarge),
                                  Text([p['college'],p['branch']].whereType<String>().where((s)=>s.isNotEmpty).join(' · '))
                                ]))]),
                              if((p['bio'] ?? '').toString().isNotEmpty) Padding(padding:const EdgeInsets.only(top:12),child:Text(p['bio'])),
                              if(shared.isNotEmpty) Padding(padding:const EdgeInsets.only(top:10),child:Wrap(spacing:6,children:[for(final tag in shared) Chip(label:Text(tag))])),
                              const SizedBox(height:10),Align(alignment:Alignment.centerRight,child:FilledButton.tonalIcon(
                                onPressed:()=>sendRequest(p['id'],mode),icon:const Icon(Icons.person_add_alt_1),label:const Text('Send request')))
                            ])));

                      });
                })
        ]))
      ]));
  Widget booksPage() => FutureBuilder<dynamic>(
      future: getData('/books'),
      builder: (context, s) {
        if (!s.hasData)
          return Center(
              child: Text(
                  s.hasError ? 'Unable to load books' : 'Loading books...'));
        final books = s.data as List;
        return SearchableCampusList(rows:books,hint:'Search books, authors…',fields:const ['title','author','condition'],
          filters:const ['Free','For sale'],matches:(b,f)=>f=='Free'?b['price']==0:b['price']>0,
          empty:'No books listed yet',action:FilledButton.icon(onPressed:addBook,icon:const Icon(Icons.add),label:const Text('List a book')),item:(b)=>
            tile(Icons.menu_book, b['title'], '${b['author']} • ₹${b['price']}',
                action: () => showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                            title: Text(b['title']),
                            content: Text('Reserve this book?'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancel')),
                              FilledButton(
                                  onPressed: () async {
                                    try {
                                      await postData(
                                          '/books/${b['id']}/reserve', {});
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      setState(() {});
                                      notify('Reserved');
                                    } catch (e) {
                                      notify('$e');
                                    }
                                  },
                                  child: const Text('Reserve'))
                            ]))));
      });
  Widget chatsPage() => FutureBuilder<dynamic>(
      future: getData('/connections'),
      builder: (context, s) {
        if (!s.hasData)
          return Center(
              child: Text(
                  s.hasError ? 'Unable to load connections' : 'Loading...'));
        final connections = s.data as List;
        return SearchableCampusList(rows:connections,hint:'Search conversations…',fields:const ['peer_name','kind'],
          filters:const ['Accepted','Pending'],matches:(c,f)=>c['status']==f.toLowerCase(),
          empty:'Your study requests and conversations will appear here.',item:(c)=>
            tile(Icons.chat, '${c['peer_name']} · ${c['kind']}',
                'Status: ${c['status']}', action: () async {
              if (c['status'] == 'pending' &&
                  c['receiver_id'] == profile?['id']) {
                try {
                  await postData('/connections/${c['id']}/accept', {});
                  setState(() {});
                } catch (e) {
                  notify('$e');
                }
              } else if (c['status'] == 'accepted') {
                final peer = c['sender_id'] == profile?['id']
                    ? c['receiver_id']
                    : c['sender_id'];
                if (mounted)
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              ChatPage(token: widget.token, peerId: peer)));
              }
            }));
      });
  Future<void> choosePortrait() async {
    try {
      final bytes=await const MethodChannel('campusvibe/files').invokeMethod<Uint8List>('pickPhoto');
      if(bytes==null)return;
      final req=http.MultipartRequest('PUT',Uri.parse('$api/profile/photo'))
        ..headers['Authorization']='Bearer ${widget.token}'
        ..files.add(http.MultipartFile.fromBytes('file',bytes,filename:'portrait'));
      final result=await req.send().timeout(const Duration(seconds:75));
      if(result.statusCode!=200){notify('Choose a JPEG or PNG up to 4 MB.');return;}
      await load();
    }catch(_){notify('Could not save the photo. Please try again.');}
  }

  Widget portrait(Map person,String kind,{double height=210}){
    final fallback=Container(height:height,alignment:Alignment.center,decoration:const BoxDecoration(
      gradient:LinearGradient(colors:[Color(0xffe9ceec),Color(0xffc7b3dc)])),child:Text(
        (person['name'] as String? ?? '').characters.take(1).toString(),
        style:TextStyle(fontSize:height*.4,fontWeight:FontWeight.bold,color:plum)));
    if(person['photo_version']==null)return fallback;
    return Image.network('$api/profile/photo/${person["id"]}?kind=$kind&v=${person["photo_version"]}',
      headers:{'Authorization':'Bearer ${widget.token}'},fit:BoxFit.cover,height:height,width:double.infinity,
      errorBuilder:(_,__,___)=>fallback);
  }

  Future<void> editStudy() async {
    if(profile==null){await load();if(!mounted || profile==null){notify('Profile unavailable. Check your connection.');return;}}
    final saved = await Navigator.push<bool>(context,MaterialPageRoute(builder:(_)=>StudyProfileEditor(
      profile:profile!,submit:(college,labels,visible) async {
        final r=await http.put(Uri.parse('$api/profile/study'),headers:{
          'Authorization':'Bearer ${widget.token}','Content-Type':'application/json'
        },body:jsonEncode({'college':college,'labels':labels,'visible':visible})).timeout(const Duration(seconds:75));
        if(r.statusCode!=200) throw Exception('Save failed');
      })));
    if(saved==true && mounted){await load();if(mounted)setState((){discoveryMode=0;tab=profile?['study_visible']==true?1:4;});}
  }
  void findStudy() {
    if(profile?['study_visible']==true){setState((){discoveryMode=0;tab=1;});}else{editStudy();}
  }

  Widget homePage() => ListView(children: [
        Text('Hi, ${profile?['name'] ?? 'Student'} 👋',
            style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 15),
        Card(color:const Color(0xffeed7f1),clipBehavior:Clip.antiAlias,child:Row(children:[
          Expanded(child:Padding(padding:const EdgeInsets.fromLTRB(16,18,4,18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Study Together',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800,color:plum)),
            const Text('Find people preparing for the same subjects.',style:TextStyle(color:plum)),
            const SizedBox(height:8),FilledButton(onPressed:findStudy,child:const Text('Find study partner'))
          ]))),Expanded(child:Image.asset('assets/campus_pair.webp',fit:BoxFit.cover,height:156))])),
        const SizedBox(height:18),
        GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:4,childAspectRatio:0.93,children:[
          for(final item in <(IconData,String,VoidCallback)>[
            (Icons.school_outlined,'Study',findStudy),
            (Icons.favorite_outline,'Dating',()=>setState((){discoveryMode=2;tab=1;})),
            (Icons.people_outline,'Friends',()=>setState((){discoveryMode=1;tab=1;})),
            (Icons.menu_book_outlined,'Books',()=>setState(()=>tab=2)),

            (Icons.groups_outlined,'Circles',()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CommunitiesPage(token:widget.token)))),
            (Icons.event_outlined,'Events',openEvents),
            (Icons.auto_awesome,'Study AI',studyAssistant),(Icons.more_horiz,'Profile',()=>setState(()=>tab=4))])
            Card(child:InkWell(onTap:item.$3,child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
              Icon(item.$1,color:lavender),const SizedBox(height:6),Text(item.$2)])))
        ]),
        const SizedBox(height:16),
        tile(Icons.event_outlined,'Upcoming on campus','See events and RSVP',action:openEvents),
        tile(Icons.badge_outlined,'Your study profile',(profile?['interests'] as List? ?? []).join(' · '),action:editStudy)
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          leading:tab==0?Padding(padding:const EdgeInsets.all(10),child:Image.asset('assets/mark.png')):null,
          title: Text(['CampusVibe','Discover','Books','Chats','Profile'][tab], style: const TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(onPressed: logout, icon: const Icon(Icons.logout))
          ]),
      body: Padding(
          padding: const EdgeInsets.all(12),
          child: tab == 0
              ? homePage()
              : tab == 1
                  ? discoverPage()
                  : tab == 2
                      ? booksPage()
                      : tab == 3
                          ? chatsPage()
                          : ListView(children: [
                              Center(child:Column(children:[ClipOval(child:SizedBox(width:96,height:96,child:portrait(profile ?? {},'study',height:96))),
                                TextButton.icon(onPressed:choosePortrait,icon:const Icon(Icons.photo_camera_outlined),label:const Text('Change photo'))])),
                              Text(profile?['name'] ?? 'Your profile',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium),
                              Text(profile?['email'] ?? ''),
                              const SizedBox(height: 18),
                              TextField(
                                  controller: college,
                                  decoration: const InputDecoration(
                                      labelText: 'College')),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: branch,
                                  decoration: const InputDecoration(
                                      labelText: 'Branch')),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: bio,
                                  maxLines: 3,
                                  decoration:
                                      const InputDecoration(labelText: 'Bio')),
                              const SizedBox(height: 16),
                              FilledButton(
                                  onPressed: save,
                                  child: const Text('Save profile')),
                              OutlinedButton.icon(onPressed:editStudy,icon:const Icon(Icons.school_outlined),label:const Text('Edit study interests and visibility')),
                              if (profile?['email_verified'] != true && profile?['email_delivery']==true)
                                OutlinedButton(
                                    onPressed: emailCode,
                                    child: const Text('Verify email')),
                              OutlinedButton(
                                  onPressed: () => preferences(),
                                  child: const Text(
                                      'Verification and preferences')),
                              OutlinedButton(
                                  onPressed: privateNote,
                                  child: const Text('Private study note')),
                              TextButton(
                                  onPressed: () async {
                                    try {
                                      final data =
                                          await getData('/account/export');
                                      await Clipboard.setData(ClipboardData(
                                          text: jsonEncode(data)));
                                      notify('Account export copied');
                                    } catch (e) {
                                      notify('$e');
                                    }
                                  },
                                  child: const Text('Export account data')),
                              TextButton(
                                  onPressed: deleteAccount,
                                  child: const Text('Delete account')),
                              Text(message)
                            ])),
      bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() => tab = v),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.explore_outlined), label: 'Discover'),
            NavigationDestination(
                icon: Icon(Icons.menu_book_outlined), label: 'Books'),
            NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
            NavigationDestination(
                icon: Icon(Icons.person_outline), label: 'Profile')
          ]));
}

class ChatPage extends StatefulWidget {
  final String token;
  final int peerId;
  const ChatPage({super.key, required this.token, required this.peerId});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController();
  List items = [];
  String error = '';
  bool busy = false;
  WebSocket? socket;
  int generation = 0;
  Map<String, String> get headers =>
      {'Authorization': 'Bearer ${widget.token}'};
  static const files = MethodChannel('campusvibe/files');
  @override
  void initState() {
    super.initState();
    listen();
  }

  Future<void> listen() async {
    final id = ++generation;
    final old = await storage.read(key: 'chat-${widget.peerId}');
    if (old != null && mounted) setState(() => items = jsonDecode(old));
    await socket?.close();
    try {
      final uri = Uri.parse(api).replace(
          scheme: api.startsWith('https:') ? 'wss' : 'ws',
          path: '/live/${widget.peerId}');
      final channel = await WebSocket.connect(uri.toString(), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (!mounted || generation != id) {
        await channel.close();
        return;
      }
      socket = channel;
      await for (final payload in channel) {
        if (!mounted || id != generation) break;
        await storage.write(
            key: 'chat-${widget.peerId}', value: payload as String);
        if (!mounted) return;
        setState(() {
          items = jsonDecode(payload);
          error = '';
        });
      }
    } catch (e) {
      if (mounted && id == generation)
        setState(() => error = 'Chat disconnected. Tap refresh to reconnect.');
    }
  }

  Future<void> perform(Future<void> Function() fn) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    final r = await http.post(Uri.parse('$api/messages'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'receiver_id': widget.peerId, 'body': text}));
    if (r.statusCode != 201) throw Exception(r.body);
    input.clear();
  }

  Future<void> share() async {
    final bytes = await files.invokeMethod<Uint8List>('pick');
    if (bytes == null) return;
    final req =
        http.MultipartRequest('POST', Uri.parse('$api/files/${widget.peerId}'))
          ..headers.addAll(headers)
          ..files.add(http.MultipartFile.fromBytes('file', bytes,
              filename: 'study-resource'));
    final r = await req.send();
    if (r.statusCode != 201)
      throw Exception('Upload refused. Choose a JPEG, PNG or PDF up to 4 MB.');
  }

  Future<void> saveFile(dynamic m) async {
    final r =
        await http.get(Uri.parse('$api/files/${m["id"]}'), headers: headers);
    if (r.statusCode != 200) throw Exception('File unavailable');
    await files.invokeMethod('save', {'mime': m['mime'], 'bytes': r.bodyBytes});
  }

  @override
  void dispose() {
    generation++;
    socket?.close();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('Conversation'), actions: [
        IconButton(
            icon: const Icon(Icons.timer_outlined),
            tooltip: 'Focus together',
            onPressed: () => Navigator.push(
                c,
                MaterialPageRoute(
                    builder: (_) => StudyRoom(
                        base: api,
                        token: widget.token,
                        title: 'Shared study room',
                        id: widget.peerId)))),
        PopupMenuButton<String>(
            onSelected: (choice) async {
              final ctl = TextEditingController();
              final yes = await showDialog<bool>(
                  context: c,
                  builder: (d) => AlertDialog(
                          title: Text('$choice student?'),
                          content: choice == 'Report'
                              ? TextField(
                                  controller: ctl,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Reason (at least 5 characters)'))
                              : const Text(
                                  'This stops messages and connection requests.'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(d, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                onPressed: () => Navigator.pop(d, true),
                                child: Text(choice))
                          ]));
              if (yes != true) return;
              await perform(() async {
                final r = await http.post(
                    Uri.parse(choice == 'Block'
                        ? '$api/blocks/${widget.peerId}'
                        : '$api/reports'),
                    headers: {...headers, 'Content-Type': 'application/json'},
                    body: jsonEncode(choice == 'Block'
                        ? {}
                        : {'target_id': widget.peerId, 'reason': ctl.text}));
                if (r.statusCode >= 400) throw Exception(r.body);
                if (c.mounted) Navigator.pop(c);
              });
            },
            itemBuilder: (_) => ['Report', 'Block']
                .map((s) => PopupMenuItem(value: s, child: Text(s)))
                .toList()),
        IconButton(icon: const Icon(Icons.refresh), onPressed: listen)
      ]),
      body: SafeArea(
          child: Column(children: [
        if (error.isNotEmpty) Text(error),
        Expanded(
            child: ListView.builder(
                reverse: true,
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final m = items[items.length - 1 - i];
                  return Align(
                      alignment: m['sender_id'] == widget.peerId
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: m['mime'] == null
                                  ? Text(m['body'])
                                  : TextButton.icon(
                                      onPressed: () =>
                                          perform(() => saveFile(m)),
                                      icon: const Icon(Icons.download),
                                      label: Text(m['body'])))));
                })),
        Row(children: [
          IconButton(
              tooltip: 'Share photo or permitted notes',
              onPressed: busy ? null : () => perform(share),
              icon: const Icon(Icons.attach_file)),
          Expanded(
              child: TextField(
                  controller: input,
                  decoration: const InputDecoration(hintText: 'Message'))),
          IconButton(
              onPressed: busy ? null : () => perform(send),
              icon: const Icon(Icons.send))
        ])
      ])));
}

class CommunitiesPage extends StatefulWidget {
  final String token;
  const CommunitiesPage({super.key, required this.token});
  @override
  State<CommunitiesPage> createState() => _CommunitiesPageState();
}

class _CommunitiesPageState extends State<CommunitiesPage> {
  final name = TextEditingController();
  Future<http.Response> post(String path, Map<String, dynamic> data) =>
      http.post(Uri.parse('$api$path'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode(data));
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      body: FutureBuilder<http.Response>(
          future: http.get(Uri.parse('$api/communities'),
              headers: {'Authorization': 'Bearer ${widget.token}'}),
          builder: (context, s) {
            if (!s.hasData)
              return const Center(child: CircularProgressIndicator());
            if (s.data!.statusCode != 200)
              return const Center(child: Text('Could not load communities'));
            final items = jsonDecode(s.data!.body) as List;
            return ListView(children: [
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: name,
                            decoration: const InputDecoration(
                                labelText: 'New community name'))),
                    IconButton(
                        onPressed: () async {
                          if (name.text.trim().length < 3) return;
                          final r = await post(
                              '/communities', {'name': name.text.trim()});
                          if (r.statusCode == 201) {
                            name.clear();
                            setState(() {});
                          }
                        },
                        icon: const Icon(Icons.add))
                  ])),
              for (final c in items)
                Card(
                    child: ListTile(
                        leading:const CircleAvatar(child:Icon(Icons.groups_outlined)),
                        title: Text(c['name']),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => StudyRoom(
                                    base: api,
                                    token: widget.token,
                                    title: c['name'],
                                    id: c['id'],
                                    circle: true))),
                        subtitle: Text(c['description'] ?? ''),
                        trailing: TextButton(
                            onPressed: () async {
                              final r = await post(
                                  '/communities/${c['id']}/join', {});
                              if (context.mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(r.statusCode == 200
                                            ? 'Joined'
                                            : 'Could not join')));
                            },
                            child: const Text('Join'))))
            ]);
          }));
}
