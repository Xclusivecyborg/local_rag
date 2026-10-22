import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart';

/// One message in the conversation, plus how an assistant answer was produced.
class Turn {
  Turn({
    required this.role,
    required this.content,
    this.sources = const [],
    this.grounded = false,
    this.topScore,
    this.threshold,
    this.computed,
    this.searchedFor,
  });

  final String role; // 'user' or 'assistant'
  final String content;

  /// The retrieved chunks the model was shown for this answer.
  final List<ScoredChunk> sources;

  /// True when document excerpts were included. False means the model
  /// answered from its own knowledge.
  final bool grounded;

  /// Best retrieval score, even when it missed [threshold]. Shown in the UI.
  final double? topScore;

  /// The relevance threshold used for this answer. Stored per turn because it
  /// changes when the user switches embedding model.
  final double? threshold;

  /// Set when the answer was computed from a table instead of retrieved.
  final QueryResult? computed;

  /// The rewritten search query, when it differed from the question.
  final String? searchedFor;

  bool get isUser => role == 'user';
  bool get isComputed => computed != null;
}
