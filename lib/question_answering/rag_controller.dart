import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/ollama/ollama_launcher.dart';
import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/table_arithmetic/table_query_planner.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:local_rag/vector_search/stored_chunk.dart';
import 'package:path_provider/path_provider.dart';

import 'model_preferences.dart';
import 'query_condenser.dart';
import 'rag_prompts.dart';
import 'retrieval_settings.dart';

/// All state behind the UI: the Ollama connection, the selected models, the
/// document index, and the conversation.
class RagController extends ChangeNotifier {
  RagController({OllamaClient? client, OllamaLauncher? launcher})
    : ollama = client ?? OllamaClient() {
    _launcher = launcher ?? OllamaLauncher(ollama);
    _ingestor = Ingestor(ollama);
    _condenser = QueryCondenser(ollama);
  }

  final OllamaClient ollama;
  late final OllamaLauncher _launcher;
  late final Ingestor _ingestor;
  late final QueryCondenser _condenser;

  // Connection
  String? ollamaVersion; // null when Ollama is not answering
  bool isConnecting = false;
  bool isStopping = false;
  bool stoppedByUser = false; // shown as "stopped" rather than as an error
  String? statusMessage; // progress text while Ollama starts or stops
  String? error;

  // Models
  List<OllamaModel> models = const [];
  String? chatModel;
  String? embedModel;

  // Documents
  ObjectBoxStore? index;
  List<CsvTable> tables = const []; // CSV files, kept for exact arithmetic
  bool isIndexing = false;
  IngestProgress? indexingProgress;

  // Conversation
  final List<Turn> turns = [];
  bool isStreaming = false;
  bool strictGrounding = true; // refuse totals the excerpts cannot support
  bool condenseQueries = true; // rewrite long questions before searching

  /// Updated on every token without calling notifyListeners(), so only the
  /// in-progress bubble rebuilds while an answer streams in.
  final streamingAnswer = ValueNotifier<String>('');
  final streamingThinking = ValueNotifier<String>('');
  StreamSubscription<ChatChunk>? _answerSubscription;

  /// How many earlier turns are sent with a question, so follow-ups make sense.
  static const int maxHistoryTurns = 8;

  bool get isConnected => ollamaVersion != null;
  bool get canChat => chatModel != null;
  bool get hasIndex => index != null && !index!.isEmpty;
  String? get ollamaPath => _launcher.resolvedPath;
  double get retrievalThreshold => RetrievalSettings.thresholdFor(embedModel);
  List<OllamaModel> get chatModels => models.where((m) => m.canChat).toList();
  List<OllamaModel> get embedModels => models.where((m) => m.canEmbed).toList();

  // ---- Connection ------------------------------------------------------

  /// Starts Ollama if it is not running, then loads models and the saved
  /// index. Safe to call again: it is what the Connect button runs.
  Future<void> connect() async {
    if (isConnecting || isStopping) return;
    isConnecting = true;
    stoppedByUser = false;
    error = null;
    _setStatus('Looking for Ollama…');

    final outcome = await _launcher.ensureRunning(onStatus: _setStatus);
    if (outcome.isUp) {
      ollamaVersion = await ollama.version();
      _launcher.resolve(); // fills in ollamaPath if Ollama was already running
      _setStatus('Loading models…');
      await _loadModelsAndIndex();
    } else {
      ollamaVersion = null;
      error = _launcher.explainLaunch(outcome);
    }

    isConnecting = false;
    statusMessage = null;
    notifyListeners();
  }

  /// Stops the Ollama server. The model selection is kept for the next start.
  Future<void> stopOllama() async {
    if (isStopping || isConnecting) return;
    isStopping = true;
    error = null;
    _setStatus('Stopping Ollama…');

    final outcome = await _launcher.stop(onStatus: _setStatus);
    ollamaVersion = await ollama.version(); // a stop can be partial, so check
    stoppedByUser = !isConnected;
    final problem = _launcher.explainStop(outcome);
    error = problem.isEmpty ? null : problem;

    isStopping = false;
    statusMessage = null;
    notifyListeners();
  }

  void _setStatus(String message) {
    statusMessage = message;
    notifyListeners();
  }

  Future<void> _loadModelsAndIndex() async {
    try {
      models = await ollama.listModels();
      chatModel ??= ModelPreferences.pick(chatModels, ModelPreferences.chat);
      embedModel ??= ModelPreferences.pick(
        embedModels,
        ModelPreferences.embedding,
      );

      final saved = await ObjectBoxStore.open(await _indexDirectory());
      if (saved == null) return;
      // Vectors from a different embedding model cannot be searched.
      if (embedModel != null && saved.isCompatibleWith(embedModel!)) {
        _replaceIndex(saved);
        final file = await _tablesFile();
        tables = await file.exists()
            ? CsvTable.decodeAll(await file.readAsString())
            : const [];
      } else {
        saved.close();
        error =
            'Existing index was built with "${saved.embeddingModel}" '
            'but the selected embedding model is "$embedModel". Re-index '
            'before querying.';
      }
    } on OllamaException catch (e) {
      ollamaVersion = null; // Ollama quit after the version check
      error = e.message;
    } on Object catch (e) {
      error = '$e';
    }
  }

  // ---- Settings --------------------------------------------------------

  /// Shows an error raised outside the controller, e.g. by the folder picker.
  void reportError(String message) {
    error = message;
    notifyListeners();
  }

  void setChatModel(String? name) {
    chatModel = name;
    notifyListeners();
  }

  /// Switching embedding model makes the current index unsearchable, so it
  /// is dropped along with the tables that came from the same folder.
  void setEmbedModel(String? name) {
    if (name == embedModel) return;
    embedModel = name;
    if (index != null && !index!.isCompatibleWith(name ?? '')) {
      _replaceIndex(null);
      tables = const [];
      error =
          'Embedding model changed to "$name". The previous index is no '
          'longer valid — pick your knowledge base again to re-index.';
    }
    notifyListeners();
  }

  void setStrictGrounding(bool value) {
    strictGrounding = value;
    notifyListeners();
  }

  // ---- Indexing --------------------------------------------------------

  Future<void> indexDirectory(Directory folder) async {
    final embed = embedModel;
    if (embed == null) {
      reportError(
        'No embedding model available. '
        'Try: ollama pull locusai/all-minilm-l6-v2',
      );
      return;
    }

    isIndexing = true;
    error = null;
    indexingProgress = const IngestProgress('Scanning');
    notifyListeners();

    try {
      final files = await findSupportedFiles(folder);
      if (files.isEmpty) {
        throw StateError(
          'No supported files in ${folder.path}.\n'
          'Looking for: ${supportedExtensions.join(", ")}',
        );
      }
      _replaceIndex(null); // ObjectBox cannot recreate a folder that is open

      final result = await _ingestor.ingest(
        files: files,
        embeddingModel: embed,
        onProgress: (progress) {
          indexingProgress = progress;
          notifyListeners();
        },
        createIndex: (model, dimension) async => ObjectBoxStore.create(
          await _indexDirectory(),
          embeddingModel: model,
          dimension: dimension,
        ),
      );
      _replaceIndex(result.index);
      tables = result.tables;
      await (await _tablesFile()).writeAsString(CsvTable.encodeAll(tables));
    } on Object catch (e) {
      error = '$e';
      _replaceIndex(null);
      tables = const [];
    } finally {
      isIndexing = false;
      notifyListeners();
    }
  }

  /// Closes the old index before dropping it: ObjectBox holds a lock on its
  /// folder, and the next open fails if the old handle is never closed.
  void _replaceIndex(ObjectBoxStore? next) {
    final old = index;
    if (identical(old, next)) return;
    index = next;
    old?.close();
  }

  Future<Directory> _indexDirectory() async =>
      ObjectBoxStore.directoryIn(await getApplicationSupportDirectory());

  /// Saved beside the index rather than in it, so older databases still load.
  Future<File> _tablesFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/tables.json');

  // ---- Answering -------------------------------------------------------

  Future<void> ask(String question) async {
    if (isStreaming) return;
    final chat = chatModel;
    if (chat == null) {
      reportError('No chat model selected.');
      return;
    }

    turns.add(Turn(role: 'user', content: question));
    isStreaming = true;
    error = null;
    notifyListeners();

    // Arithmetic over a table is exact, so it takes priority over retrieval.
    final computed = _computeFromTables(question);
    final threshold = retrievalThreshold; // fixed now, so the UI shows this one
    final search = computed == null
        ? await _searchDocuments(question, chat)
        : null;
    final topScore = search?.chunks.firstOrNull?.score;
    final grounded = topScore != null && topScore >= threshold;
    final sources = grounded ? search!.chunks : const <ScoredChunk>[];

    final messages = [
      ChatMessage(
        'system',
        RagPrompts.system(
          grounded: grounded,
          strictGrounding: strictGrounding,
          computed: computed != null,
        ),
      ),
      // Earlier turns are replayed without their excerpts, so old context
      // does not keep steering new answers.
      for (final turn in _previousTurns(maxHistoryTurns))
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

    final answer = StringBuffer();
    _answerSubscription = ollama.chat(model: chat, messages: messages).listen((
      chunk,
    ) {
      if (chunk.thinking?.isNotEmpty ?? false) {
        streamingThinking.value += chunk.thinking!;
      }
      if (chunk.content?.isNotEmpty ?? false) {
        answer.write(chunk.content);
        streamingAnswer.value = answer.toString();
      }
    });
    try {
      // Never completes if stop() cancels the subscription; stop() then
      // records the partial answer itself.
      await _answerSubscription!.asFuture<void>();
    } on Object catch (e) {
      error = '$e';
    }
    _answerSubscription = null;

    final text = answer.toString().trim();
    turns.add(
      Turn(
        role: 'assistant',
        content: text.isEmpty ? (error ?? '(no response)') : text,
        sources: sources,
        grounded: grounded,
        topScore: topScore,
        threshold: threshold,
        computed: computed,
        searchedFor: search?.rewrittenQuery,
      ),
    );
    _endStreaming();
  }

  /// Answers aggregation questions ("total revenue in January") exactly from
  /// a table. Null when no table can answer or no rows matched.
  QueryResult? _computeFromTables(String question) {
    for (final table in tables) {
      final query = TableQueryPlanner.planFor(table, question);
      final result = query == null ? null : table.aggregate(query);
      if (result != null && !result.isEmpty) return result;
    }
    return null;
  }

  /// Searches the index for [question], best match first. Null when there is
  /// no index or the search failed; the model then answers without documents.
  Future<({List<ScoredChunk> chunks, String? rewrittenQuery})?>
  _searchDocuments(String question, String chat) async {
    final embed = embedModel;
    if (!hasIndex || embed == null) return null;
    try {
      // A long question embeds poorly, so it is shortened to a search query.
      String? rewritten;
      if (condenseQueries) {
        final condensed = await _condenser.condense(
          model: chat,
          question: question,
          history: [
            for (final turn in _previousTurns(4))
              '${turn.role}: ${turn.content.length > 200 ? '${turn.content.substring(0, 200)}…' : turn.content}',
          ],
          thinkingModel: models.any((m) => m.name == chat && m.thinks),
        );
        if (condensed.wasCondensed) rewritten = condensed.text;
      }

      final query = rewritten ?? question;
      final vector = await ollama.embedOne(
        model: embed,
        input: embed.startsWith('mxbai-embed')
            ? '${OllamaClient.mxbaiQueryPrefix}$query'
            : query,
      );
      final chunks = index!.search(
        vector,
        k: RetrievalSettings.topK,
        maxPerSource: RetrievalSettings.maxChunksPerSource,
      );
      return (chunks: chunks, rewrittenQuery: rewritten);
    } on Object catch (e) {
      debugPrint('Retrieval failed, answering without documents: $e');
      return null;
    }
  }

  /// Up to [count] turns before the question currently being answered.
  Iterable<Turn> _previousTurns(int count) {
    final previous = turns.length - 1;
    return turns.take(previous).skip(previous > count ? previous - count : 0);
  }

  /// Stops the answer in progress. Cancelling closes the HTTP request, so
  /// Ollama stops generating too.
  Future<void> stop() async {
    await _answerSubscription?.cancel();
    _answerSubscription = null;
    if (!isStreaming) return;
    final partial = streamingAnswer.value.trim();
    if (partial.isNotEmpty) {
      turns.add(Turn(role: 'assistant', content: '$partial\n\n_(stopped)_'));
    }
    _endStreaming();
  }

  void _endStreaming() {
    streamingAnswer.value = '';
    streamingThinking.value = '';
    isStreaming = false;
    notifyListeners();
  }

  void clearChat() {
    turns.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _answerSubscription?.cancel();
    streamingAnswer.dispose();
    streamingThinking.dispose();
    ollama.close();
    super.dispose();
  }
}
