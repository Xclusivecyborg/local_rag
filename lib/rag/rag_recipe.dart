/// Which RAG this app runs: every optimization is one switch here.
///
/// [naive] is the pipeline every tutorial builds: split, embed, take the top
/// five, paste them into the prompt. [optimized] is the same pipeline with
/// each fix this project measured turned on. Both run through the same
/// [RagPipeline], so any difference in their answers comes from these
/// switches alone. tool/retrieval_quality/before_after.dart measures both.
class RagRecipe {
  const RagRecipe({
    required this.name,
    this.chunkSize = 600,
    this.chunkOverlap = 200,
    this.csvAsProse = true,
    this.useToolCalling = true,
    this.condenseQueries = true,
    this.maxChunksPerSource = 2,
    this.relevanceGate = true,
    this.strictGrounding = true,
    this.guardedPrompt = true,
    this.topK = 5,
  });

  /// Shown in the sidebar, and names this recipe's index folder.
  final String name;

  // ---- Indexing --------------------------------------------------------

  /// Maximum characters per chunk. Smaller chunks are about fewer things, so
  /// they match short questions better: 6 of 12 retrieve at 1200, 10 of 12
  /// at 600.
  final int chunkSize;
  final int chunkOverlap;

  /// Rewrite CSV rows as labelled sentences before embedding.
  /// `Region: Lagos. Units sold: 48.` gives an embedder something to match;
  /// `2026-01-05,Lagos,Everyday,48` does not.
  final bool csvAsProse;

  // ---- Answering -------------------------------------------------------

  /// Give the model a calculate tool over the CSV files, so totals and
  /// averages are computed over every row by code, not added up by the model
  /// from the five chunks it happened to retrieve.
  final bool useToolCalling;

  /// Rewrite a long question into a short search query before embedding it.
  final bool condenseQueries;

  /// Most chunks any one file may contribute to the top [topK], so a big CSV
  /// cannot crowd out the prose. Null means no cap.
  final int? maxChunksPerSource;

  /// Only show the model excerpts whose score clears the embedding model's
  /// measured threshold, so "Hello" does not pull in the returns policy.
  final bool relevanceGate;

  /// Tell the model not to estimate totals from a partial set of excerpts.
  final bool strictGrounding;

  /// Use the app's system prompt, which tells the model never to invent
  /// company facts. Off, it gets the tutorial's "answer using the excerpts",
  /// and will confidently add up whatever five chunks it was handed.
  final bool guardedPrompt;

  /// Chunks retrieved per question.
  final int topK;

  /// The tutorial pipeline, with every optimization off.
  static const RagRecipe naive = RagRecipe(
    name: 'naive',
    chunkSize: 1200,
    csvAsProse: false,
    useToolCalling: false,
    condenseQueries: false,
    maxChunksPerSource: null,
    relevanceGate: false,
    strictGrounding: false,
    guardedPrompt: false,
  );

  /// Every optimization on.
  static const RagRecipe optimized = RagRecipe(name: 'optimized');

  /// Folder this recipe's index lives in, inside Application Support.
  ///
  /// Each recipe chunks differently, so each needs its own index. Keeping
  /// them apart means switching recipe never forces a re-index. [optimized]
  /// keeps the original `objectbox` folder, so an existing index still loads.
  String get indexFolder =>
      name == 'optimized' ? 'objectbox' : 'objectbox-$name';

  /// File the CSV tables are saved in, next to [indexFolder].
  String get tablesFile =>
      name == 'optimized' ? 'tables.json' : 'tables-$name.json';

  /// Every optimization, grouped by the stage it improves, for the sidebar
  /// and the eval report.
  List<Optimization> get optimizations => [
    Optimization(
      'Small chunks',
      'Cut files into smaller pieces',
      RagStage.indexing,
      enabled: chunkSize <= 600,
      setting: '$chunkSize chars',
    ),
    Optimization(
      'CSV rows as prose',
      'Turn spreadsheet rows into sentences',
      RagStage.indexing,
      enabled: csvAsProse,
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
      'Relevance Filtering',
      'Use only documents relevant to the question, so small talk gets a '
          'natural response.',
      RagStage.retrieval,
      enabled: relevanceGate,
    ),
    Optimization(
      'Use Tool Calling',
      'When you have data that needs to be computed, like CSV tables, '
          'don\'t embed it. Use tool calling to fetch data from it instead.',
      RagStage.answering,
      enabled: useToolCalling,
    ),
    Optimization(
      'Strict Data Grounding',
      'Say “I don’t know” when the available data is insufficient rather '
          'than guessing or estimating.',
      RagStage.answering,
      enabled: strictGrounding,
    ),
    Optimization(
      'Never-invent prompt',
      'Never make up company facts',
      RagStage.answering,
      enabled: guardedPrompt,
    ),
  ];
}

/// The part of the pipeline an optimization improves.
enum RagStage {
  indexing('Indexing'),
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

  /// The value it runs with, e.g. "600 chars", shown even when the
  /// optimization is off if the naive value teaches something (1200 chars).
  /// Null when there is none.
  final String? setting;
}
