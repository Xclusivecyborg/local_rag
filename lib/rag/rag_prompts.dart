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

  /// Added at the end when the model can call the calculate tool, followed
  /// by the table description, so it knows what it can compute and when to ask.
  static const String toolRules = '''
You can calculate exact figures from the user's spreadsheets with the
calculate tool. The tables are described below.

- For any question that needs numbers from more than one row, call
  calculate. Never add up, average or count numbers yourself.
- Report the figure the tool returns as given, and say what it covers
  (the period, any filters, how many rows).
- If the tool says a request cannot run, fix the request, or ask the user
  if it is unclear.''';

  /// Sent when the model's tool call was not valid JSON, before it is asked
  /// again.
  static const String unreadableToolCall =
      'Your last calculate call was not valid JSON, so it was not run. Call '
      'calculate again with valid JSON arguments.';

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

  /// The system prompt changes shape depending on whether context was
  /// retrieved. With no excerpts it is simply a normal assistant.
  ///
  /// With [guarded] false, [tutorial] replaces [base], so nothing tells the
  /// model to admit what it does not know.
  ///
  /// [tables] is the calculate tool's table description, when the model has
  /// the tool.
  static String system({
    required bool grounded,
    required bool strictGrounding,
    String? tables,
    bool guarded = true,
  }) {
    final start = guarded ? base : tutorial;
    final rules = !grounded
        ? (strictGrounding ? '$start\n$clarifyRule' : start)
        : strictGrounding
        ? '$start$groundedRules\n$clarifyRule\n$aggregationRule'
        : '$start$groundedRules';
    return tables == null ? rules : '$rules\n\n$toolRules\n\n$tables';
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
