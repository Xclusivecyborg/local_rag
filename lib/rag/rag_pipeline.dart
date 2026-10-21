import 'dart:io';

import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/ingest_result.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:rag_blocks/rag_blocks.dart';

import 'rag_prompts.dart';
import 'rag_recipe.dart';
import 'retrieval_settings.dart';

/// Creates the empty index that the embedded chunks are written into.
typedef CreateIndex =
    Future<ObjectBoxStore> Function(String embeddingModel, int dimension);

/// Everything the pipeline decided before the model writes a word.
class PreparedPrompt {
  const PreparedPrompt({
    required this.messages,
    this.sources = const [],
    this.grounded = false,
    this.topScore,
    this.threshold,
    this.computed,
    this.searchedFor,
    this.retrievalError,
  });

  /// What is sent to the chat model.
  final List<ChatMessage> messages;

  /// The excerpts included in [messages]. Empty when none were.
  final List<ScoredChunk> sources;
  final bool grounded;

  /// Best retrieval score, even when it missed [threshold].
  final double? topScore;

  /// The relevance gate used, or null when the recipe has no gate.
  final double? threshold;

  /// Set when the answer was computed from a table instead of retrieved.
  final QueryResult? computed;

  /// The condensed search query, when it differed from the question.
  final String? searchedFor;

  /// Why retrieval failed, when it did. The model then answers without
  /// documents rather than not at all.
  final String? retrievalError;
}

/// The RAG workflow, step by step, built from rag_blocks.
///
/// The [recipe] decides which optimizations run. The steps are numbered as in
/// the talk: 1 knowledge base, 2 chunking, 3 embedding, 4 vector database,
/// 5 retrieval, 6 generation.
class RagPipeline {
  RagPipeline(this.ollama, {this.recipe = RagRecipe.optimized});

  final OllamaClient ollama;
  final RagRecipe recipe;

  /// How many earlier turns are sent with a question, so follow-ups make sense.
  static const int maxHistoryTurns = 8;

  /// How many earlier turns the condenser sees to resolve "and the Abuja one?".
  static const int condenserHistoryTurns = 4;

  // ---- Indexing: once per folder ---------------------------------------

  /// Turns files into a searchable index, plus tables for any CSV files.
  Future<IngestResult> ingest({
    required List<File> files,
    required String embeddingModel,
    required CreateIndex createIndex,
    void Function(IngestProgress)? onProgress,
  }) async {
    // 1. Knowledge base: read every file.
    onProgress?.call(const IngestProgress('Reading files'));
    final splitter = RecursiveCharacterTextSplitter(
      chunkSize: recipe.chunkSize,
      chunkOverlap: recipe.chunkOverlap,
    );
    final chunks = <Chunk>[];
    final tables = <CsvTable>[];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      String text;
      try {
        text = await file.readAsString();
      } on Object catch (e) {
        onProgress?.call(IngestProgress('Skipped $name ($e)'));
        continue;
      }
      if (fileExtension(name) == '.csv') {
        // A CSV is used both ways: as text for lookups ("which supplier makes
        // Heritage shoes?") and as a table for arithmetic ("January revenue").
        if (recipe.computeFromTables) {
          final table = CsvTable.parse(text, source: name);
          if (table.rowCount > 0) tables.add(table);
        }
        if (recipe.csvAsProse) text = csvToProse(text);
      }
      // 2. Chunking.
      chunks.addAll(splitter.splitText(text, source: name));
    }

    if (chunks.isEmpty) {
      throw StateError(
        'No readable text found. Supported: '
        '${supportedExtensions.join(", ")}.\n'
        'PDF and scanned documents are not handled by this build.',
      );
    }

    // 3. Embedding.
    onProgress?.call(
      IngestProgress('Embedding', done: 0, total: chunks.length),
    );
    final vectors = await ollama.embed(
      model: embeddingModel,
      input: [for (final c in chunks) c.text],
      onProgress: (done, total) => onProgress?.call(
        IngestProgress('Embedding', done: done, total: total),
      ),
    );

    // 4. Vector database.
    final index = await createIndex(embeddingModel, vectors.first.length);
    index.addAll(chunks, vectors);

    final tableRows = tables.fold<int>(0, (sum, t) => sum + t.rowCount);
    onProgress?.call(
      IngestProgress(
        'Indexed ${index.size} chunks from ${files.length} file(s)'
        '${tables.isEmpty ? '' : ', $tableRows table rows'}',
        done: chunks.length,
        total: chunks.length,
      ),
    );
    return IngestResult(index, tables);
  }

  // ---- Querying: every question ----------------------------------------

  /// Builds the prompt for [question]: computes, or retrieves and gates.
  ///
  /// [history] is the conversation before [question], oldest first.
  Future<PreparedPrompt> prepare({
    required String question,
    required String chatModel,
    String? embeddingModel,
    VectorStore? index,
    List<CsvTable> tables = const [],
    List<Turn> history = const [],
    bool thinkingModel = false,
  }) async {
    // 5a. Arithmetic over a table is exact, so it takes priority.
    final computed = recipe.computeFromTables
        ? TableQueryPlanner.answer(tables, question)
        : null;

    // 5b. Otherwise retrieve.
    List<ScoredChunk> hits = const [];
    String? searchedFor;
    String? retrievalError;
    final canSearch = index != null && !index.isEmpty && embeddingModel != null;
    if (computed == null && canSearch) {
      try {
        final search = await _search(
          question,
          chatModel: chatModel,
          embeddingModel: embeddingModel,
          index: index,
          history: _last(history, condenserHistoryTurns),
          thinkingModel: thinkingModel,
        );
        hits = search.hits;
        searchedFor = search.searchedFor;
      } on Object catch (e) {
        retrievalError = '$e';
      }
    }

    // The relevance gate: excerpts are only used when the best one is a real
    // match. Without it, every question gets the top five, even "Hello".
    final topScore = hits.firstOrNull?.score;
    final threshold = recipe.relevanceGate
        ? RetrievalSettings.thresholdFor(embeddingModel)
        : null;
    final grounded =
        topScore != null && (threshold == null || topScore >= threshold);
    final sources = grounded ? hits : const <ScoredChunk>[];

    // 6. Augment the prompt; generation streams from [generate].
    final messages = [
      ChatMessage(
        'system',
        RagPrompts.system(
          grounded: grounded,
          strictGrounding: recipe.strictGrounding,
          computed: computed != null,
          guarded: recipe.guardedPrompt,
        ),
      ),
      // Earlier turns are replayed without their excerpts, so old context
      // does not keep steering new answers.
      for (final turn in _last(history, maxHistoryTurns))
        ChatMessage(turn.role, turn.content),
      ChatMessage(
        'user',
        computed != null
            ? RagPrompts.withComputed(question, computed)
            : grounded
            ? RagPrompts.withContext(question, sources)
            : question,
      ),
    ];

    return PreparedPrompt(
      messages: messages,
      sources: sources,
      grounded: grounded,
      topScore: topScore,
      threshold: threshold,
      computed: computed,
      searchedFor: searchedFor,
      retrievalError: retrievalError,
    );
  }

  /// 6. Generation: streams the answer to [prompt].
  Stream<ChatChunk> generate(String chatModel, PreparedPrompt prompt) =>
      ollama.chatStream(model: chatModel, messages: prompt.messages);

  /// Earlier turns as condenser context, long answers cut to their start.
  static List<String> _forCondenser(List<Turn> history) => [
    for (final turn in history)
      '${turn.role}: ${turn.content.length > 200 ? '${turn.content.substring(0, 200)}…' : turn.content}',
  ];

  /// Condenses, embeds and searches. Best match first.
  Future<({List<ScoredChunk> hits, String? searchedFor})> _search(
    String question, {
    required String chatModel,
    required String embeddingModel,
    required VectorStore index,
    required List<Turn> history,
    required bool thinkingModel,
  }) async {
    // A long question embeds poorly, so it is shortened to a search query.
    String? rewritten;
    if (recipe.condenseQueries) {
      // A reasoning model thinks for ages over a one-line rewrite; skip it.
      final condenser = QueryCondenser(
        ollama.chatModel(chatModel, think: thinkingModel ? false : null),
      );
      final condensed = await condenser.condense(
        question: question,
        history: _forCondenser(history),
      );
      if (condensed.wasCondensed) rewritten = condensed.text;
    }

    final query = rewritten ?? question;
    final vector = await ollama.embedOne(
      model: embeddingModel,
      input: embeddingModel.startsWith('mxbai-embed')
          ? '${OllamaClient.mxbaiQueryPrefix}$query'
          : query,
    );
    final hits = index.search(
      vector,
      k: recipe.topK,
      maxPerSource: recipe.maxChunksPerSource,
    );
    return (hits: hits, searchedFor: rewritten);
  }

  /// The last [count] of [turns].
  static List<Turn> _last(List<Turn> turns, int count) =>
      turns.length > count ? turns.sublist(turns.length - count) : turns;
}
