import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key, required this.controller});

  final RagController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (c.isConnecting || c.isStopping) {
      return Panel(
        child: PanelHeader(
          icon: Icons.hub_outlined,
          color: scheme.primary,
          title: c.isStopping ? 'Stopping Ollama' : 'Starting Ollama',
          subtitle: c.statusMessage ?? 'Working…',
          trailing: const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (c.isConnected) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PanelHeader(
              icon: Icons.hub_outlined,
              color: AppColors.ok,
              title: 'Ollama connected',
              subtitle: '127.0.0.1:11434',
              trailing: Tooltip(
                message: c.ollamaPath ?? 'ollama binary not located',
                child: Tag('v${c.ollamaVersion}'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const StatusDot(color: AppColors.ok),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Running on this machine',
                    style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                  ),
                ),
                ConnectionButtons(controller: c),
              ],
            ),
          ],
        ),
      );
    }

    // A stop the user asked for is not a failure, so it does not get the red
    // treatment. Only an unexpected disconnection does.
    final deliberate = c.stoppedByUser;
    final accent = deliberate ? null : scheme.error;
    return Panel(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(
            icon: deliberate
                ? Icons.power_settings_new_rounded
                : Icons.portable_wifi_off_rounded,
            color: accent ?? theme.hintColor,
            title: deliberate ? 'Ollama stopped' : 'Ollama is not running',
          ),
          const SizedBox(height: 10),
          SelectableText(
            c.error ??
                (deliberate
                    ? 'Press Connect to start it again.'
                    : 'Could not reach Ollama on 127.0.0.1:11434.'),
            style: TextStyle(
              fontSize: 11.5,
              color: deliberate ? theme.hintColor : scheme.onSurface,
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
    const size = Size(0, 30);
    const padding = EdgeInsets.symmetric(horizontal: 11);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: (c.isConnected && !busy) ? c.stopOllama : null,
          icon: const Icon(Icons.stop_rounded, size: 15),
          label: const Text('Stop'),
          style: OutlinedButton.styleFrom(minimumSize: size, padding: padding),
        ),
        if (!c.isConnected) ...[
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: busy ? null : c.connect,
            icon: const Icon(Icons.bolt_rounded, size: 15),
            label: const Text('Connect'),
            style: FilledButton.styleFrom(minimumSize: size, padding: padding),
          ),
        ],
      ],
    );
  }
}
