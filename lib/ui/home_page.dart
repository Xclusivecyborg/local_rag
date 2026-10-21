import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/ui/composer.dart';
import 'package:local_rag/ui/sidebar/sidebar.dart';
import 'package:local_rag/ui/transcript/transcript.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.recipe});
  final RagRecipe recipe;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final RagController _controller = RagController(recipe: widget.recipe);
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.connect();
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
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _pickKnowledgeBase() async {
    final String? path;
    try {
      path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder of documents',
      );
    } on PlatformException catch (e) {
      _controller.reportError(
        'Could not open the folder picker.\n'
        '${e.message ?? e.code}',
      );
      return;
    }
    if (path == null) return; // user cancelled
    await _controller.indexDirectory(Directory(path));
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _controller.ask(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Sidebar(controller: _controller, onPick: _pickKnowledgeBase),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Transcript(
                    controller: _controller,
                    scroll: _scroll,
                    onAsk: _controller.ask,
                  ),
                ),
                Composer(controller: _controller, input: _input, onSend: _send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
