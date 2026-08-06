import 'package:flutter/material.dart';

class ModelDropdown extends StatelessWidget {
  const ModelDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.emptyHint,
  });

  final String? value;
  final List<(String, String?)> items;
  final ValueChanged<String?> onChanged;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Text(
        emptyHint,
        style: TextStyle(
            fontSize: 12, color: Theme.of(context).colorScheme.error),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: [
        for (final (name, size) in items)
          DropdownMenuItem(
            value: name,
            child: Text(
              size == null ? name : '$name  ·  $size',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
