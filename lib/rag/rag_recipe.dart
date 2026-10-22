/// Which RAG this app runs: every optimization is one switch here.
///
/// [normal] is the pipeline every tutorial builds: split, embed, take the top
/// five, paste them into the prompt. [optimized] is the same pipeline with
/// each fix this project measured turned on. Both run through the same
/// [RagPipeline], so any difference in their answers comes from these
/// switches alone. tool/retrieval_quality/before_after.dart measures both.
class RagRecipe {
  const RagRecipe({
    required this.name,
    this.chunkSize = 600,
    this.chunkOverlap = 200,
    this.useToolCalling = true,
    this.condenseQueries = true,
    this.maxChunksPerSource = 2,
    this.relevanceGate = true,
    this.fineTunedPrompt = true,
    this.topK = 5,
  });

  /// Shown in the sidebar, and names this recipe's index folder.
  final String name;

  // ---- Indexing --------------------------------------------------------

  /// Maximum characters per chunk, the same in both recipes. Size is a
  /// trade-off rather than a fix: 600 retrieves more short questions than
  /// 1200 (10 of 12 against 6 of 12), but a 1200-character chunk sometimes
  /// holds two sections a question needs together.
  final int chunkSize;
  final int chunkOverlap;

  // ---- Answering -------------------------------------------------------

  /// Keep CSV files out of the index and give the model a calculate tool
  /// instead, so totals and averages are computed over every row by code,
  /// not added up by the model from the five chunks it happened to retrieve.
  final bool useToolCalling;

  /// Rewrite a long question into a short search query before embedding it.
  final bool condenseQueries;

  /// Most chunks any one file may contribute to the top [topK], so a big CSV
  /// cannot crowd out the prose. Null means no cap.
  final int? maxChunksPerSource;

  /// Only show the model excerpts whose score clears the embedding model's
  /// measured threshold, so "Hello" does not pull in the returns policy.
  final bool relevanceGate;

  /// Use the app's system prompt, which tells the model never to invent
  /// company facts, to ask for a detail a question leaves out, and not to
  /// estimate totals from a partial set of excerpts. Off, it gets the
  /// tutorial's "answer using the excerpts", and will confidently add up
  /// whatever five chunks it was handed.
  final bool fineTunedPrompt;

  /// Chunks retrieved per question.
  final int topK;

  /// The tutorial pipeline, with every optimization off.
  static const RagRecipe normal = RagRecipe(
    name: 'normal',
    useToolCalling: false,
    condenseQueries: false,
    maxChunksPerSource: null,
    relevanceGate: false,
    fineTunedPrompt: false,
  );

  /// Every optimization on.
  static const RagRecipe optimized = RagRecipe(name: 'optimized');

  /// Folder this recipe's index lives in, inside Application Support.
  ///
  /// Normal embeds the CSV rows and optimized does not, so each needs its
  /// own index. Keeping them apart means switching recipe never forces a
  /// re-index. [optimized] keeps the original `objectbox` folder, so an
  /// existing index still loads.
  String get indexFolder =>
      name == 'optimized' ? 'objectbox' : 'objectbox-$name';

  /// File the CSV tables are saved in, next to [indexFolder].
  String get tablesFile =>
      name == 'optimized' ? 'tables.json' : 'tables-$name.json';

  /// Every optimization, in the order the talk introduces them, for the
  /// sidebar (which groups them by stage) and the eval report.
  List<Optimization> get optimizations => [
    Optimization(
      'Fine tune prompts',
      'Never make up company facts, and ask when a question leaves out '
          'a detail',
      RagStage.answering,
      enabled: fineTunedPrompt,
    ),
    Optimization(
      'Query condensing',
      'Shorten and optimize long questions first',
      RagStage.retrieval,
      enabled: condenseQueries,
    ),
    Optimization(
      'Per-file cap',
      'Cap the number of matches from each file so one large file '
          'doesn\'t dominate the result set',
      RagStage.retrieval,
      enabled: maxChunksPerSource != null,
      setting: maxChunksPerSource == null
          ? null
          : '$maxChunksPerSource per file',
    ),
    Optimization(
      'Relevance filtering',
      'Use only documents relevant to the question, so small talk gets a '
          'natural response.',
      RagStage.retrieval,
      enabled: relevanceGate,
    ),
    Optimization(
      'Tool calling',
      'When you have data that needs to be computed, like CSV tables, '
          'don\'t embed it. Use tool calling to fetch data from it instead.',
      RagStage.answering,
      enabled: useToolCalling,
    ),
  ];
}

/// The part of the pipeline an optimization improves.
enum RagStage {
  retrieval('Retrieval'),
  answering('Answering');

  const RagStage(this.label);
  final String label;
}

/// One switch in a [RagRecipe], described for display.
class Optimization {
  const Optimization(
    this.label,
    this.description,
    this.stage, {
    required this.enabled,
    this.setting,
  });

  /// The technical name, e.g. "Query condensing".
  final String label;

  /// What it does, in plain English, e.g. "Shorten and optimize long
  /// questions first".
  final String description;
  final RagStage stage;
  final bool enabled;

  /// The value it runs with, e.g. "2 per file". Null when there is none.
  final String? setting;
}
