import 'dart:io';

import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/ingest_result.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart';

import 'calculate_tool.dart';
import 'rag_prompts.dart';
import 'rag_recipe.dart';
import 'retrieval_settings.dart';

/// Creates the empty index that the embedded chunks are written into.
typedef CreateIndex =
    Future<ObjectBoxStore> Function(String embeddingModel, int dimension);

/// Everything the pipeline decided before the model writes a word.
class PreparedPrompt {
  PreparedPrompt({
    required this.messages,
    this.sources = const [],
    this.grounded = false,
    this.topScore,
    this.threshold,
    this.calculator,
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

  /// The calculate tool offered to the model, when the recipe uses tool
  /// calling and there are tables.
  final CalculateTool? calculator;

  /// Every calculation the model asked for while answering, in order. Filled
  /// in by [RagPipeline.generate].
  final List<CalculateOutcome> calculations = [];

  /// The last figure the model computed, once [RagPipeline.generate] is done.
  QueryResult? get computed =>
      calculations.lastWhere((c) => c.succeeded, orElse: _none).result;

  static CalculateOutcome _none() =>
      CalculateOutcome.error(const ToolCall('', {}), '');

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
        // With tool calling a CSV is only a table: the model asks the
        // calculate tool for figures, so embedding its rows adds nothing.
        if (recipe.useToolCalling) {
          final table = CsvTable.parse(text, source: name);
          if (table.rowCount > 0) tables.add(table);
          continue;
        }
        if (recipe.csvAsProse) text = csvToProse(text);
      }
      // 2. Chunking.
      chunks.addAll(splitter.splitText(text, source: name));
    }

    if (chunks.isEmpty && tables.isEmpty) {
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
    // Only spreadsheets: the index is empty, but still needs its width.
    final dimension = vectors.isNotEmpty
        ? vectors.first.length
        : (await ollama.embedOne(model: embeddingModel, input: 'x')).length;

    // 4. Vector database.
    final index = await createIndex(embeddingModel, dimension);
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
    // 5. Retrieval. With tool calling the model also gets the calculate
    // tool, and decides itself whether a question needs it.
    final calculator = recipe.useToolCalling && tables.isNotEmpty
        ? CalculateTool(tables)
        : null;
    List<ScoredChunk> hits = const [];
    String? searchedFor;
    String? retrievalError;
    final canSearch = index != null && !index.isEmpty && embeddingModel != null;
    if (canSearch) {
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
          tables: calculator?.describeTables(),
          guarded: recipe.guardedPrompt,
        ),
      ),
      // Earlier turns are replayed without their excerpts, so old context
      // does not keep steering new answers.
      for (final turn in _last(history, maxHistoryTurns))
        ChatMessage(turn.role, turn.content),
      ChatMessage(
        'user',
        grounded ? RagPrompts.withContext(question, sources) : question,
      ),
    ];

    return PreparedPrompt(
      messages: messages,
      sources: sources,
      grounded: grounded,
      topScore: topScore,
      threshold: threshold,
      calculator: calculator,
      searchedFor: searchedFor,
      retrievalError: retrievalError,
    );
  }

  /// Most rounds of tool calls before the model must answer with what it
  /// has. One call answers most questions; a comparison may need two.
  static const int maxToolRounds = 3;

  /// 6. Generation: streams the answer to [prompt].
  ///
  /// With a calculator, the model may ask for calculations first. Each is
  /// run by code and sent back, and the model is asked again, until it
  /// answers in words. Only the words and thinking are streamed out; what
  /// was computed is recorded in [PreparedPrompt.calculations].
  Stream<ChatChunk> generate(String chatModel, PreparedPrompt prompt) async* {
    final calculator = prompt.calculator;
    final messages = [...prompt.messages];
    for (var round = 0; ; round++) {
      final offerTools = calculator != null && round < maxToolRounds;
      final calls = <ToolCall>[];
      final said = StringBuffer();
      try {
        await for (final chunk in ollama.chatStream(
          model: chatModel,
          messages: messages,
          tools: offerTools ? [calculator.definition] : const [],
        )) {
          calls.addAll(chunk.toolCalls);
          said.write(chunk.content ?? '');
          final hasText =
              (chunk.content?.isNotEmpty ?? false) ||
              (chunk.thinking?.isNotEmpty ?? false);
          if (hasText) {
            yield ChatChunk(content: chunk.content, thinking: chunk.thinking);
          }
        }
      } on OllamaException catch (e) {
        // The model wrote a tool call Ollama could not read as JSON. Say so
        // and let it try again, rather than failing the whole answer.
        if (!offerTools || !e.message.contains('error parsing tool call')) {
          rethrow;
        }
        messages.add(ChatMessage('system', RagPrompts.unreadableToolCall));
        continue;
      }
      if (calls.isEmpty || calculator == null) return;

      messages.add(ChatMessage('assistant', said.toString(), toolCalls: calls));
      for (final call in calls) {
        final outcome = calculator.run(call);
        prompt.calculations.add(outcome);
        messages.add(ChatMessage.toolResult(call, outcome.text));
      }
    }
  }

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
