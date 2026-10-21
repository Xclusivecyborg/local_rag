import 'dart:math' as math;

import 'vector_entities.dart';

/// Vector helpers used by the ObjectBox index, kept separate so they can be
/// tested.
abstract final class Vectors {
  /// The width a [modelDimension]-wide vector is stored at: the smallest
  /// supported width that fits it.
  ///
  /// ObjectBox fixes an index's width when code is generated, so instead of
  /// one index per possible model width, vectors are padded up (see [pad]).
  static int storageDimensionFor(int modelDimension) {
    if (modelDimension <= 0) {
      throw ArgumentError(
        'Embedding dimension must be positive, got $modelDimension.',
      );
    }
    final sizes = supportedDimensions.toList()..sort();
    for (final size in sizes) {
      if (modelDimension <= size) return size;
    }
    throw ArgumentError(
      'This embedding model produces $modelDimension-d vectors, which is '
      'wider than the largest HNSW index in this build (${sizes.last}-d). '
      'Add an entity for it in lib/vector_search/vector_entities.dart and '
      're-run the generator, or choose a model of ${sizes.last} dimensions '
      'or fewer.',
    );
  }

  /// Appends zeros until [v] is [width] long. Zeros add nothing to a dot
  /// product or a length, so cosine similarity is exactly unchanged.
  static List<double> pad(List<double> v, int width) {
    if (v.length == width) return v;
    if (v.length > width) {
      throw ArgumentError('Cannot pad a ${v.length}-d vector down to $width.');
    }
    return [...v, ...List<double>.filled(width - v.length, 0.0)];
  }

  static List<double> normalise(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final length = math.sqrt(sum);
    if (length == 0) return v;
    return [for (final x in v) x / length];
  }

  /// Dot product over the shorter of the two; for normalised vectors this is
  /// cosine similarity.
  static double dot(List<double> a, List<double> b) {
    var sum = 0.0;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  /// Throws if a vector's width does not match the index. ObjectBox accepts
  /// the wrong width silently and returns wrong results from then on.
  static void checkDimension(int got, int expected, {required bool isQuery}) {
    if (got == expected) return;
    throw StateError(
      isQuery
          ? 'Query embedding is $got-d but the index is $expected-d. '
                'Re-index with the current embedding model.'
          : 'Embedding dimension mismatch: expected $expected, got $got. '
                'The embedding model changed underneath this index.',
    );
  }
}
