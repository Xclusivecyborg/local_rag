import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

class IndexingStatus extends StatelessWidget {
  const IndexingStatus({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.indexingProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: p?.fraction),
        const SizedBox(height: 8),
        Text(
          p == null
              ? 'Working…'
              : (p.total > 0 ? '${p.stage} ${p.done}/${p.total}' : p.stage),
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ],
    );
  }
}

/// What the current index actually contains.
///
/// Spelled out rather than reduced to a tick, because "43 chunks, 384-d,
/// built by locusai/all-minilm-l6-v2" is what tells you whether the answers
/// you are about to get can be trusted. An index built by a different model
/// from the one now selected is the failure this card is here to make visible.
class IndexedStatus extends StatelessWidget {
  const IndexedStatus({super.key, required this.index});
  final ObjectBoxStore index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, size: 15, color: Colors.greenAccent),
          const SizedBox(height: 6),
          Text('${index.size} chunks indexed',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            '${index.sources.length} file(s) · ${index.dimension}-d\n'
            '${index.embeddingModel}\n'
            'ObjectBox HNSW${index.storageDimension != index.dimension ? ' · stored at ${index.storageDimension}-d' : ''}',
            style: TextStyle(fontSize: 11, color: theme.hintColor, height: 1.5),
          ),
        ],
      ),
    );
  }
}
