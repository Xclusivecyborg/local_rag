import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.input,
    required this.onSend,
  });

  final RagController controller;
  final TextEditingController input;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final enabled = c.canChat && !c.isStreaming;

    return Container(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: input,
              enabled: enabled,
              maxLines: 4,
              minLines: 1,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: c.canChat
                    ? (c.hasIndex
                          ? 'Ask about your documents, or anything else…'
                          : 'Say something…')
                    : 'No chat model available',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (c.isStreaming)
            FilledButton.tonalIcon(
              onPressed: c.stop,
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop'),
            )
          else
            FilledButton(
              onPressed: enabled ? onSend : null,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text('Send'),
              ),
            ),
        ],
      ),
    );
  }
}
