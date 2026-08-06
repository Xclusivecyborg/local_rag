import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/composer.dart';
import 'package:local_rag/ui/sidebar/sidebar.dart';
import 'package:local_rag/ui/transcript/transcript.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final RagController _c = RagController();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChanged);
    _c.init();
  }

  void _onChanged() {
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _c.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickKnowledgeBase() async {
    final String? path;
    try {
      // Static in file_picker 11.x (it was FilePicker.platform.* before).
      // Requires com.apple.security.files.user-selected.read-only in both
      // entitlements files — the plugin reads that key directly and refuses
      // without it, whether or not the app is sandboxed.
      path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder of documents',
      );
    } on PlatformException catch (e) {
      // Without this the button is simply dead. An exception thrown here
      // escapes as an unhandled async error, which is visible in a debugger
      // and nowhere else — so a release build shows the user nothing at all.
      _c.reportError('Could not open the folder picker.\n'
          '${e.message ?? e.code}');
      return;
    }
    if (path == null) return; // user cancelled
    await _c.indexDirectory(Directory(path));
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _c.ask(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Sidebar(controller: _c, onPick: _pickKnowledgeBase),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(child: Transcript(controller: _c, scroll: _scroll)),
                Composer(controller: _c, input: _input, onSend: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
