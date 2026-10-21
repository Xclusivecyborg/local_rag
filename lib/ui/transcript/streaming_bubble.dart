import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/markdown_text.dart';
import 'package:local_rag/ui/transcript/turn_bubble.dart';
import 'package:local_rag/ui/widgets/panel.dart';

class StreamingBubble extends StatelessWidget {
  const StreamingBubble({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AssistantLayout(
      children: [
        // Reasoning models emit their scratchpad before any answer text.
        // Without surfacing something here, gpt-oss looks frozen for
        // several seconds on every question.
        ValueListenableBuilder<String>(
          valueListenable: controller.streamingThinking,
          builder: (context, thinking, _) {
            if (thinking.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.psychology_outlined,
                          size: 13,
                          color: theme.hintColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'THINKING',
                          style: TextStyle(
                            fontSize: 9.5,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      thinking,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontStyle: FontStyle.italic,
                        color: theme.hintColor,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        ValueListenableBuilder<String>(
          valueListenable: controller.streamingAnswer,
          builder: (context, text, _) => AssistantBubble(
            child: text.isEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Retrieving and generating…',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  )
                : MarkdownText(text, style: kBubbleText),
          ),
        ),
      ],
    );
  }
}
