import 'package:flutter/material.dart';
import 'package:local_rag/ui/theme/app_theme.dart';

/// The app's card: a dark surface with a hairline border, washed from the
/// top-left corner with [accent] when it has one.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.accent,
    this.padding = const EdgeInsets.all(14),
    this.radius = 12,
    this.color,
  });

  final Widget child;
  final Color? accent;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// The surface underneath the wash. Defaults to surfaceContainer.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surface = color ?? scheme.surfaceContainer;
    final a = accent;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: a == null ? surface : null,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color:
              a?.withValues(alpha: 0.28) ??
              scheme.outlineVariant.withValues(alpha: 0.45),
        ),
        gradient: a == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [a.withValues(alpha: 0.07), surface, surface],
                stops: const [0, 0.35, 1],
              ),
      ),
      child: child,
    );
  }
}

/// An icon in a tinted, rounded square: the lead of every panel header.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color, this.size = 34});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(size * 0.27),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Icon(icon, size: size * 0.53, color: color),
  );
}

/// A small monospace tag for a technical value: "600 chars", "384-d", "0.42".
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.dim = false});
  final String text;

  /// Tints the tag, for values that carry a meaning (a score, a source).
  final Color? color;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color:
            c?.withValues(alpha: 0.14) ??
            scheme.surfaceContainerHighest.withValues(alpha: dim ? 0.5 : 1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontFamily: kMono,
          color:
              c ??
              (dim
                  ? Theme.of(context).hintColor.withValues(alpha: 0.65)
                  : scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// A coloured dot with a soft glow, for live state.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
      ],
    ),
  );
}

/// A panel header: an [IconTile], a title and an optional subtitle.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Row(
      children: [
        IconTile(icon, color: color),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: hint),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
