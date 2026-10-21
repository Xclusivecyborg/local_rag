import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/widgets/panel.dart';

class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.input,
    required this.onSend,
  });

  final RagController controller;
  final TextEditingController input;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final enabled = c.canChat && !c.isStreaming;
    final optimized = c.recipe.optimizations.every((o) => o.enabled);

    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 20),
      child: Column(
        children: [
          Panel(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            radius: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    enabled: enabled,
                    maxLines: 4,
                    minLines: 1,
                    onSubmitted: (_) => onSend(),
                    style: const TextStyle(fontSize: 14, height: 1.45),
                    decoration: InputDecoration(
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      hintText: !c.isConnected
                          ? 'Ollama is stopped. Press Connect to chat'
                          : c.canChat
                          ? (c.hasIndex
                                ? 'Ask about your documents, or anything else…'
                                : 'Say something…')
                          : 'No chat model available',
                      hintStyle: TextStyle(color: theme.hintColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: c.isStreaming
                      ? IconButton.filledTonal(
                          tooltip: 'Stop',
                          onPressed: c.stop,
                          icon: const Icon(Icons.stop_rounded, size: 18),
                        )
                      : IconButton.filled(
                          tooltip: 'Send',
                          onPressed: enabled ? onSend : null,
                          icon: const Icon(
                            Icons.arrow_upward_rounded,
                            size: 18,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Tag(
                '${c.recipe.name} RAG',
                color: optimized ? AppColors.ok : AppColors.caution,
              ),
              if (c.chatModel != null) ...[
                const SizedBox(width: 6),
                Tag(c.chatModel!),
              ],
              const SizedBox(width: 8),
              Icon(Icons.wifi_off_rounded, size: 12, color: theme.hintColor),
              const SizedBox(width: 4),
              Text(
                'offline',
                style: TextStyle(fontSize: 10.5, color: theme.hintColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
