import 'package:rag_blocks/rag_blocks.dart';

/// Every piece of text [RagPipeline] sends to the chat model: the system
/// prompt, the rules layered onto it, and the wrappers around the question.
///
/// Kept apart from the controller so the wording can be read and changed in
/// one place without wading through connection and indexing logic.
abstract final class RagPrompts {
  /// Always present. Makes the assistant conversational by default, so
  /// "Hello" gets a greeting rather than a refusal or a document lookup.
  static const String base = '''
You are a helpful assistant specializing in answering Questions about Stridewell Footwear Company.

- Chat naturally. Greetings, small talk and general questions get normal,
  conversational answers.
- Answer general-knowledge questions from what you already know.
- Never invent facts about the user's company, its staff, policies or numbers.
  If you are asked something company-specific you do not know,
  say you do not have an answer rather than guessing.''';

  /// The system prompt a tutorial gives: no rules about what not to invent.
  /// Used when the recipe turns [base]'s guardrails off.
  static const String tutorial = '''
You are a helpful assistant. Answer the question using the excerpts provided.''';

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
  sample and that the true total cannot be computed from them. Then suggest a
  way to ask that can be computed: one measure, one period with its year, and
  at most one store or product line, such as "total revenue in Q1 2026". If the
  question excludes something or compares periods, suggest asking for each part
  separately, e.g. the total and the Heritage figure, then subtract.''';

  /// Added under strict grounding whenever nothing was computed, so a
  /// question missing a detail gets a question back instead of a refusal.
  static const String clarifyRule = '''
- If a question about the company's numbers leaves out something the answer
  depends on, do not answer or refuse. Ask for the missing detail in one short
  question, and offer the likely options if the excerpts show them. For example:
  a month or quarter with no year ("Q1": which year?), an unclear measure ("how
  much was made": revenue in naira, or units sold?), a partial or unclear name
  ("Ikeja": which location?), or a relative date ("last month": which month and
  year?).''';

  /// Rewrites a short follow-up into a question [TableQueryPlanner] can read.
  ///
  /// Not the search condenser's prompt: that one drops "how much" and the
  /// numbers to make a good search query, which leaves the planner nothing.
  static const String followUp = '''
You rewrite a follow-up message into one complete, standalone question, using
the conversation so far.

Rules:
- Output ONLY the question. No preamble, no quotes, no explanation.
- Keep the user's words for what to calculate: "how much", "total", "average",
  the measure, the period, and any store or product line.
- Fill in what the follow-up leaves out from the earlier question, such as the
  year or the measure.
- If the message is already a complete question, repeat it unchanged.

Examples:
Conversation so far:
user: How much was made in Q1?
assistant: Which year do you mean? The sales data covers 2026.
Q: 2026
How much was made in Q1 2026?
Conversation so far:
user: What was the total revenue at Ikeja City Mall in January 2026?
assistant: Total revenue at Ikeja City Mall in January 2026 was 15,203,000.
Q: and February?
What was the total revenue at Ikeja City Mall in February 2026?''';

  /// The system prompt changes shape depending on whether context was
  /// retrieved. With no excerpts it is simply a normal assistant.
  ///
  /// With [guarded] false, [tutorial] replaces [base], so nothing tells the
  /// model to admit what it does not know.
  static String system({
    required bool grounded,
    required bool strictGrounding,
    bool computed = false,
    bool guarded = true,
  }) {
    final start = guarded ? base : tutorial;
    if (computed) return '$start\n\n$computedRules';
    if (!grounded) return strictGrounding ? '$start\n$clarifyRule' : start;
    return strictGrounding
        ? '$start$groundedRules\n$clarifyRule\n$aggregationRule'
        : '$start$groundedRules';
  }

  static String withComputed(String question, QueryResult result) =>
      'COMPUTED RESULT (exact, from the full dataset):\n'
      '${result.toPromptBlock()}\nQUESTION: $question';

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
