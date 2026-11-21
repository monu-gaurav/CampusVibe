import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class StudyRoom extends StatefulWidget {
  final String base, token, title;
  final int id;
  final bool circle;
  const StudyRoom(
      {super.key,
      required this.base,
      required this.token,
      required this.title,
      required this.id,
      this.circle = false});
  @override
  State<StudyRoom> createState() => _StudyRoom();
}

class _StudyRoom extends State<StudyRoom> {
  final input = TextEditingController();
  Timer? timer;
  Map session = {};
  List posts = [];
  String error = '';
  bool loading = false, writing = false;
  String get path =>
      widget.circle ? '/communities/${widget.id}/posts' : '/study/${widget.id}';
  Future<dynamic> call(String endpoint, String method, [Map? data]) async {
    final req = http.Request(method, Uri.parse(widget.base + endpoint))
      ..headers.addAll({
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      });
    if (data != null) req.body = jsonEncode(data);
    final r = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 10)));
    final v = jsonDecode(r.body);
    if (r.statusCode >= 400) throw Exception(v['detail']);
    return v;
  }

  @override
  void initState() {
    super.initState();
    load();
    int tick = 0;
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (++tick % 5 == 0) {
        load();
      } else if (!widget.circle) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final value = await call(widget.circle ? path : '$path/session', 'GET');
      if (mounted)
        setState(() {
          if (widget.circle) {
            posts = value;
          } else {
            session = value;
          }
          error = '';
        });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      loading = false;
    }
  }

  Future<void> write(String endpoint, String method, [Map? data]) async {
    if (writing) return;
    setState(() => writing = true);
    try {
      await call(endpoint, method, data);
      input.clear();
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => writing = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final remaining = ((session['ends'] ?? 0) as int) -
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(18), children: [
          if (error.isNotEmpty) Text(error),
          if (widget.circle) ...[
            TextField(
                controller: input,
                maxLength: 3000,
                decoration:
                    const InputDecoration(labelText: 'Post to your circle')),
            FilledButton(
                onPressed: writing
                    ? null
                    : () => write(path, 'POST', {'body': input.text.trim()}),
                child: const Text('Post')),
            for (final p in posts)
              Card(
                  child: ListTile(
                      title: Text(p['name']), subtitle: Text(p['body'])))
          ] else ...[
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(children: [
                      const Text('Focus together'),
                      Text(
                          remaining <= 0
                              ? '25:00'
                              : '${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
                          style: Theme.of(c).textTheme.displayMedium),
                      FilledButton(
                          onPressed: remaining > 0 || writing
                              ? null
                              : () => write('$path/start', 'POST'),
                          child: Text(remaining > 0
                              ? 'In session'
                              : 'Start shared timer'))
                    ]))),
            if ((session['goal'] ?? '') != '')
              CheckboxListTile(
                  value: session['completed'] == true,
                  title: Text(session['goal']),
                  onChanged: session['completed'] == true || writing
                      ? null
                      : (_) => write('$path/complete', 'POST')),
            TextField(
                controller: input,
                maxLength: 240,
                decoration:
                    const InputDecoration(labelText: 'Shared revision goal')),
            OutlinedButton(
                onPressed: writing
                    ? null
                    : () =>
                        write('$path/goal', 'PUT', {'goal': input.text.trim()}),
                child: const Text('Set goal'))
          ]
        ])));
  }
}
