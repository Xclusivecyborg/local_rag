import 'package:flutter/material.dart';

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).hintColor.withValues(alpha: 0.85),
      ),
    ),
  );
}
