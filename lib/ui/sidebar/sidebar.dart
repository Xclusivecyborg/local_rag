import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/rag/retrieval_settings.dart';
import 'package:local_rag/ui/sidebar/connection_card.dart';
import 'package:local_rag/ui/sidebar/error_card.dart';
import 'package:local_rag/ui/sidebar/index_status.dart';
import 'package:local_rag/ui/sidebar/model_dropdown.dart';
import 'package:local_rag/ui/sidebar/recipe_card.dart';
import 'package:local_rag/ui/sidebar/section_label.dart';
import 'package:local_rag/ui/widgets/panel.dart';

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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(right: BorderSide(color: theme.dividerColor)),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
          children: [
            const _Brand(),
            const SizedBox(height: 26),
            ConnectionCard(controller: c),
            if (c.isConnected && c.error != null) ...[
              const SizedBox(height: 12),
              ErrorCard(message: c.error!),
            ],
            const SizedBox(height: 24),
            const SectionLabel('RAG recipe'),
            RecipeCard(
              recipe: c.recipe,
              onOptimizedChanged: c.canSwitchRecipe
                  ? (on) =>
                        c.setRecipe(on ? RagRecipe.optimized : RagRecipe.naive)
                  : null,
            ),
            const SizedBox(height: 24),
            const SectionLabel('Models'),
            ModelDropdown(
              icon: Icons.forum_outlined,
              value: c.chatModel,
              items: [for (final m in c.chatModels) (m.name, m.parameterSize)],
              onChanged: c.setChatModel,
              emptyHint: 'No chat models installed.\nollama pull gpt-oss',
            ),
            const SizedBox(height: 8),
            ModelDropdown(
              icon: Icons.scatter_plot_outlined,
              value: c.embedModel,
              items: [for (final m in c.embedModels) (m.name, null)],
              onChanged: c.setEmbedModel,
              emptyHint:
                  'No embedding model installed.\n'
                  'ollama pull locusai/all-minilm-l6-v2',
            ),
            if (c.embedModel != null &&
                !RetrievalSettings.hasMeasuredThreshold(c.embedModel)) ...[
              const SizedBox(height: 8),
              Text(
                'Retrieval gate not measured for this model — using '
                '${RetrievalSettings.unmeasuredThreshold}. '
                'Run tool/retrieval_quality/compare_embedders.dart to calibrate it.',
                style: TextStyle(
                  fontSize: 10.5,
                  color: theme.hintColor,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 24),
            const SectionLabel('Knowledge base'),
            if (c.isIndexing) ...[
              IndexingStatus(controller: c),
              const SizedBox(height: 10),
            ] else if (c.index != null) ...[
              IndexedStatus(index: c.index!),
              const SizedBox(height: 10),
            ],
            OutlinedButton.icon(
              onPressed: c.isIndexing ? null : onPick,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: Text(c.index == null ? 'Choose folder…' : 'Re-index…'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(38),
              ),
            ),
            if (c.turns.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: c.clearChat,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('Clear conversation'),
                  style: TextButton.styleFrom(foregroundColor: theme.hintColor),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The app's name, and the promise it makes.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        IconTile(
          Icons.airplanemode_active_rounded,
          color: theme.colorScheme.primary,
          size: 38,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Local RAG',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Everything runs on this machine.',
                style: TextStyle(fontSize: 11.5, color: theme.hintColor),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
