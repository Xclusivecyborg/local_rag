import 'dart:io';

import 'package:local_rag/document_indexing/chunker.dart';

import 'objectbox.g.dart';
import 'stored_chunk.dart';
import 'vector_entities.dart';

/// The app's vector index: ObjectBox's HNSW graph, on disk.
///
/// Approximate, and effectively flat in corpus size — measured on real
/// embeddings, query time barely moves between 500 and 8,000 chunks while an
/// exact scan grows linearly. Recall against exact cosine was 98–100% at every
/// size measured, and on sample_kb the two return byte-identical rankings.
///
/// One wrinkle is worth knowing before reading further: `@HnswIndex` fixes a
/// dimension at code-generation time, so unlike Chroma or Qdrant — where a
/// collection's width is a runtime argument — this build can only store the
/// widths declared in [supportedDimensions]. Anything narrower is zero-padded
/// up to the nearest, which leaves cosine similarity exactly unchanged. See
/// [Vectors.storageDimensionFor].
class ObjectBoxStore {
  ObjectBoxStore._(this._store, this.embeddingModel, this.dimension, this._dir)
      : storageDimension = Vectors.storageDimensionFor(dimension),
        _adapter = _adapterFor(
          _store,
          Vectors.storageDimensionFor(dimension),
        );

  final Store _store;
  final Directory _dir;
  final _DimensionAdapter _adapter;

  /// The model these vectors came from, and the width it produces.
  ///
  /// Persisted with the index because vectors are only comparable to other
  /// vectors from the same model. Swap the embedding model and every stored
  /// vector silently becomes meaningless: same numbers, different space. Hence
  /// [isCompatibleWith].
  final String embeddingModel;
  final int dimension;

  /// The width the vectors are physically stored at — [dimension] rounded up
  /// to the nearest declared HNSW index.
  final int storageDimension;

  /// How many extra candidates to pull from the graph when [search] has to
  /// honour a `maxPerSource` cap.
  ///
  /// An exact scan sees every chunk, so it can always fill k slots after
  /// filtering. HNSW returns exactly what you ask for, so asking for k and
  /// then discarding same-source duplicates returns fewer than k. Over-fetch
  /// first, filter second.
  static const int overFetchFactor = 8;

  /// Whether a model of this width can be indexed by this build at all.
  static bool supports(int dimension) {
    try {
      Vectors.storageDimensionFor(dimension);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  /// The database directory, derived from the app's index path.
  static Directory directoryFor(File indexFile) =>
      Directory('${indexFile.parent.path}/objectbox');

  /// Opens an existing index, or null if [dir] holds no usable one.
  ///
  /// Returns null rather than throwing on a corrupt or older database — the
  /// caller's answer to both is the same: re-index.
  static Future<ObjectBoxStore?> open(Directory dir) async {
    if (!await dir.exists()) return null;
    Store? store;
    try {
      store = await openStore(directory: dir.path);
      final meta = store.box<IndexMeta>().getAll();
      if (meta.isEmpty) {
        store.close();
        return null;
      }
      final m = meta.first;
      if (!supports(m.dimension)) {
        store.close();
        return null;
      }
      return ObjectBoxStore._(store, m.embeddingModel, m.dimension, dir);
    } on Object {
      store?.close();
      return null;
    }
  }

  /// Creates an empty index at [dir], discarding anything already there.
  ///
  /// Throws [ArgumentError] when [dimension] is wider than any declared HNSW
  /// index; the message names the file to edit.
  static Future<ObjectBoxStore> create(
    Directory dir, {
    required String embeddingModel,
    required int dimension,
  }) async {
    Vectors.storageDimensionFor(dimension); // throws with guidance if too wide
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final store = await openStore(directory: dir.path);
    store.box<IndexMeta>().put(IndexMeta()
      ..embeddingModel = embeddingModel
      ..dimension = dimension);
    return ObjectBoxStore._(store, embeddingModel, dimension, dir);
  }

  int get size => _adapter.count();
  bool get isEmpty => size == 0;
  Set<String> get sources => _adapter.sources();

  /// How many chunks each file contributed.
  ///
  /// Worth having because "5 of 43 chunks came from the CSV" is the shape of
  /// the aggregation problem, and it cannot be seen from [sources] alone.
  Map<String, int> get chunkCountsBySource => _adapter.countsBySource();

  bool isCompatibleWith(String model) => model == embeddingModel;

  void addAll(List<Chunk> source, List<List<double>> embeddings) {
    if (source.length != embeddings.length) {
      throw ArgumentError(
        'chunk/embedding count mismatch: '
        '${source.length} vs ${embeddings.length}',
      );
    }
    final rows = <StoredChunk>[];
    for (var i = 0; i < source.length; i++) {
      Vectors.checkDimension(embeddings[i].length, dimension, isQuery: false);
      rows.add(StoredChunk(
        text: source[i].text,
        source: source[i].source,
        index: source[i].index,
        embedding: Vectors.pad(
          Vectors.normalise(embeddings[i]),
          storageDimension,
        ),
      ));
    }
    _adapter.putAll(rows);
  }

  /// Returns the [k] closest chunks to [queryEmbedding], best first.
  List<ScoredChunk> search(
    List<double> queryEmbedding, {
    int k = 5,
    int? maxPerSource,
  }) {
    if (isEmpty) return const [];
    Vectors.checkDimension(queryEmbedding.length, dimension, isQuery: true);
    final q = Vectors.pad(
      Vectors.normalise(queryEmbedding),
      storageDimension,
    );
    final want = maxPerSource == null ? k : k * overFetchFactor;
    return Vectors.capPerSource(_adapter.nearest(q, want, dimension), k,
        maxPerSource);
  }

  /// ObjectBox writes on `put`, so there is nothing to flush. The metadata row
  /// is rewritten anyway so an index that was created and never re-opened
  /// still identifies itself.
  Future<void> save(File indexFile) async {
    final box = _store.box<IndexMeta>();
    final existing = box.getAll();
    box.put((existing.isEmpty ? IndexMeta() : existing.first)
      ..embeddingModel = embeddingModel
      ..dimension = dimension);
  }

  /// Releases the native handle and the lock on the database directory.
  /// Dropping the reference without calling this leaks both, and the next
  /// open of the same directory fails.
  void close() => _store.close();

  /// Size on disk.
  int get diskBytes {
    if (!_dir.existsSync()) return 0;
    var total = 0;
    for (final f in _dir.listSync(recursive: true)) {
      if (f is File) total += f.lengthSync();
    }
    return total;
  }

  static _DimensionAdapter _adapterFor(Store store, int storageDimension) =>
      switch (storageDimension) {
        384 => _DimensionAdapter.v384(store),
        768 => _DimensionAdapter.v768(store),
        1024 => _DimensionAdapter.v1024(store),
        _ => throw ArgumentError('no entity for $storageDimension-d vectors'),
      };
}

/// Dispatch for the per-dimension entities.
///
/// Vec384/Vec768/Vec1024 cannot share a base class — ObjectBox entities do not
/// inherit fields — and their generated query properties (`Vec384_.vector` and
/// friends) are separate statics. But they all implement [VecRow], so reading a
/// row is written once. What remains per dimension is only what genuinely
/// differs: the box, two query properties, and the constructor.
class _DimensionAdapter {
  _DimensionAdapter({
    required this.count,
    required this.sources,
    required this.countsBySource,
    required this.putAll,
    required this.nearest,
  });

  final int Function() count;
  final Set<String> Function() sources;
  final Map<String, int> Function() countsBySource;
  final void Function(List<StoredChunk>) putAll;

  /// `modelDimension` trims the stored vector back to what the model produced,
  /// so a caller never sees the padding.
  final List<ScoredChunk> Function(List<double> q, int k, int modelDimension)
      nearest;

  static _DimensionAdapter forEntity<T extends VecRow>({
    required Box<T> box,
    required QueryHnswProperty<T> vector,
    required QueryStringProperty<T> source,
    required T Function(StoredChunk) toEntity,
  }) =>
      _DimensionAdapter(
        count: box.count,
        sources: () => _sourceValues(box, source, distinct: true).toSet(),
        countsBySource: () {
          final counts = <String, int>{};
          for (final s in _sourceValues(box, source, distinct: false)) {
            counts[s] = (counts[s] ?? 0) + 1;
          }
          return counts;
        },
        putAll: (rows) => box.putMany([for (final r in rows) toEntity(r)]),
        nearest: (q, k, modelDimension) {
          final query = box.query(vector.nearestNeighborsF32(q, k)).build();
          final found = query.findWithScores();
          query.close();
          return [
            for (final r in found)
              ScoredChunk(
                StoredChunk(
                  text: r.object.text,
                  source: r.object.source,
                  index: r.object.chunkIndex,
                  embedding:
                      (r.object.vector ?? const <double>[]).take(modelDimension)
                          .toList(growable: false),
                ),
                // ObjectBox reports cosine *distance* in 0..2 (0 = identical
                // direction). The app's gates are cosine *similarity*, and the
                // conversion is verified against an exact dot product in
                // test/vector_search/objectbox_store_test.dart.
                1.0 - r.score,
              ),
          ];
        },
      );

  static List<String> _sourceValues<T>(
    Box<T> box,
    QueryStringProperty<T> source, {
    required bool distinct,
  }) {
    final query = box.query().build();
    final pq = query.property(source)..distinct = distinct;
    final out = pq.find();
    pq.close();
    query.close();
    return out;
  }

  factory _DimensionAdapter.v384(Store store) => forEntity<Vec384>(
        box: store.box<Vec384>(),
        vector: Vec384_.vector,
        source: Vec384_.source,
        toEntity: (r) => Vec384()
          ..text = r.text
          ..source = r.source
          ..chunkIndex = r.index
          ..vector = r.embedding,
      );

  factory _DimensionAdapter.v768(Store store) => forEntity<Vec768>(
        box: store.box<Vec768>(),
        vector: Vec768_.vector,
        source: Vec768_.source,
        toEntity: (r) => Vec768()
          ..text = r.text
          ..source = r.source
          ..chunkIndex = r.index
          ..vector = r.embedding,
      );

  factory _DimensionAdapter.v1024(Store store) => forEntity<Vec1024>(
        box: store.box<Vec1024>(),
        vector: Vec1024_.vector,
        source: Vec1024_.source,
        toEntity: (r) => Vec1024()
          ..text = r.text
          ..source = r.source
          ..chunkIndex = r.index
          ..vector = r.embedding,
      );
}
