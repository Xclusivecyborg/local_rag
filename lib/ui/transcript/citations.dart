import 'package:flutter/material.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';
import 'package:rag_blocks/rag_blocks.dart';

/// The chunks the model was shown, collapsed until asked for.
class Citations extends StatefulWidget {
  const Citations({super.key, required this.sources});
  final List<ScoredChunk> sources;

  @override
  State<Citations> createState() => _CitationsState();
}

class _CitationsState extends State<Citations> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = widget.sources;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${sources.length} retrieved chunk'
                    '${sources.length == 1 ? '' : 's'}',
                    style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < sources.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _Source(rank: i + 1, hit: sources[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.rank, required this.hit});
  final int rank;
  final ScoredChunk hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Tag('$rank'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hit.chunk.source,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: kMono,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              Tag('chunk ${hit.chunk.index}', dim: true),
              const SizedBox(width: 6),
              Tag(
                hit.score.toStringAsFixed(3),
                color: theme.colorScheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hit.chunk.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: theme.hintColor,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// How this answer was produced, as a pill under the reply.
///
/// A computed answer is a different kind of claim from a retrieved one, and
/// the badge says which. "5 of 43 chunks" and "80 of 240 rows" deserve very
/// different amounts of trust.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.turn});
  final Turn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final computed = turn.computed;
    if (computed != null) {
      return _Badge(
        icon: Icons.functions_rounded,
        color: AppColors.computed,
        label: 'Computed',
        tags: [
          '${computed.matchedRows} of ${computed.totalRows} rows',
          computed.source,
        ],
      );
    }

    final score = turn.topScore;
    final threshold = turn.threshold;
    return _Badge(
      icon: turn.grounded
          ? Icons.description_outlined
          : Icons.psychology_alt_outlined,
      color: turn.grounded ? AppColors.ok : theme.hintColor,
      label: turn.grounded
          ? 'From your documents'
          : (score == null ? 'General knowledge' : 'Nothing relevant found'),
      tags: [
        if (score != null) 'best ${score.toStringAsFixed(2)}',
        if (score != null)
          threshold == null
              ? 'no gate'
              : 'gate ${threshold.toStringAsFixed(2)}',
        if (turn.searchedFor != null) 'searched "${turn.searchedFor}"',
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.color,
    required this.label,
    this.tags = const [],
  });

  final IconData icon;
  final Color color;
  final String label;
  final List<String> tags;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        for (final t in tags) Tag(t),
      ],
    ),
  );
}
