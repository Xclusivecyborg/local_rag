import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasIndex = controller.hasIndex;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 40, color: theme.hintColor),
            const SizedBox(height: 16),
            Text(
              hasIndex
                  ? 'Ask about your documents, or just talk.'
                  : 'Say hello, or pick a knowledge base to ask about your own files.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}
