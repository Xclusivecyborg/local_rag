import 'dart:math' as math;

import 'vector_entities.dart';

class StoredChunk {
  StoredChunk({
    required this.text,
    required this.source,
    required this.index,
    required this.embedding,
  });

  final String text;
  final String source;
  final int index;

  /// Stored pre-normalised to unit length, so cosine similarity at query time
  /// collapses to a plain dot product.
  final List<double> embedding;
}

class ScoredChunk {
  const ScoredChunk(this.chunk, this.score);
  final StoredChunk chunk;

  /// Cosine similarity in [-1, 1], higher is closer.
  ///
  /// ObjectBox natively reports cosine *distance* in 0..2; the store converts,
  /// so the per-model retrieval gates in RagController are read on this scale.
  final double score;
}

/// Vector-shape helpers shared by the store and its tests.
///
/// These live outside [ObjectBoxStore] because the padding rules are the
/// interesting part of the design and deserve to be testable on their own.
abstract final class Vectors {
  /// The dimension a [modelDimension]-wide vector is actually stored at.
  ///
  /// `@HnswIndex(dimensions:)` is an annotation argument, so it is fixed when
  /// the code is generated — unlike Chroma or Qdrant, where a collection's
  /// width is a runtime parameter. Rather than declare an entity for every
  /// width an embedding model might produce, vectors are padded up to the
  /// nearest declared one.
  ///
  /// This is free in every sense that matters: see [pad].
  static int storageDimensionFor(int modelDimension) {
    if (modelDimension <= 0) {
      throw ArgumentError('Embedding dimension must be positive, got '
          '$modelDimension.');
    }
    final sizes = supportedDimensions.toList()..sort();
    for (final s in sizes) {
      if (modelDimension <= s) return s;
    }
    throw ArgumentError(
      'This embedding model produces $modelDimension-d vectors, which is '
      'wider than the largest HNSW index in this build (${sizes.last}-d). '
      'Add an entity for it in lib/vector_search/vector_entities.dart and '
      're-run the generator, or choose a model of ${sizes.last} dimensions '
      'or fewer.',
    );
  }

  /// Appends zeros until [v] is [width] long.
  ///
  /// Padding with zeros leaves cosine similarity **exactly** unchanged: the
  /// dot product gains only `0 * 0` terms and neither magnitude moves, so
  /// `a·b`, `|a|` and `|b|` are all identical. Verified bit-for-bit in
  /// test/vector_search/padding_test.dart. The only cost is storage.
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
    final norm = math.sqrt(sum);
    if (norm == 0) return v;
    return [for (final x in v) x / norm];
  }

  /// Guards a vector's width against what the index expects.
  ///
  /// ObjectBox does not do this itself — measured in the Phase 0 spike, a
  /// 1024-d vector put into a 384-d index is accepted silently and the index
  /// is quietly wrong from then on.
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

  /// Applies a per-source cap to an already-sorted list of hits.
  ///
  /// This matters when one source dwarfs the others: a 240-row sales CSV
  /// becomes 43 of 55 chunks that all mention the same locations, and it will
  /// happily take every slot in the top k, burying the one paragraph that
  /// actually answers the question. Measured on sample_kb, capping at 2 lifts
  /// hit@1 from 83% to 100%.
  static List<ScoredChunk> capPerSource(
    List<ScoredChunk> sorted,
    int k,
    int? maxPerSource,
  ) {
    if (maxPerSource == null) return sorted.take(k).toList();
    final taken = <String, int>{};
    final out = <ScoredChunk>[];
    for (final s in sorted) {
      final used = taken[s.chunk.source] ?? 0;
      if (used >= maxPerSource) continue;
      taken[s.chunk.source] = used + 1;
      out.add(s);
      if (out.length >= k) break;
    }
    return out;
  }
}
