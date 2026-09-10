import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/vector_search/stored_chunk.dart';

class Turn {
  Turn({
    required this.role,
    required this.content,
    this.sources = const [],
    this.grounded = false,
    this.topScore,
    this.gate,
    this.computed,
    this.searchedFor,
  });

  final String role; // 'user' | 'assistant'
  final String content;
  final List<ScoredChunk> sources;

  /// Whether document excerpts were injected for this answer. When false the
  /// model answered from its own knowledge.
  final bool grounded;

  /// Best retrieval score seen for this turn, whether or not it cleared the
  /// gate. Surfaced in the UI so the threshold is observable, not magic.
  final double? topScore;

  /// The threshold [topScore] was judged against. Stored per turn rather than
  /// read from the controller, because the gate is per embedding model and the
  /// user can change models mid-conversation — displaying today's gate next to
  /// yesterday's score would be quietly wrong.
  final double? gate;

  /// Set when this answer came from computing over a table instead of from
  /// retrieved excerpts. The two are mutually exclusive by construction.
  final QueryResult? computed;

  /// What was actually embedded, when it differed from what the user typed.
  /// Shown in the UI so a surprising retrieval can be traced to the rewrite.
  final String? searchedFor;

  bool get isComputed => computed != null;
}