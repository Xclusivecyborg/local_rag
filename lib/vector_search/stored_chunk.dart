import 'dart:math' as math;

import 'vector_entities.dart';

/// A chunk as read back from the index.
class StoredChunk {
  StoredChunk({
    required this.text,
    required this.source,
    required this.index,
    required this.embedding,
    this.start = 0,
    this.end = 0,
  });

  final String text;
  final String source;
  final int index;

  /// Character range in [source]. Both are 0 on indexes built before this was
  /// saved, so treat `start == end` as "not recorded".
  final int start;
  final int end;

  /// Normalised to length 1, so cosine similarity is a plain dot product.
  final List<double> embedding;
}

class ScoredChunk {
  const ScoredChunk(this.chunk, this.score);
  final StoredChunk chunk;

  /// Cosine similarity, from -1 to 1. Higher is more similar.
  final double score;
}

/// Vector helpers used by the index, kept separate so they can be tested.
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

  /// The first [k] of [sorted], taking at most [maxPerSource] from any one
  /// file. Stops one large file (like a 240-row CSV) filling every slot;
  /// on sample_kb a cap of 2 lifts hit@1 from 83% to 100%.
  static List<ScoredChunk> capPerSource(
    List<ScoredChunk> sorted,
    int k,
    int? maxPerSource,
  ) {
    if (maxPerSource == null) return sorted.take(k).toList();
    final perSource = <String, int>{};
    final kept = <ScoredChunk>[];
    for (final hit in sorted) {
      final used = perSource[hit.chunk.source] ?? 0;
      if (used >= maxPerSource) continue;
      perSource[hit.chunk.source] = used + 1;
      kept.add(hit);
      if (kept.length >= k) break;
    }
    return kept;
  }
}
