import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/vector_search/stored_chunk.dart';

/// Every piece of text [RagController] sends to the chat model: the system
/// prompt, the rules layered onto it, and the wrappers around the question.
///
/// Kept apart from the controller so the wording can be read and changed in
/// one place without wading through connection and indexing logic.
abstract final class RagPrompts {
  /// Always present. Makes the assistant conversational by default, so
  /// "Hello" gets a greeting rather than a refusal or a document lookup.
  static const String base = '''
You are a helpful assistant specializing in answering Questions about Stridewell Footwear Commpany.

- Chat naturally. Greetings, small talk and general questions get normal,
  conversational answers.
- Answer general-knowledge questions from what you already know.
- Never invent facts about the user's company, its staff, policies or numbers.
  If you are asked something company-specific you do not know,
  say you do not have an answer rather than guessing.''';

  /// Added when an exact figure was computed over a table.
  ///
  /// No hedging clause here, and no aggregation rule. The figure was computed
  /// over every matching row, so telling the model to warn about partial
  /// samples would make it undermine a number that is exact.
  static const String computedRules = '''


A COMPUTED RESULT is included with this question. It was calculated directly
over every row of the user's data, not sampled or estimated, so it is exact.

- Report the figure as given. Do not recompute it, round it, or adjust it.
- State what it covers (the period, any filters, how many rows).
- Do not warn that it might be incomplete. It is not.''';

  /// Added when retrieved excerpts cleared the relevance gate.
  static const String groundedRules = '''


Excerpts from the user's documents are included with this question. Prefer them
for anything company-specific, and name the file you used.''';

  /// Added to [groundedRules] under strict grounding.
  static const String aggregationRule = '''
- If a question requires adding up, counting, or averaging values spread across
  many records, do NOT estimate from the excerpts. Say they are a partial
  sample and that the true total cannot be computed from them.''';

  /// The system prompt changes shape depending on whether context was
  /// retrieved. With no excerpts it is simply a normal assistant.
  static String system({
    required bool grounded,
    required bool strictGrounding,
    bool computed = false,
  }) {
    if (computed) return '$base$computedRules';
    if (!grounded) return base;
    return strictGrounding
        ? '$base$groundedRules\n$aggregationRule'
        : '$base$groundedRules';
  }

  static String withComputed(String question, QueryResult result) =>
      'COMPUTED RESULT (exact, from the full dataset):\n'
      '${result.toPromptBlock()}\nQUESTION: $question';

  static String withContext(String question, List<ScoredChunk> hits) {
    final ctx = StringBuffer();
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      ctx.writeln('[${i + 1}] ${h.chunk.source} '
          '(chunk ${h.chunk.index}, score ${h.score.toStringAsFixed(3)})');
      ctx.writeln(h.chunk.text);
      ctx.writeln();
    }
    return 'EXCERPTS FROM YOUR DOCUMENTS:\n$ctx\nQUESTION: $question';
  }
}
