import 'package:rag_blocks/rag_blocks.dart';

import 'normal_prompt.dart';
import 'optimized_prompt.dart';

/// Puts together what [RagPipeline] sends to the chat model: the system
/// prompt from [NormalPrompt] or [OptimizedPrompt], and the wrapper around
/// the question.
///
/// The wording lives in those two files, so the unoptimized and optimized
/// prompts can be read side by side.
abstract final class RagPrompts {
  /// The system prompt changes shape depending on whether context was
  /// retrieved. With no excerpts it is simply a normal assistant.
  ///
  /// With [fineTuned] false the model gets [NormalPrompt] alone, as a
  /// tutorial would give it: nothing tells it to admit what it does not know
  /// or to name its sources.
  ///
  /// [tables] is the calculate tool's table description, when the model has
  /// the tool.
  static String system({
    required bool grounded,
    required bool strictGrounding,
    String? tables,
    bool fineTuned = true,
  }) {
    final start = fineTuned
        ? '${OptimizedPrompt.base}'
              '${grounded ? OptimizedPrompt.groundedRules : ''}'
        : NormalPrompt.system;
    final rules = !strictGrounding
        ? start
        : grounded
        ? '$start\n${OptimizedPrompt.clarifyRule}\n'
              '${OptimizedPrompt.aggregationRule}'
        : '$start\n${OptimizedPrompt.clarifyRule}';
    return tables == null
        ? rules
        : '$rules\n\n${OptimizedPrompt.toolRules}\n\n$tables';
  }

  static String withContext(String question, List<ScoredChunk> hits) {
    final ctx = StringBuffer();
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      ctx.writeln(
        '[${i + 1}] ${h.chunk.source} '
        '(chunk ${h.chunk.index}, score ${h.score.toStringAsFixed(3)})',
      );
      ctx.writeln(h.chunk.text);
      ctx.writeln();
    }
    return 'EXCERPTS FROM YOUR DOCUMENTS:\n$ctx\nQUESTION: $question';
  }
}
