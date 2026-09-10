/// Settings that decide which retrieved chunks the chat model gets to see.
abstract final class RetrievalSettings {
  /// Chunks fetched per question.
  static const int topK = 5;

  /// Most chunks any one file may contribute to the [topK].
  static const int maxChunksPerSource = 2;

  /// Minimum similarity score for a chunk to count as relevant.
  ///
  /// Scores are not comparable between embedding models, so each model needs
  /// its own number. Measured on sample_kb (20 on-topic questions against 12
  /// off-topic ones), with the threshold set at the worst on-topic score:
  ///
  /// | model                           | worst on-topic | best off-topic |
  /// |---------------------------------|----------------|----------------|
  /// | mxbai-embed-large:latest        | 0.478          | 0.497          |
  /// | locusai/all-minilm-l6-v2:latest | 0.227          | 0.256          |
  ///
  /// Only valid for the chunk size they were measured at (`defaultChunkSize`).
  /// After changing it, re-measure with
  /// `flutter test tool/retrieval_quality/compare_embedders.dart`.
  static const Map<String, double> measuredThresholds = {
    'mxbai-embed-large:latest': 0.47,
    'locusai/all-minilm-l6-v2:latest': 0.22,
  };

  /// Used for models nobody has measured. Kept low on purpose: too high
  /// silently hides the user's documents, too low only lets small talk pull
  /// in an excerpt, which the UI labels.
  static const double unmeasuredThreshold = 0.15;

  /// The threshold for [model].
  ///
  /// A missing `:tag` is fine when only one measured tag of that model exists.
  /// If several exist with different values, it falls back to
  /// [unmeasuredThreshold] rather than guessing.
  static double thresholdFor(
    String? model, {
    Map<String, double> thresholds = measuredThresholds,
  }) {
    if (model == null) return unmeasuredThreshold;
    final exact = thresholds[model];
    if (exact != null) return exact;

    final baseName = model.split(':').first;
    final sameModel = {
      for (final entry in thresholds.entries)
        if (entry.key.split(':').first == baseName) entry.value,
    };
    return sameModel.length == 1 ? sameModel.first : unmeasuredThreshold;
  }

  static bool hasMeasuredThreshold(String? model) =>
      model != null && thresholdFor(model) != unmeasuredThreshold;
}
