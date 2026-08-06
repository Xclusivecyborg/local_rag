import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

class IndexingStatus extends StatelessWidget {
  const IndexingStatus({super.key, required this.controller});
  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final p = controller.progress;
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

/// Lets the exact and approximate indexes be swapped at will.
///
/// Exposed rather than hidden because the whole point is that they are
/// comparable: same corpus, same vectors, same questions, and you can watch
/// whether the answers change. Switching drops the current index, since the
/// vectors only exist inside whichever store built them.

class IndexedStatus extends StatelessWidget {
  const IndexedStatus({super.key, required this.store, required this.path});
  final ObjectBoxStore store;
  final String? path;

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
          const Row(children: [
            Icon(Icons.check_circle, size: 15, color: Colors.greenAccent),
            SizedBox(width: 6),
          ]),
          Text('${store.size} chunks indexed',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            '${store.sources.length} file(s) · ${store.dimension}-d\n'
            '${store.embeddingModel}\n'
            'ObjectBox HNSW${store.storageDimension != store.dimension ? ' · stored at ${store.storageDimension}-d' : ''}',
            style: TextStyle(fontSize: 11, color: theme.hintColor, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// Connection state for Ollama, and the way back when it is down.
///
/// The app is useless without Ollama, so this is deliberately the first thing
/// in the sidebar and carries its own recovery action rather than telling the
/// user to go open a terminal.
