import 'package:flutter/material.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/vector_search/stored_chunk.dart';

class Citations extends StatelessWidget {
  const Citations({super.key, required this.sources});
  final List<ScoredChunk> sources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 720),
      margin: const EdgeInsets.only(top: 8),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          '${sources.length} retrieved chunks',
          style: TextStyle(fontSize: 11.5, color: theme.hintColor),
        ),
        children: [
          for (var i = 0; i < sources.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '[${i + 1}] ${sources[i].chunk.source} · chunk '
                    '${sources[i].chunk.index} · '
                    '${sources[i].score.toStringAsFixed(3)}',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    sources[i].chunk.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.hintColor,
                      height: 1.45,
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

class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.turn});
  final Turn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A computed answer is a different kind of claim from a retrieved one, and
    // the badge says which. "5 of 43 chunks" and "80 of 240 rows" deserve very
    // different amounts of trust.
    final computed = turn.computed;
    if (computed != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, left: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.functions, size: 12, color: theme.colorScheme.tertiary),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                'computed over ${computed.matchedRows} of '
                '${computed.totalRows} rows · ${computed.source}',
                style: TextStyle(
                  fontSize: 10.5,
                  color: theme.colorScheme.tertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final score = turn.topScore;
    final label = turn.grounded
        ? 'from your documents'
        : (score == null
              ? 'general knowledge'
              : 'general knowledge · nothing relevant found');

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            turn.grounded
                ? Icons.description_outlined
                : Icons.psychology_alt_outlined,
            size: 12,
            color: turn.grounded ? theme.colorScheme.primary : theme.hintColor,
          ),
          const SizedBox(width: 5),
          Text(
            score == null
                ? label
                : '$label · best match ${score.toStringAsFixed(2)} '
                      '(gate ${turn.threshold?.toStringAsFixed(2) ?? '—'})',
            style: TextStyle(
              fontSize: 10.5,
              color: turn.grounded
                  ? theme.colorScheme.primary
                  : theme.hintColor,
            ),
          ),
        ],
      ),
    );
  }
}
