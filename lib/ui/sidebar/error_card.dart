import 'package:flutter/material.dart';
import 'package:local_rag/ui/widgets/panel.dart';

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      accent: scheme.error,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(Icons.error_outline_rounded, color: scheme.error, size: 28),
          const SizedBox(width: 11),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurface,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
