import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/question_answering/retrieval_settings.dart';
import 'package:local_rag/ui/sidebar/connection_card.dart';
import 'package:local_rag/ui/sidebar/error_card.dart';
import 'package:local_rag/ui/sidebar/index_status.dart';
import 'package:local_rag/ui/sidebar/model_dropdown.dart';
import 'package:local_rag/ui/sidebar/section_label.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.controller, required this.onPick});

  final RagController controller;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);

    return SizedBox(
      width: 330,
      child: Container(
        color: theme.colorScheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          children: [
            Text('Local RAG',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Everything runs on this machine.',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 28),
            ConnectionCard(controller: c),
            const SizedBox(height: 20),
            if (c.isConnected && c.error != null) ...[
              ErrorCard(message: c.error!),
              const SizedBox(height: 20),
            ],
            const SectionLabel('Chat model'),
            ModelDropdown(
              value: c.chatModel,
              items: [for (final m in c.chatModels) (m.name, m.parameterSize)],
              onChanged: c.setChatModel,
              emptyHint: 'No chat models installed',
            ),
            const SizedBox(height: 20),
            const SectionLabel('Embedding model'),
            ModelDropdown(
              value: c.embedModel,
              items: [for (final m in c.embedModels) (m.name, null)],
              onChanged: c.setEmbedModel,
              emptyHint: 'Run: ollama pull locusai/all-minilm-l6-v2',
            ),
            if (c.embedModel != null &&
                !RetrievalSettings.hasMeasuredThreshold(c.embedModel)) ...[
              const SizedBox(height: 6),
              Text(
                'Retrieval gate not measured for this model — using '
                '${RetrievalSettings.unmeasuredThreshold}. '
                'Run tool/retrieval_quality/compare_embedders.dart to calibrate it.',
                style: TextStyle(fontSize: 10.5, color: theme.hintColor),
              ),
            ],
            const SizedBox(height: 28),
            const SectionLabel('Knowledge base'),
            FilledButton.tonalIcon(
              onPressed: c.isIndexing ? null : onPick,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(c.index == null ? 'Choose folder…' : 'Re-index…'),
            ),
            const SizedBox(height: 12),
            if (c.isIndexing)
              IndexingStatus(controller: c)
            else if (c.index != null)
              IndexedStatus(index: c.index!),
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: c.strictGrounding,
              onChanged: c.setStrictGrounding,
              title:
                  const Text('Strict grounding', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                c.strictGrounding
                    ? 'Refuses totals it cannot verify'
                    : 'Will happily invent a total',
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
            ),
            if (c.turns.isNotEmpty)
              TextButton.icon(
                onPressed: c.clearChat,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear conversation'),
              ),
          ],
        ),
      ),
    );
  }
}
