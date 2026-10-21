import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';

/// First-run guidance, plus one question for each thing the eval measures:
/// a lookup, a total, and small talk. On stage, a click instead of typing.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.controller, required this.onAsk});
  final RagController controller;
  final ValueChanged<String> onAsk;

  static const List<(IconData, Color, String)> _suggestions = [
    (
      Icons.description_outlined,
      AppColors.ok,
      'How many days do I have to return unworn shoes?',
    ),
    (
      Icons.functions_rounded,
      AppColors.computed,
      "How much was Stridewell's revenue in january 2026?",
    ),
    (Icons.waving_hand_outlined, AppColors.caution, 'Hello!'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTile(
                Icons.airplanemode_active_rounded,
                color: theme.colorScheme.primary,
                size: 56,
              ),
              const SizedBox(height: 18),
              Text(
                c.hasIndex
                    ? 'Ask your documents anything'
                    : 'Choose a knowledge base to begin',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                c.hasIndex
                    ? 'Answers come from your files when they can, and from '
                          'the model when they can\'t. Nothing leaves this machine.'
                    : 'Pick a folder in the sidebar to search your own files, '
                          'or just say hello.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.hintColor,
                  height: 1.5,
                ),
              ),
              if (c.hasIndex && c.canChat) ...[
                const SizedBox(height: 28),
                for (final (icon, color, question) in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _Suggestion(
                      icon: icon,
                      color: color,
                      text: question,
                      onTap: () => onAsk(question),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({
    required this.icon,
    required this.color,
    required this.text,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Panel(
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(
            children: [
              IconTile(icon, color: color, size: 26),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
              Icon(
                Icons.arrow_forward_rounded,
                size: 15,
                color: theme.hintColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
