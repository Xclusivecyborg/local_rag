import 'package:flutter/material.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';

class ModelDropdown extends StatelessWidget {
  const ModelDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.emptyHint,
    required this.icon,
  });

  final String? value;
  final List<(String, String?)> items;
  final ValueChanged<String?> onChanged;
  final String emptyHint;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Panel(
        accent: AppColors.caution,
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          emptyHint,
          style: TextStyle(
            fontSize: 11,
            fontFamily: kMono,
            color: theme.colorScheme.onSurface,
            height: 1.4,
          ),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      borderRadius: BorderRadius.circular(10),
      dropdownColor: theme.colorScheme.surfaceContainerHigh,
      icon: Icon(Icons.unfold_more_rounded, size: 16, color: theme.hintColor),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, size: 16, color: theme.hintColor),
        prefixIconConstraints: const BoxConstraints(minWidth: 38),
      ),
      items: [
        for (final (name, size) in items)
          DropdownMenuItem(
            value: name,
            child: Text.rich(
              TextSpan(
                text: name,
                children: [
                  if (size != null)
                    TextSpan(
                      text: '  $size',
                      style: TextStyle(
                        fontFamily: kMono,
                        fontSize: 11,
                        color: theme.hintColor,
                      ),
                    ),
                ],
              ),
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
