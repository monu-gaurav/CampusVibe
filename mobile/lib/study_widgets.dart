import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onContinue});
  final VoidCallback onContinue;
  @override
  Widget build(BuildContext context) => Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(26),
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(children: [
                        Image.asset('assets/mark.png',height:48),
                        Text('CampusVibe',
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w900)),
                        const Text('Study. Connect. Vibe.'),
                        const SizedBox(height: 22),
                        ClipRRect(
                            borderRadius: BorderRadius.circular(32),
                            child: Image.asset('assets/study_group.webp',
                                width: 340, height: 210, fit: BoxFit.cover)),
                        const SizedBox(height: 22),
                        Text('Your all-in-one\ncampus community',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        const Text(
                            'Find a study partner, share notes and prepare together.',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 26),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                                onPressed: onContinue,
                                icon: const Icon(Icons.arrow_forward),
                                label: const Text('Get started')))
                      ]))))));
}

class StudyProfileEditor extends StatefulWidget {
  const StudyProfileEditor(
      {super.key, required this.profile, required this.submit});
  final Map<String, dynamic> profile;
  final Future<void> Function(String, List<String>, bool) submit;
  @override
  State<StudyProfileEditor> createState() => _StudyProfileEditorState();
}

class _StudyProfileEditorState extends State<StudyProfileEditor> {
  late final college =
      TextEditingController(text: widget.profile['college'] ?? '');
  late final topics = TextEditingController(
      text: (widget.profile['interests'] as List? ?? []).join(', '));
  late bool visible =
      widget.profile['study_visible'] == true || topics.text.isEmpty;
  bool busy = false;
  String error = '';
  @override
  void dispose() {
    college.dispose();
    topics.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final labels = topics.text
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (college.text.trim().length < 2 ||
        (visible && labels.isEmpty) ||
        labels.length > 15 ||
        labels.any((x) => x.length > 80)) {
      setState(() => error = 'Add your college and up to 15 study interests.');
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.submit(college.text.trim(), labels, visible);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(
            () => error = 'Could not save. Check your connection and retry.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Your study profile')),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
        Center(child: Image.asset('assets/college.webp', height: 92)),
        const SizedBox(height: 16),
        Text('What are you studying?',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        TextField(
            controller: college,
            maxLength: 160,
            decoration:
                const InputDecoration(labelText: 'College or university')),
        TextField(
            controller: topics,
            maxLength: 450,
            decoration: const InputDecoration(
                labelText: 'Study interests',
                hintText: 'GATE CSE, Python, DBMS',
                helperText: 'Separate interests with commas')),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: visible,
            onChanged: busy ? null : (v) => setState(() => visible = v),
            title: const Text('Show me in Study discovery'),
            subtitle: const Text(
                'Students at the same college can find your profile and request to study together.')),
        if (error.isNotEmpty) Text(error),
        FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'Saving…' : 'Save study profile'))
      ])));
}
