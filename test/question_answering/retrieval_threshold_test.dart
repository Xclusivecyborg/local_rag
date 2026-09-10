import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/question_answering/model_preferences.dart';
import 'package:local_rag/question_answering/retrieval_settings.dart';

void main() {
  test('the gates were measured at the current chunk size', () {
    // A tripwire, not a behaviour test. Every value in measuredThresholds is
    // only valid for the chunk size it was calibrated at: halving the chunk
    // size from 1200 to 600 moved mxbai from 0.57 to 0.47 and MiniLM from
    // 0.29 to 0.22, because a shorter chunk is about fewer things and matches
    // a specific question more strongly.
    //
    // Nothing else in the codebase couples these two, and the failure is
    // silent — a stale gate that is too high blocks real questions while the
    // app reports "I don't have that information". If you are here because
    // this test failed, you changed the chunk size; re-run
    //
    //   flutter test tool/retrieval_quality/compare_embedders.dart
    //
    // and update RetrievalSettings.measuredThresholds before changing this number.
    expect(defaultChunkSize, 600,
        reason: 'chunk size changed — the retrieval gates must be re-measured');
  });

  group('per-model retrieval threshold', () {
    test('each measured model gets its own gate', () {
      expect(RetrievalSettings.thresholdFor('mxbai-embed-large:latest'), 0.47);
      expect(RetrievalSettings.thresholdFor('locusai/all-minilm-l6-v2:latest'), 0.22);
    });

    test('the default embedding model has a measured gate, not a guess', () {
      // The app ships pointing at this model. If it ever falls through to the
      // permissive default, retrieval is running on an unverified number.
      for (final name in ModelPreferences.embedding) {
        expect(RetrievalSettings.hasMeasuredThreshold('$name:latest'), isTrue,
            reason: '$name is a shipping default with no measured gate — run '
                'tool/retrieval_quality/compare_embedders.dart');
      }
    });

    test('a missing tag resolves when the base name is unambiguous', () {
      expect(RetrievalSettings.thresholdFor('mxbai-embed-large'), 0.47);
      expect(RetrievalSettings.thresholdFor('locusai/all-minilm-l6-v2'), 0.22);
    });

    test('an ambiguous base name falls back rather than guessing', () {
      // Two tags of one model measured at different gates. Picking either
      // would be a coin flip that silently changes retrieval behaviour.
      //
      // Supplied explicitly rather than read from measuredThresholds, which
      // holds no ambiguous pair today — a test written against that would
      // pass by accident and check nothing.
      const ambiguous = {'all-minilm:22m': 0.29, 'all-minilm:33m': 0.22};
      expect(RetrievalSettings.thresholdFor('all-minilm', thresholds: ambiguous),
          RetrievalSettings.unmeasuredThreshold);
      expect(RetrievalSettings.thresholdFor('all-minilm:22m', thresholds: ambiguous), 0.29,
          reason: 'an exact match is never ambiguous');
    });

    test('agreeing tags of one model still resolve', () {
      const agreeing = {'foo:a': 0.3, 'foo:b': 0.3};
      expect(RetrievalSettings.thresholdFor('foo', thresholds: agreeing), 0.3);
    });

    test('an unknown model falls back permissively', () {
      final t = RetrievalSettings.thresholdFor('nomic-embed-text');
      expect(t, RetrievalSettings.unmeasuredThreshold);
      // Too high silently disables retrieval; too low is merely visible noise.
      // The fallback must err low.
      expect(t, lessThan(0.22));
    });

    test('null model does not throw', () {
      expect(RetrievalSettings.thresholdFor(null),
          RetrievalSettings.unmeasuredThreshold);
    });

    test('hasMeasuredThreshold distinguishes known from guessed', () {
      expect(RetrievalSettings.hasMeasuredThreshold('mxbai-embed-large:latest'),
          isTrue);
      expect(RetrievalSettings.hasMeasuredThreshold('nomic-embed-text'), isFalse);
      expect(RetrievalSettings.hasMeasuredThreshold(null), isFalse);
    });

    test('gates differ enough between models to matter', () {
      // The failure this map prevents: 0.221 is the WORST score a real
      // question gets under MiniLM. Judged by mxbai's gate it fails silently;
      // by its own it passes.
      const worstRealForMiniLm = 0.221;
      expect(worstRealForMiniLm,
          lessThan(RetrievalSettings.thresholdFor('mxbai-embed-large:latest')));
      expect(
          worstRealForMiniLm,
          greaterThanOrEqualTo(
              RetrievalSettings.thresholdFor('locusai/all-minilm-l6-v2:latest')));
    });
  });
}
