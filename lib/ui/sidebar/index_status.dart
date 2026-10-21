import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

class IndexingStatus extends StatelessWidget {
  const IndexingStatus({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.indexingProgress;
    final scheme = Theme.of(context).colorScheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            icon: Icons.layers_outlined,
            color: scheme.primary,
            title: 'Indexing',
            subtitle: p?.stage ?? 'Working…',
            trailing: p != null && p.total > 0
                ? Tag('${p.done}/${p.total}')
                : null,
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: p?.fraction,
              minHeight: 4,
              backgroundColor: scheme.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
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
    final files = index.sources.length;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            icon: Icons.inventory_2_outlined,
            color: AppColors.ok,
            title: '${index.size} chunks indexed',
            subtitle: index.embeddingModel,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tag('$files file${files == 1 ? '' : 's'}'),
              Tag('${index.dimension}-d'),
              const Tag('ObjectBox HNSW'),
              if (index.storageDimension != index.dimension)
                Tag('stored at ${index.storageDimension}-d'),
            ],
          ),
        ],
      ),
    );
  }
}
