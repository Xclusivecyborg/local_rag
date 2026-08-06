import 'dart:async';

import 'package:local_rag/ollama/ollama_client.dart';

/// The outcome of trying to shorten a question before embedding it.
class CondensedQuery {
  const CondensedQuery({
    required this.text,
    required this.original,
    required this.wasCondensed,
    this.note,
  });

  /// What to actually embed.
  final String text;
  final String original;
  final bool wasCondensed;

  /// Why it was skipped or rejected — surfaced for diagnostics, never guessed at.
  final String? note;

  const CondensedQuery.unchanged(String question, [String? why])
      : text = question,
        original = question,
        wasCondensed = false,
        note = why;
}

/// Rewrites a question into a short search query before it is embedded.
///
/// Embeddings score the *whole sentence*. Ask "How much discount do I get if I
/// buy shoes worth 100,000 naira as an employee?" and the clause about buying
/// drags the vector toward documents about purchases and refunds; the staff
/// handbook that actually answers it falls to rank 10, and with k=5 it is never
/// seen. Measured on sample_kb:
///
///     "employee discount"                              rank 1
///     "What discount do employees get on Heritage?"     rank 2
///     the full question above                           rank 10
///
/// Condensing also fixes follow-ups. "and the Abuja one?" embeds four words
/// with no noun in them; resolved against history it becomes a real query.
///
/// Everything here is designed to fail back to the original question. A bad
/// rewrite is worse than no rewrite, so a rewrite is only used when it clearly
/// looks like a search query.
class QueryCondenser {
  QueryCondenser(this._ollama, {this.timeout = const Duration(seconds: 25)});

  final OllamaClient _ollama;
  final Duration timeout;

  /// Questions at or below this many words are already close to a search query.
  /// Rewriting them risks stripping the one word that mattered, for no gain —
  /// "employee discount" cannot be usefully improved.
  static const int minWordsToCondense = 8;

  /// A rewrite longer than this is the model explaining itself, not answering.
  static const int maxWords = 12;

  static const String _system = '''
You rewrite questions into short search queries for a document search engine.

Rules:
- Output ONLY the query. No preamble, no quotes, no explanation.
- Keep the words that identify WHICH document or topic is needed.
- Drop politeness, hypotheticals, and any numbers the user wants calculated.
- Use the conversation to resolve pronouns and follow-ups into full nouns.
- Maximum 8 words.

Examples:
Q: How much will I get as discount if I buy shoes worth 100,000 naira as an employee?
employee discount policy
Q: and the Abuja one?
Abuja branch location
Q: Can you tell me please what the returns window is for the Heritage line?
Heritage line returns window''';

  /// Returns a query to embed. Never throws.
  Future<CondensedQuery> condense({
    required String model,
    required String question,
    List<String> history = const <String>[],
    bool thinkingModel = false,
  }) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty) return const CondensedQuery.unchanged('');

    final words = trimmed.split(RegExp(r'\s+')).length;
    if (words < minWordsToCondense && history.isEmpty) {
      return CondensedQuery.unchanged(trimmed, 'short question, left alone');
    }

    final messages = <ChatMessage>[
      const ChatMessage('system', _system),
      if (history.isNotEmpty)
        ChatMessage('user',
            'Conversation so far:\n${history.join('\n')}\n\nQ: $trimmed'),
      if (history.isEmpty) ChatMessage('user', 'Q: $trimmed'),
    ];

    try {
      final buffer = StringBuffer();
      await for (final chunk in _ollama
          .chat(
            model: model,
            messages: messages,
            temperature: 0,
            // A rewrite does not need a visible scratchpad, and waiting for one
            // would put several seconds in front of every question.
            think: thinkingModel ? false : null,
          )
          .timeout(timeout)) {
        if (chunk.content != null) buffer.write(chunk.content);
      }
      return _validate(buffer.toString(), trimmed);
    } on Object catch (e) {
      // Condensing is an optimisation. If it fails for any reason — model gone,
      // timeout, malformed stream — the turn continues on the raw question.
      return CondensedQuery.unchanged(trimmed, 'condense failed: $e');
    }
  }

  /// Accepts a rewrite only if it looks like a query rather than a sentence
  /// about one.
  static CondensedQuery _validate(String raw, String original) {
    var text = raw.trim();
    if (text.isEmpty) {
      return CondensedQuery.unchanged(original, 'empty rewrite');
    }

    // Models like to add a line of commentary. Take the first real line.
    text = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    text = text.replaceAll(RegExp(r'^["“”\x27`]+|["“”\x27`]+$'), '').trim();
    // Strip a leading "Query:" / "Search:" label if one slipped through.
    text = text.replaceFirst(
        RegExp(r'^(query|search|answer)\s*:\s*', caseSensitive: false), '');

    if (text.isEmpty) {
      return CondensedQuery.unchanged(original, 'empty after cleanup');
    }
    if (text.split(RegExp(r'\s+')).length > maxWords) {
      return CondensedQuery.unchanged(original, 'rewrite too long');
    }
    if (RegExp(r"\b(sorry|cannot|can't|unable|as an ai)\b",
            caseSensitive: false)
        .hasMatch(text)) {
      return CondensedQuery.unchanged(original, 'model refused');
    }
    // Must carry at least one word of substance, not just stopwords.
    final content = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !_stopwords.contains(w));
    if (content.isEmpty) {
      return CondensedQuery.unchanged(original, 'rewrite carried no content');
    }

    return CondensedQuery(
      text: text,
      original: original,
      wasCondensed: true,
    );
  }

  static const Set<String> _stopwords = {
    'the', 'and', 'for', 'with', 'what', 'how', 'why', 'who', 'was', 'are',
    'you', 'your', 'this', 'that', 'from', 'about', 'get', 'can', 'does',
  };
}
