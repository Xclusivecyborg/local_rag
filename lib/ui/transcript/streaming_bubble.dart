import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/markdown_text.dart';

class StreamingBubble extends StatelessWidget {
  const StreamingBubble({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reasoning models emit their scratchpad before any answer text.
          // Without surfacing something here, gpt-oss looks frozen for
          // several seconds on every question.
          ValueListenableBuilder<String>(
            valueListenable: controller.streamingThinking,
            builder: (context, thinking, _) {
              if (thinking.isEmpty) return const SizedBox.shrink();
              return Container(
                constraints: const BoxConstraints(maxWidth: 720),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  thinking,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: theme.hintColor),
                ),
              );
            },
          ),
          ValueListenableBuilder<String>(
            valueListenable: controller.streamingText,
            builder: (context, text, _) {
              return Container(
                constraints: const BoxConstraints(maxWidth: 720),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: text.isEmpty
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Text('Retrieving and generating…',
                            style: TextStyle(
                                fontSize: 12.5, color: theme.hintColor)),
                      ])
                    : MarkdownText(
                        text,
                        style: const TextStyle(fontSize: 14, height: 1.55),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}
