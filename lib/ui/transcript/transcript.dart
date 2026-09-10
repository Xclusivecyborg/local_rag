import 'package:flutter/material.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/ui/transcript/empty_state.dart';
import 'package:local_rag/ui/transcript/streaming_bubble.dart';
import 'package:local_rag/ui/transcript/turn_bubble.dart';

class Transcript extends StatelessWidget {
  const Transcript({super.key, required this.controller, required this.scroll});

  final RagController controller;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.turns.isEmpty && !c.isStreaming) {
      return EmptyState(controller: c);
    }

    return SelectionArea(
      child: ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(32, 28, 32, 12),
        itemCount: c.turns.length + (c.isStreaming ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < c.turns.length) return TurnBubble(turn: c.turns[i]);
          // The live bubble. Isolated behind ValueListenableBuilder so each
          // token repaints this widget only — not the transcript above it.
          return StreamingBubble(controller: c);
        },
      ),
    );
  }
}
