// Zero-padding is what lets one fixed-width HNSW index serve every embedding
// model narrower than it.
//
// The whole idea rests on one claim: appending zeros does not change cosine
// similarity. If that were even slightly false, every retrieval gate in the app
// would be measuring something different from what it was calibrated against.
// So the claim is tested directly, not assumed.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/vector_search/vectors.dart';

double cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

List<double> randomVector(int n, int seed) {
  final rng = math.Random(seed);
  return [for (var i = 0; i < n; i++) rng.nextDouble() * 2 - 1];
}

void main() {
  group('padding preserves cosine similarity', () {
    test('exactly, to the last bit, at every width', () {
      for (final from in [1, 7, 128, 383, 384, 500, 767]) {
        for (final to in [768, 1024]) {
          if (from > to) continue;
          final a = randomVector(from, from * 31 + to);
          final b = randomVector(from, from * 17 + to);
          expect(
            cosine(Vectors.pad(a, to), Vectors.pad(b, to)),
            cosine(a, b),
            reason: 'padding ${from}d -> ${to}d must not move the score',
          );
        }
      }
    });

    test('and the score is unchanged after normalising too', () {
      final a = Vectors.normalise(randomVector(384, 1));
      final b = Vectors.normalise(randomVector(384, 2));
      expect(
        cosine(Vectors.pad(a, 1024), Vectors.pad(b, 1024)),
        cosine(a, b),
      );
    });

    test('ranking order survives padding', () {
      // The property that actually matters: not just that scores are equal,
      // but that the winner does not change.
      final q = randomVector(384, 99);
      final corpus = [for (var i = 0; i < 30; i++) randomVector(384, i)];
      int best(List<double> query, List<List<double>> docs) {
        var bi = 0;
        var bs = -2.0;
        for (var i = 0; i < docs.length; i++) {
          final s = cosine(query, docs[i]);
          if (s > bs) {
            bs = s;
            bi = i;
          }
        }
        return bi;
      }

      expect(
        best(Vectors.pad(q, 1024), [for (final d in corpus) Vectors.pad(d, 1024)]),
        best(q, corpus),
      );
    });
  });

  group('choosing the storage width', () {
    test('rounds up to the nearest declared index', () {
      expect(Vectors.storageDimensionFor(384), 384);
      expect(Vectors.storageDimensionFor(768), 768);
      expect(Vectors.storageDimensionFor(1024), 1024);
      expect(Vectors.storageDimensionFor(512), 768, reason: 'rounds up');
      expect(Vectors.storageDimensionFor(1), 384);
      expect(Vectors.storageDimensionFor(769), 1024);
    });

    test('a model wider than every index fails with a fix in the message', () {
      // qwen3-embedding at 2560-d, say. Better a clear error naming the file to
      // edit than a silent fallback to something slower.
      expect(
        () => Vectors.storageDimensionFor(2560),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('vector_entities.dart'), contains('2560')),
        )),
      );
    });

    test('a nonsense dimension is rejected', () {
      expect(() => Vectors.storageDimensionFor(0), throwsA(isA<ArgumentError>()));
      expect(() => Vectors.storageDimensionFor(-4), throwsA(isA<ArgumentError>()));
    });
  });

  test('padding never silently truncates', () {
    expect(() => Vectors.pad(randomVector(1024, 5), 384),
        throwsA(isA<ArgumentError>()));
  });
}
