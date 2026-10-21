import 'package:flutter/material.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/ui/markdown_text.dart';
import 'package:local_rag/ui/transcript/citations.dart';
import 'package:local_rag/ui/widgets/panel.dart';

const double kBubbleMaxWidth = 720;
const TextStyle kBubbleText = TextStyle(fontSize: 14, height: 1.55);

class TurnBubble extends StatelessWidget {
  const TurnBubble({super.key, required this.turn});
  final Turn turn;

  @override
  Widget build(BuildContext context) {
    if (turn.isUser) return UserBubble(text: turn.content);
    return AssistantLayout(
      children: [
        AssistantBubble(child: MarkdownText(turn.content, style: kBubbleText)),
        SourceBadge(turn: turn),
        if (turn.sources.isNotEmpty) Citations(sources: turn.sources),
      ],
    );
  }
}

class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22, left: 80),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: kBubbleMaxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.16),
            border: Border.all(color: primary.withValues(alpha: 0.3)),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(text, style: kBubbleText),
        ),
      ),
    );
  }
}

/// An avatar on the left and the reply, badge and sources stacked beside it.
class AssistantLayout extends StatelessWidget {
  const AssistantLayout({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24, right: 40),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconTile(
          Icons.auto_awesome,
          color: Theme.of(context).colorScheme.primary,
          size: 28,
        ),
        const SizedBox(width: 12),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kBubbleMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );
}

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(14),
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
      ),
      child: child,
    );
  }
}
