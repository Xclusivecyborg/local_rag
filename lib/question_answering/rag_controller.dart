import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/rag/rag_pipeline.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/rag/retrieval_settings.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart';

import 'model_preferences.dart';

/// All state behind the UI: the Ollama connection, the selected models, the
/// document index, and the conversation.
///
/// The RAG itself lives in [RagPipeline]; this class feeds it and streams
/// what it produces into the UI.
class RagController extends ChangeNotifier {
  RagController({
    OllamaClient? client,
    OllamaLauncher? launcher,
    RagRecipe recipe = RagRecipe.optimized,
  }) : ollama = client ?? OllamaClient(),
       _recipe = recipe {
    _launcher = launcher ?? OllamaLauncher(ollama);
    _pipeline = RagPipeline(ollama, recipe: recipe);
  }

  final OllamaClient ollama;

  /// Which optimizations run. Changed with [setRecipe]; each recipe has its
  /// own index, so changing it swaps the index too.
  RagRecipe get recipe => _recipe;
  RagRecipe _recipe;
  late final OllamaLauncher _launcher;
  late RagPipeline _pipeline;

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

  /// Updated on every token without calling notifyListeners(), so only the
  /// in-progress bubble rebuilds while an answer streams in.
  final streamingAnswer = ValueNotifier<String>('');
  final streamingThinking = ValueNotifier<String>('');
  StreamSubscription<ChatChunk>? _answerSubscription;
  int _currentTurn = 0; // stop() bumps this so an unfinished ask() gives up

  bool get isConnected => ollamaVersion != null;

  /// Whether a question can be sent now: Ollama is up and a chat model is
  /// chosen. The model stays selected after Stop, so both are needed.
  bool get canChat => isConnected && chatModel != null;
  bool get hasIndex => index != null && !index!.isEmpty;
  String? get ollamaPath => _launcher.resolvedPath;

  /// The relevance gate for the selected embedding model, or null when the
  /// recipe has no gate.
  double? get retrievalThreshold =>
      recipe.relevanceGate ? RetrievalSettings.thresholdFor(embedModel) : null;
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

      await _loadSavedIndex();
    } on OllamaException catch (e) {
      ollamaVersion = null; // Ollama quit after the version check
      error = e.message;
    } on Object catch (e) {
      error = '$e';
    }
  }

  /// Opens the current recipe's saved index and tables, if it has any.
  Future<void> _loadSavedIndex() async {
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
  }

  // ---- Settings --------------------------------------------------------

  /// Whether [setRecipe] can run now. Not mid-answer or mid-index, since
  /// both are using the current recipe's pipeline and index.
  bool get canSwitchRecipe => !isStreaming && !isIndexing;

  /// Switches between recipes while the app runs, e.g. naive to optimized.
  ///
  /// Each recipe chunks differently, so each has its own index: the current
  /// one is closed and the new recipe's saved index is opened. The
  /// conversation is kept, so the same question can be compared under both.
  Future<void> setRecipe(RagRecipe next) async {
    if (next.name == _recipe.name || !canSwitchRecipe) return;
    _recipe = next;
    _pipeline = RagPipeline(ollama, recipe: next);
    _replaceIndex(null);
    tables = const [];
    error = null;
    notifyListeners();
    try {
      await _loadSavedIndex();
    } on Object catch (e) {
      error = '$e';
    }
    if (index == null && error == null) {
      error =
          'No ${next.name} index yet. Choose the knowledge base folder to '
          'build one; after that, switching back here is instant.';
    }
    notifyListeners();
  }

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

      final result = await _pipeline.ingest(
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

  Future<Directory> _indexDirectory() async => ObjectBoxStore.directoryIn(
    await getApplicationSupportDirectory(),
    folder: recipe.indexFolder,
  );

  /// Saved beside the index rather than in it, so older databases still load.
  Future<File> _tablesFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/${recipe.tablesFile}',
  );

  // ---- Answering -------------------------------------------------------

  Future<void> ask(String question) async {
    if (isStreaming) return;
    if (!isConnected) {
      reportError('Ollama is stopped. Press Connect to start it again.');
      return;
    }
    final chat = chatModel;
    if (chat == null) {
      reportError('No chat model selected.');
      return;
    }

    turns.add(Turn(role: 'user', content: question));
    final turn = ++_currentTurn;
    isStreaming = true;
    error = null;
    notifyListeners();

    final prompt = await _pipeline.prepare(
      question: question,
      chatModel: chat,
      embeddingModel: embedModel,
      index: hasIndex ? index : null,
      tables: tables,
      history: _previousTurns(RagPipeline.maxHistoryTurns).toList(),
      thinkingModel: models.any((m) => m.name == chat && m.thinks),
    );
    if (turn != _currentTurn) return; // stopped while searching
    if (prompt.retrievalError != null) {
      debugPrint(
        'Retrieval failed, answering without documents: '
        '${prompt.retrievalError}',
      );
    }

    final answer = StringBuffer();
    _answerSubscription = _pipeline.generate(chat, prompt).listen((chunk) {
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
        sources: prompt.sources,
        grounded: prompt.grounded,
        topScore: prompt.topScore,
        threshold: prompt.threshold,
        computed: prompt.computed,
        searchedFor: prompt.searchedFor,
      ),
    );
    _endStreaming();
  }

  /// Up to [count] turns before the question currently being answered.
  Iterable<Turn> _previousTurns(int count) {
    final previous = turns.length - 1;
    return turns.take(previous).skip(previous > count ? previous - count : 0);
  }

  /// Stops the answer in progress. Cancelling closes the HTTP request, so
  /// Ollama stops generating too.
  Future<void> stop() async {
    _currentTurn++;
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
