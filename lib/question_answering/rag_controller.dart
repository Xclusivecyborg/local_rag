import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'query_condenser.dart';
import 'package:local_rag/table_arithmetic/table_query_planner.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:local_rag/ollama/ollama_launcher.dart';
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

class RagController extends ChangeNotifier {
  RagController({OllamaClient? client, OllamaLauncher? launcher})
      : ollama = client ?? OllamaClient() {
    _ingestor = Ingestor(ollama);
    _launcher = launcher ?? OllamaLauncher(ollama);
    _condenser = QueryCondenser(ollama);
  }

  final OllamaClient ollama;
  late final Ingestor _ingestor;
  late final OllamaLauncher _launcher;
  late final QueryCondenser _condenser;

  // ---- Hot path -------------------------------------------------------
  // Tokens arrive dozens of times per second. Routing them through
  // notifyListeners() would rebuild the entire page — sidebar, transcript,
  // every previous bubble — on every token. These two notifiers let the UI
  // rebuild *only* the in-flight bubble instead.
  final ValueNotifier<String> streamingText = ValueNotifier<String>('');
  final ValueNotifier<String> streamingThinking = ValueNotifier<String>('');

  // ---- Coarse state ---------------------------------------------------
  List<OllamaModel> models = const [];
  String? chatModel;
  String? embedModel;
  String? error;

  ObjectBoxStore? store;

  /// Swaps [store], closing whatever it replaces.
  ///
  /// ObjectBox holds a native handle and a lock on its directory; dropping the
  /// reference without closing leaks both, and the next open of the same
  /// directory fails.
  void _replaceStore(ObjectBoxStore? next) {
    final old = store;
    if (identical(old, next)) return;
    store = next;
    old?.close();
  }

  /// Structured tables from the same ingest, used for arithmetic.
  List<CsvTable> tables = const <CsvTable>[];

  IngestProgress? progress;
  bool isIndexing = false;
  bool isStreaming = false;

  // ---- Connection -----------------------------------------------------
  /// Version reported by Ollama, or null when it is not answering. This is the
  /// single source of truth for "are we connected" — a version string can only
  /// exist if something replied on port 11434.
  String? ollamaVersion;
  bool isConnecting = false;
  bool isStopping = false;

  /// True when Ollama is down because the user pressed Stop, rather than
  /// because something went wrong. Purely presentational: a deliberate stop
  /// should not be dressed up as an error.
  bool stoppedByUser = false;

  /// Progress text while launching, so a 30-second wait is not a frozen UI.
  String? connectStatus;

  bool get isConnected => ollamaVersion != null;

  /// Absolute path of the `ollama` binary in use, for display. Worth surfacing
  /// because a machine can easily have two (a Homebrew one and the installer's)
  /// and "which one is this actually talking to" is otherwise unanswerable.
  String? get ollamaPath => _launcher.resolvedPath;

  /// When true the model is told to refuse arithmetic it cannot verify.
  /// Turn it off to reproduce the confident-wrong-total failure.
  bool strictGrounding = true;

  /// When true, long questions and follow-ups are rewritten into a short search
  /// query before being embedded. Costs one extra model call on those turns.
  bool condenseQueries = true;

  final List<Turn> turns = <Turn>[];
  StreamSubscription<ChatChunk>? _sub;

  List<OllamaModel> get chatModels =>
      models.where((m) => m.canChat).toList(growable: false);
  List<OllamaModel> get embedModels =>
      models.where((m) => m.canEmbed).toList(growable: false);

  /// Which chat model to start on, best first.
  ///
  /// Without this the app takes whichever model sorts first alphabetically,
  /// so `gemma4` beats `gpt-oss` on spelling rather than on being the better
  /// answer. Anything not listed still works — it just has to be chosen.
  static const List<String> preferredChatModels = <String>['gpt-oss'];

  /// Which embedding model to start on, best first.
  ///
  /// Kept explicit for the same reason, and because the wrong one here is
  /// worse than the wrong chat model: an index built with one embedder cannot
  /// be searched with another, so a silent alphabetical pick means a rebuild.
  static const List<String> preferredEmbedModels = <String>[
    'locusai/all-minilm-l6-v2',
  ];

  /// First installed model matching [preferred]; otherwise the first installed
  /// one, so a machine with none of the preferred models still starts usable.
  ///
  /// Matches on the name before the tag, so a preference for `gpt-oss` is
  /// satisfied by `gpt-oss:20b` or `gpt-oss:latest` alike.
  static String? preferredOf(
    List<OllamaModel> installed,
    List<String> preferred,
  ) {
    if (installed.isEmpty) return null;
    for (final want in preferred) {
      for (final m in installed) {
        if (m.name == want || m.name.split(':').first == want) return m.name;
      }
    }
    return installed.first.name;
  }

  /// Chatting only needs a chat model. An index is optional — without one the
  /// assistant simply answers from its own knowledge, which is what makes
  /// "Hello" work instead of erroring.
  bool get canChat => chatModel != null;

  bool get hasIndex => store != null && !store!.isEmpty;

  /// Similarity above which retrieved context is considered relevant enough
  /// to show the model — **per embedding model**.
  ///
  /// These are not interchangeable, and using one model's number with another
  /// is a silent failure rather than an error.
  ///
  /// Measured on sample_kb at [kDefaultTargetChars], with 20 questions the
  /// documents genuinely answer — 12 long descriptive ones and 8 short
  /// entity-shaped ones — against 12 off-topic inputs:
  ///
  /// | model                           | worst real | best off-topic | gate |
  /// |---------------------------------|------------|----------------|------|
  /// | mxbai-embed-large:latest        | 0.478      | 0.500          | 0.47 |
  /// | locusai/all-minilm-l6-v2:latest | 0.221      | 0.249          | 0.22 |
  ///
  /// **A threshold is only valid for the chunk size it was measured at.** These
  /// were 0.57 and 0.29 when chunks were 1200 characters. Halving the chunk
  /// size moved both, because a shorter chunk is about fewer things and so
  /// matches a specific question more strongly. Change [kDefaultTargetChars]
  /// and every number here has to be measured again:
  ///
  ///   flutter test tool/retrieval_quality/compare_embedders.dart
  ///
  /// In both cases the two bands **overlap** — the worst real question scores
  /// slightly below the loudest small talk — so no value is clean. The gate
  /// sits at the worst real question and accepts the leak, because a blocked
  /// question fails silently while a leak is visible on screen and labelled.
  /// At these settings that costs 1 leak in 12 for MiniLM and 4 in 12 for
  /// mxbai, and misses nothing.
  ///
  /// `all-minilm:22m` and `:33m` used to be here at 0.29 and 0.22. They were
  /// removed rather than left behind: both numbers were taken at 1200
  /// characters, and a stale threshold that is too high is precisely the
  /// silent failure this map exists to prevent. Re-pull and re-measure to
  /// bring them back. (`:22m` is the same model as the locusai entry — same
  /// worst on-topic score to three decimals when both were installed.)
  static const Map<String, double> measuredThresholds = <String, double>{
    'mxbai-embed-large:latest': 0.47,
    'locusai/all-minilm-l6-v2:latest': 0.22,
  };

  /// Used for a model nobody has measured.
  ///
  /// Deliberately permissive. A threshold set too high silently disables
  /// retrieval, which looks like the app forgot your documents and gives the
  /// user nothing to act on. Too low merely lets small talk pull an excerpt —
  /// visible, harmless, and labelled in the UI.
  static const double unmeasuredThreshold = 0.15;

  /// Threshold for [model], falling back to [unmeasuredThreshold].
  ///
  /// Tolerates a missing or different tag when the base name is unambiguous,
  /// so `mxbai-embed-large` and `mxbai-embed-large:latest` agree. When two
  /// tags of the same base name disagree — `all-minilm:22m` at 0.29 against
  /// `:33m` at 0.22 — it refuses to pick, because guessing between them
  /// silently changes retrieval behaviour.
  ///
  /// [from] exists so that branch stays testable. Which models are in
  /// [measuredThresholds] changes as they are pulled and removed, and a test
  /// that depends on today's contents is a test that quietly stops checking
  /// anything.
  static double thresholdFor(String? model, {Map<String, double>? from}) {
    if (model == null) return unmeasuredThreshold;
    final table = from ?? measuredThresholds;
    final exact = table[model];
    if (exact != null) return exact;

    final base = model.split(':').first;
    final candidates = table.entries
        .where((e) => e.key.split(':').first == base)
        .map((e) => e.value)
        .toSet();
    return candidates.length == 1 ? candidates.first : unmeasuredThreshold;
  }

  static bool hasMeasuredThreshold(String? model) =>
      model != null && thresholdFor(model) != unmeasuredThreshold;

  /// The gate in force right now, for display and for [ask].
  double get retrievalThreshold => thresholdFor(embedModel);

  /// Cap on chunks any one file may contribute to the top k.
  static const int maxChunksPerSource = 2;

  /// Kept beside the index rather than inside it, so a database written by an
  /// older build still loads and simply arrives without tables.
  Future<File> _tablesFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/tables.json');
  }

  /// Where the ObjectBox database lives.
  Future<Directory> _indexDir() async =>
      ObjectBoxStore.directoryIn(await getApplicationSupportDirectory());

  /// Builds an empty index of the currently selected [backend].
  ///
  /// Throws when the model is wider than any declared HNSW index. Narrower
  /// models are zero-padded up to the nearest, which leaves cosine similarity
  /// exactly unchanged — so every model up to the widest entity just works.
  Future<ObjectBoxStore> _newIndex(String model, int dimension) async {
    return ObjectBoxStore.create(
      await _indexDir(),
      embeddingModel: model,
      dimension: dimension,
    );
  }

  /// Called once at startup.
  Future<void> init() => connect();

  /// Makes sure Ollama is up — launching it if it is not — then loads models
  /// and any persisted index.
  ///
  /// Safe to call repeatedly. This is what the Connect button runs, and it is
  /// how the app recovers when Ollama is quit mid-session instead of needing a
  /// restart.
  Future<void> connect() async {
    if (isConnecting || isStopping) return;
    isConnecting = true;
    stoppedByUser = false;
    connectStatus = 'Looking for Ollama…';
    error = null;
    notifyListeners();

    final outcome = await _launcher.ensureRunning(onStatus: (message) {
      connectStatus = message;
      notifyListeners();
    });

    if (!outcome.isUp) {
      ollamaVersion = null;
      error = _launcher.explain(outcome);
      isConnecting = false;
      connectStatus = null;
      notifyListeners();
      return;
    }

    ollamaVersion = await ollama.version();
    // Populate resolvedPath even when Ollama was already running (in which
    // case ensureRunning never had to look), so the UI can show which binary.
    _launcher.resolve();
    connectStatus = 'Loading models…';
    notifyListeners();

    await _loadModelsAndIndex();

    isConnecting = false;
    connectStatus = null;
    notifyListeners();
  }

  /// Stops the Ollama server. The counterpart to [connect].
  ///
  /// Deliberately leaves [models] and the selected model names alone. They go
  /// stale for as long as Ollama is down, but clearing them would throw away
  /// the user's model choice every time they toggle the server — and the
  /// connection card already states plainly that nothing is running.
  Future<void> stopOllama() async {
    if (isStopping || isConnecting) return;
    isStopping = true;
    connectStatus = 'Stopping Ollama…';
    error = null;
    notifyListeners();

    final outcome = await _launcher.stop(onStatus: (message) {
      connectStatus = message;
      notifyListeners();
    });

    // Ask the server, don't assume: on a partial stop something may still be
    // answering, and the UI must reflect what is true rather than what we tried.
    ollamaVersion = await ollama.version();
    stoppedByUser = !isConnected;
    error = _launcher.explainStop(outcome);
    if (error!.isEmpty) error = null;

    isStopping = false;
    connectStatus = null;
    notifyListeners();
  }

  Future<void> _loadModelsAndIndex() async {
    try {
      models = await ollama.listModels();
      error = null;
      chatModel ??= preferredOf(chatModels, preferredChatModels);
      embedModel ??= preferredOf(embedModels, preferredEmbedModels);

      final loaded = await _loadPersistedIndex();
      if (loaded != null) {
        // Only reuse a persisted index if it was built by the model we are
        // about to query with. Otherwise the vectors are in a different
        // space and retrieval quietly returns nonsense.
        if (embedModel != null && loaded.isCompatibleWith(embedModel!)) {
          _replaceStore(loaded);
          final tablesFile = await _tablesFile();
          tables = await tablesFile.exists()
              ? CsvTable.decodeAll(await tablesFile.readAsString())
              : const <CsvTable>[];
        } else {
          loaded.close();
          error = 'Existing index was built with "${loaded.embeddingModel}" '
              'but the selected embedding model is "$embedModel". Re-index '
              'before querying.';
        }
      }
    } on OllamaException catch (e) {
      // Reachable a moment ago, gone now — Ollama was quit between the version
      // probe and this call. Drop back to disconnected so the UI offers
      // Connect rather than an empty model list with no way forward.
      ollamaVersion = null;
      error = e.message;
    } on Object catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  /// Loads the index from disk, or null if there isn't a usable one.
  Future<ObjectBoxStore?> _loadPersistedIndex() async =>
      ObjectBoxStore.open(await _indexDir());

  /// Surfaces a failure that happened outside the controller — the folder
  /// picker, say — in the same place as every other error, rather than letting
  /// it vanish into an unhandled async error.
  void reportError(String message) {
    error = message;
    notifyListeners();
  }

  void setChatModel(String? name) {
    chatModel = name;
    notifyListeners();
  }

  /// Changing the embedding model invalidates every stored vector.
  void setEmbedModel(String? name) {
    if (name == embedModel) return;
    embedModel = name;
    if (store != null && !store!.isCompatibleWith(name ?? '')) {
      _replaceStore(null);
      // Tables are model-independent — no embeddings involved — but they came
      // from the folder the stale index describes, so they go together.
      tables = const <CsvTable>[];
      error = 'Embedding model changed to "$name". The previous index is no '
          'longer valid — pick your knowledge base again to re-index.';
    }
    notifyListeners();
  }

  void setStrictGrounding(bool value) {
    strictGrounding = value;
    notifyListeners();
  }

  Future<void> indexDirectory(Directory dir) async {
    final embed = embedModel;
    if (embed == null) {
      error = 'No embedding model available. '
          'Try: ollama pull locusai/all-minilm-l6-v2';
      notifyListeners();
      return;
    }

    isIndexing = true; 
    error = null;
    progress = const IngestProgress('Scanning');
    notifyListeners();

    try {
      final files = await collectFiles(dir);
      if (files.isEmpty) {
        throw StateError(
          'No supported files in ${dir.path}.\n'
          'Looking for: ${kSupportedExtensions.join(", ")}',
        );
      }
      // Close the current index before ingesting: ObjectBox re-creates its
      // database directory, which it cannot do while the old handle holds it.
      _replaceStore(null);

      final built = await _ingestor.ingest(
        files: files,
        embeddingModel: embed,
        report: (p) {
          progress = p;
          notifyListeners();
        },
        indexFactory: _newIndex,
      );
      _replaceStore(built.store);
      tables = built.tables;
      // The index needs no explicit save — ObjectBox wrote every chunk to disk
      // as it was put. Only the tables, which live outside it, do.
      await (await _tablesFile())
          .writeAsString(CsvTable.encodeAll(built.tables));
    } on Object catch (e) {
      error = '$e';
      _replaceStore(null);
      tables = const <CsvTable>[];
    } finally {
      isIndexing = false;
      notifyListeners();
    }
  }

  /// How many previous turns to replay, so follow-ups like "and the Abuja
  /// one?" make sense. Bounded so a long conversation does not slowly eat
  /// the model's context window.
  static const int historyTurns = 8;

  static const _aggregationRule = '''
- If a question requires adding up, counting, or averaging values spread across
  many records, do NOT estimate from the excerpts. Say they are a partial
  sample and that the true total cannot be computed from them.''';

  /// The system prompt changes shape depending on whether context was
  /// retrieved. This is what makes the assistant conversational: with no
  /// excerpts it is simply a normal assistant, so "Hello" gets a greeting
  /// rather than a refusal or a hallucinated document lookup.
  String _systemPrompt({required bool grounded, bool computed = false}) {
    final p = StringBuffer('''
You are a helpful assistant specializing in answering Questions about Stridewell Footwear Commpany.

- Chat naturally. Greetings, small talk and general questions get normal,
  conversational answers.
- Answer general-knowledge questions from what you already know.
- Never invent facts about the user's company, its staff, policies or numbers.
  If you are asked something company-specific and no excerpts were provided,
  say you do not have that document rather than guessing.''');

    if (computed) {
      // No hedging clause here, and no aggregation rule. The figure was
      // computed over every matching row, so telling the model to warn about
      // partial samples would make it undermine a number that is exact.
      p.write('''


A COMPUTED RESULT is included with this question. It was calculated directly
over every row of the user's data, not sampled or estimated, so it is exact.

- Report the figure as given. Do not recompute it, round it, or adjust it.
- State what it covers (the period, any filters, how many rows).
- Do not warn that it might be incomplete. It is not.''');
      return p.toString();
    }

    if (grounded) {
      p.write('''


Excerpts from the user's documents are included with this question. Prefer them
for anything company-specific, and name the file you used.''');
      if (strictGrounding) p.write('\n$_aggregationRule');
    }
    return p.toString();
  }

  /// The last few turns, flattened, for resolving follow-up questions.
  List<String> _recentHistory() {
    final prior = turns.length <= 1
        ? const <Turn>[]
        : turns.sublist(0, turns.length - 1);
    final recent =
        prior.length > 4 ? prior.sublist(prior.length - 4) : prior;
    return [
      for (final t in recent)
        '${t.role}: ${t.content.length > 200 ? '${t.content.substring(0, 200)}…' : t.content}'
    ];
  }

  /// Answers a question by computing over a table, or returns null.
  ///
  /// Runs before retrieval because the two are mutually exclusive: if this
  /// question is arithmetic over structured data, handing the model five
  /// similar-looking rows is precisely the failure we are removing.
  QueryResult? _tryCompute(String question) {
    if (tables.isEmpty) return null;
    for (final table in tables) {
      final query = TableQueryPlanner.planFor(table, question);
      if (query == null) continue;
      final result = table.aggregate(query);
      // A query that matched no rows is not an answer — fall through to
      // retrieval rather than announcing a confident zero.
      if (result == null || result.isEmpty) continue;
      return result;
    }
    return null;
  }

  String _withComputed(String question, QueryResult result) =>
      'COMPUTED RESULT (exact, from the full dataset):\n'
      '${result.toPromptBlock()}\nQUESTION: $question';

  String _withContext(String question, List<ScoredChunk> hits) {
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

  Future<void> ask(String question) async {
    if (isStreaming) return;
    final chat = chatModel;
    if (chat == null) {
      error = 'No chat model selected.';
      notifyListeners();
      return;
    }

    turns.add(Turn(role: 'user', content: question));
    isStreaming = true;
    error = null;
    streamingText.value = '';
    streamingThinking.value = '';
    notifyListeners();

    // ---- Retrieval, gated on relevance ---------------------------------
    // Always search if there is an index, but only *use* the result when it
    // clears the threshold. Below it, the question is not about the
    // documents, so injecting five irrelevant chunks would just confuse the
    // model into answering a question nobody asked.
    var hits = <ScoredChunk>[];
    double? best;
    var grounded = false;
    // Captured once, so the value judged against and the value displayed can
    // never disagree even if the model changes while the answer streams.
    final gate = retrievalThreshold;

    // Arithmetic first. If this question is an aggregation over structured
    // data, retrieval cannot answer it at any k — see README.
    final computed = _tryCompute(question);

    final embed = embedModel;
    String? searchedFor;
    if (computed == null && hasIndex && embed != null) {
      try {
        // Embeddings score the whole sentence, so a clause about the
        // calculation the user wants can outweigh the words identifying which
        // document they need. Condense first; see QueryCondenser.
        var searchText = question;
        if (condenseQueries) {
          final thinks =
              models.any((m) => m.name == chat && m.thinks);
          final condensed = await _condenser.condense(
            model: chat,
            question: question,
            history: _recentHistory(),
            thinkingModel: thinks,
          );
          if (condensed.wasCondensed) {
            searchText = condensed.text;
            searchedFor = condensed.text;
          }
        }

        final isMxbai = embed.startsWith('mxbai-embed');
        final queryVec = await ollama.embedOne(
          model: embed,
          input: isMxbai
              ? '${OllamaClient.mxbaiQueryPrefix}$searchText'
              : searchText,
        );
        final candidates = store!.search(
          queryVec,
          k: 5,
          maxPerSource: maxChunksPerSource,
        );
        if (candidates.isNotEmpty) {
          best = candidates.first.score;
          if (best >= gate) {
            hits = candidates;
            grounded = true;
          }
        }
      } on Object catch (e) {
        // Retrieval failing should degrade to an ordinary chat, not kill
        // the turn.
        debugPrint('Retrieval failed, answering without context: $e');
      }
    }

    // ---- Conversation history ------------------------------------------
    final prior = turns.sublist(0, turns.length - 1);
    final replay = prior.length > historyTurns
        ? prior.sublist(prior.length - historyTurns)
        : prior;

    final messages = <ChatMessage>[
      ChatMessage('system',
          _systemPrompt(grounded: grounded, computed: computed != null)),
      // Only clean turns are replayed. Retrieved excerpts attach to the
      // current question and are never written into history — otherwise
      // stale context from three questions ago keeps steering the answer,
      // and the window fills with duplicate copies of the same chunks.
      for (final t in replay) ChatMessage(t.role, t.content),
      ChatMessage(
        'user',
        computed != null
            ? _withComputed(question, computed)
            : grounded
                ? _withContext(question, hits)
                : question,
      ),
    ];

    final buffer = StringBuffer();
    final completer = Completer<void>();

    _sub = ollama.chat(model: chat, messages: messages).listen(
      (chunk) {
        if (chunk.thinking != null && chunk.thinking!.isNotEmpty) {
          streamingThinking.value += chunk.thinking!;
        }
        if (chunk.content != null && chunk.content!.isNotEmpty) {
          buffer.write(chunk.content);
          streamingText.value = buffer.toString();
        }
      },
      onError: (Object e) {
        error = '$e';
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    await completer.future;
    await _sub?.cancel();
    _sub = null;

    final answer = buffer.toString().trim();
    turns.add(Turn(
      role: 'assistant',
      content: answer.isEmpty ? (error ?? '(no response)') : answer,
      sources: hits,
      grounded: grounded,
      topScore: best,
      gate: gate,
      computed: computed,
      searchedFor: searchedFor,
    ));
    streamingText.value = '';
    streamingThinking.value = '';
    isStreaming = false;
    notifyListeners();
  }

  /// Aborts generation. Cancelling the subscription closes the HTTP
  /// connection, so Ollama stops producing tokens instead of finishing
  /// the response into a void.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (!isStreaming) return;
    final partial = streamingText.value.trim();
    if (partial.isNotEmpty) {
      turns.add(Turn(role: 'assistant', content: '$partial\n\n_(stopped)_'));
    }
    streamingText.value = '';
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
    _sub?.cancel();
    streamingText.dispose();
    streamingThinking.dispose();
    ollama.close();
    super.dispose();
  }
}
