import 'package:flutter/material.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';

/// Which RAG is running, and which optimizations it has.
///
/// The app starts with the recipe chosen in lib/main.dart; the switch in the
/// header flips between normal and optimized while it runs. The badge, the
/// meter and every row change together, so nobody has to take it on trust.
class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.recipe, this.onOptimizedChanged});
  final RagRecipe recipe;

  /// Called with true for optimized, false for normal. Null disables the
  /// switch, e.g. while an answer is streaming.
  final ValueChanged<bool>? onOptimizedChanged;

  @override
  Widget build(BuildContext context) {
    final all = recipe.optimizations;
    final on = all.where((o) => o.enabled).length;
    final optimized = on == all.length;
    final accent = optimized ? AppColors.ok : AppColors.caution;

    return Panel(
      accent: accent,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: PanelHeader(
              icon: optimized ? Icons.auto_awesome : Icons.science_outlined,
              color: accent,
              title: optimized ? 'Optimized RAG' : '${_title(recipe.name)} RAG',
              subtitle: '$on of ${all.length} optimizations on',
              trailing: _OptimizeSwitch(
                value: optimized,
                onChanged: onOptimizedChanged,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _Meter(states: [for (final o in all) o.enabled]),
          ),
          const SizedBox(height: 6),
          for (final stage in RagStage.values) ...[
            _StageLabel(stage.label),
            for (final o in all.where((o) => o.stage == stage)) _Row(o),
          ],
          const SizedBox(height: 10),
          const Divider(height: 1),
          const _SwitchHint(),
        ],
      ),
    );
  }

  static String _title(String name) =>
      name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';
}

/// One segment per optimization, lit when it is on. Readable from the back
/// of a room in a way "6 of 6" is not.
class _Meter extends StatelessWidget {
  const _Meter({required this.states});
  final List<bool> states;

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.45);
    return Row(
      children: [
        for (var i = 0; i < states.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 4,
              decoration: BoxDecoration(
                color: states[i] ? AppColors.ok : off,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StageLabel extends StatelessWidget {
  const _StageLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 9.5,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).hintColor.withValues(alpha: 0.8),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.optimization);
  final Optimization optimization;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = optimization;
    final dim = theme.hintColor.withValues(alpha: 0.65);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: o.enabled ? AppColors.ok.withValues(alpha: 0.18) : null,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: o.enabled ? AppColors.ok.withValues(alpha: 0.6) : dim,
              ),
            ),
            child: o.enabled
                ? const Icon(Icons.check_rounded, size: 11, color: AppColors.ok)
                : null,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        o.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: o.enabled ? theme.colorScheme.onSurface : dim,
                        ),
                      ),
                    ),
                    if (o.setting != null) Tag(o.setting!, dim: !o.enabled),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  o.description,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.3,
                    color: o.enabled
                        ? theme.hintColor
                        : dim.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How to change recipe, right where the audience is looking.
class _SwitchHint extends StatelessWidget {
  const _SwitchHint();

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 11),
      child: Row(
        children: [
          Icon(Icons.code_rounded, size: 13, color: hint),
          const SizedBox(width: 7),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'lib/main.dart',
                    style: TextStyle(fontFamily: kMono),
                  ),
                  TextSpan(
                    text: '  ·  sets the starting recipe',
                    style: TextStyle(color: hint.withValues(alpha: 0.8)),
                  ),
                ],
              ),
              style: TextStyle(fontSize: 10.5, color: hint),
            ),
          ),
        ],
      ),
    );
  }
}

/// The normal / optimized toggle, labelled so it reads as a control.
class _OptimizeSwitch extends StatelessWidget {
  const _OptimizeSwitch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Tooltip(
      message: value ? 'Switch to normal RAG' : 'Turn on every optimization',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 26,
            child: FittedBox(
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: AppColors.ink,
                activeTrackColor: AppColors.ok,
              ),
            ),
          ),
          Text(
            'Optimize',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: onChanged == null ? hint.withValues(alpha: 0.5) : hint,
            ),
          ),
        ],
      ),
    );
  }
}
