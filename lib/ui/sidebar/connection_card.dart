import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key, required this.controller});

  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (c.isConnecting || c.isStopping) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                c.connectStatus ?? 'Working…',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (c.isConnected) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: c.ollamaPath ?? 'ollama binary not located',
                child: Text(
                  'Ollama ${c.ollamaVersion}',
                  style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConnectionButtons(controller: c),
        ],
      );
    }

    // A stop the user asked for is not a failure, so it does not get the red
    // treatment. Only an unexpected disconnection does.
    final deliberate = c.stoppedByUser;
    final background =
        deliberate ? scheme.surfaceContainerHighest : scheme.errorContainer;
    final foreground =
        deliberate ? scheme.onSurfaceVariant : scheme.onErrorContainer;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                deliberate ? 'Ollama stopped' : 'Ollama is not running',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            c.error ??
                (deliberate
                    ? 'Press Connect to start it again.'
                    : 'Could not reach Ollama on 127.0.0.1:11434.'),
            style: TextStyle(
              fontSize: 11.5,
              color: foreground,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          ConnectionButtons(controller: c),
        ],
      ),
    );
  }
}

/// The controls for Ollama's lifecycle.
///
/// While it is running, Stop is the only thing left to do — a connected app has
/// nothing to connect to. When it is down, both appear: Connect to start it,
/// and Stop greyed out, which says "there is nothing running" more directly
/// than an absent button does.

class ConnectionButtons extends StatelessWidget {
  const ConnectionButtons({super.key, required this.controller});

  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final busy = c.isConnecting || c.isStopping;

    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: (c.isConnected && !busy) ? c.stopOllama : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 15),
          label: const Text('Stop', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
        if (!c.isConnected) ...[
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: busy ? null : c.connect,
            icon: const Icon(Icons.bolt, size: 15),
            label: const Text('Connect', style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ],
      ],
    );
  }
}
