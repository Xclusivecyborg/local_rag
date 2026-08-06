import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/markdown_text.dart';
import 'package:local_rag/ui/transcript/citations.dart';

class TurnBubble extends StatelessWidget {
  const TurnBubble({super.key, required this.turn});
  final Turn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.role == 'user';
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 720),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isUser
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            // User text is typed by a human and is not Markdown. Only the
            // model's output goes through the renderer.
            child: isUser
                ? Text(turn.content,
                    style: const TextStyle(fontSize: 14, height: 1.55))
                : MarkdownText(
                    turn.content,
                    style: const TextStyle(fontSize: 14, height: 1.55),
                  ),
          ),
          if (!isUser) SourceBadge(turn: turn),
          if (turn.sources.isNotEmpty) Citations(sources: turn.sources),
        ],
      ),
    );
  }
}

/// Shows where the answer came from. Without this the retrieval gate is
/// invisible and users cannot tell a grounded answer from a guess.
