import 'dart:io';

import 'package:local_rag/document_indexing/chunker.dart';

import 'objectbox.g.dart';
import 'stored_chunk.dart';
import 'vector_entities.dart';

/// The vector index: an ObjectBox HNSW graph stored on disk.
///
/// ObjectBox fixes the vector width at code-generation time, so only the
/// widths in [supportedDimensions] can be stored. Narrower vectors are
/// zero-padded up to the next one, which leaves cosine similarity unchanged.
class ObjectBoxStore {
  ObjectBoxStore._(this._store, this.embeddingModel, this.dimension, this._dir)
    : storageDimension = Vectors.storageDimensionFor(dimension),
      _entity = _EntityAccess.forWidth(
        _store,
        Vectors.storageDimensionFor(dimension),
      );

  final Store _store;
  final Directory _dir;
  final _EntityAccess _entity;

  /// The model that produced these vectors. Vectors from different models
  /// cannot be compared, hence [isCompatibleWith].
  final String embeddingModel;
  final int dimension;

  /// [dimension] rounded up to the nearest supported width.
  final int storageDimension;

  /// With a per-file cap, HNSW is asked for this many times `k` candidates so
  /// enough are left after the cap to fill `k`.
  static const int _overFetchFactor = 8;

  /// Whether this build can index vectors of this width at all.
  static bool supports(int dimension) =>
      supportedDimensions.any((width) => dimension > 0 && dimension <= width);

  /// Where the database lives inside the app's support directory.
  static Directory directoryIn(Directory supportDir) =>
      Directory('${supportDir.path}/objectbox');

  /// Opens the index in [dir], or returns null if there is no usable one
  /// (missing, corrupt, or from an older build). Either way: re-index.
  static Future<ObjectBoxStore?> open(Directory dir) async {
    if (!await dir.exists()) return null;
    Store? store;
    try {
      store = await openStore(directory: dir.path);
      final meta = store.box<IndexMeta>().getAll().firstOrNull;
      if (meta == null || !supports(meta.dimension)) {
        store.close();
        return null;
      }
      return ObjectBoxStore._(store, meta.embeddingModel, meta.dimension, dir);
    } on Object {
      store?.close();
      return null;
    }
  }

  /// Creates an empty index in [dir], deleting anything already there.
  /// Throws [ArgumentError] if [dimension] is wider than any supported width.
  static Future<ObjectBoxStore> create(
    Directory dir, {
    required String embeddingModel,
    required int dimension,
  }) async {
    Vectors.storageDimensionFor(dimension); // throws if too wide
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final store = await openStore(directory: dir.path);
    store.box<IndexMeta>().put(
      IndexMeta()
        ..embeddingModel = embeddingModel
        ..dimension = dimension,
    );
    return ObjectBoxStore._(store, embeddingModel, dimension, dir);
  }

  int get size => _entity.count();
  bool get isEmpty => size == 0;
  Set<String> get sources => _entity.sources();
  Map<String, int> get chunkCountsBySource => _entity.countsBySource();

  bool isCompatibleWith(String model) => model == embeddingModel;

  void addAll(List<Chunk> chunks, List<List<double>> embeddings) {
    if (chunks.length != embeddings.length) {
      throw ArgumentError(
        'chunk/embedding count mismatch: '
        '${chunks.length} vs ${embeddings.length}',
      );
    }
    final rows = <StoredChunk>[];
    for (var i = 0; i < chunks.length; i++) {
      Vectors.checkDimension(embeddings[i].length, dimension, isQuery: false);
      rows.add(
        StoredChunk(
          text: chunks[i].text,
          source: chunks[i].source,
          index: chunks[i].index,
          start: chunks[i].start,
          end: chunks[i].end,
          embedding: Vectors.pad(
            Vectors.normalise(embeddings[i]),
            storageDimension,
          ),
        ),
      );
    }
    _entity.putAll(rows);
  }

  /// The [k] chunks closest to [queryEmbedding], best first, with at most
  /// [maxPerSource] from any one file.
  List<ScoredChunk> search(
    List<double> queryEmbedding, {
    int k = 5,
    int? maxPerSource,
  }) {
    if (isEmpty) return const [];
    Vectors.checkDimension(queryEmbedding.length, dimension, isQuery: true);
    final query = Vectors.pad(
      Vectors.normalise(queryEmbedding),
      storageDimension,
    );
    final candidates = maxPerSource == null ? k : k * _overFetchFactor;
    return Vectors.capPerSource(
      _entity.nearest(query, candidates, dimension),
      k,
      maxPerSource,
    );
  }

  /// Releases the database. Without this the folder stays locked and the
  /// next open of it fails.
  void close() => _store.close();

  int get diskBytes {
    if (!_dir.existsSync()) return 0;
    var total = 0;
    for (final f in _dir.listSync(recursive: true)) {
      if (f is File) total += f.lengthSync();
    }
    return total;
  }
}

/// Reads and writes whichever entity (Vec384, Vec768, Vec1024) matches the
/// index width. The entities cannot share a base class, so each gets its own
/// box and query properties, wrapped here as functions.
class _EntityAccess {
  _EntityAccess({
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

  /// Nearest neighbours of `query`; vectors are trimmed back to
  /// `modelDimension` so callers never see the padding.
  final List<ScoredChunk> Function(
    List<double> query,
    int k,
    int modelDimension,
  )
  nearest;

  static _EntityAccess forWidth(Store store, int width) => switch (width) {
    384 => _for<Vec384>(
      box: store.box<Vec384>(),
      vector: Vec384_.vector,
      source: Vec384_.source,
      create: Vec384.new,
    ),
    768 => _for<Vec768>(
      box: store.box<Vec768>(),
      vector: Vec768_.vector,
      source: Vec768_.source,
      create: Vec768.new,
    ),
    1024 => _for<Vec1024>(
      box: store.box<Vec1024>(),
      vector: Vec1024_.vector,
      source: Vec1024_.source,
      create: Vec1024.new,
    ),
    _ => throw ArgumentError('no entity for $width-d vectors'),
  };

  static _EntityAccess _for<T extends VecRow>({
    required Box<T> box,
    required QueryHnswProperty<T> vector,
    required QueryStringProperty<T> source,
    required T Function() create,
  }) => _EntityAccess(
    count: box.count,
    sources: () => _sourceValues(box, source, distinct: true).toSet(),
    countsBySource: () {
      final counts = <String, int>{};
      for (final s in _sourceValues(box, source, distinct: false)) {
        counts[s] = (counts[s] ?? 0) + 1;
      }
      return counts;
    },
    putAll: (rows) => box.putMany([
      for (final r in rows)
        create()
          ..text = r.text
          ..source = r.source
          ..chunkIndex = r.index
          ..chunkStart = r.start
          ..chunkEnd = r.end
          ..vector = r.embedding,
    ]),
    nearest: (query, k, modelDimension) {
      final q = box.query(vector.nearestNeighborsF32(query, k)).build();
      final found = q.findWithScores();
      q.close();
      return [
        for (final r in found)
          ScoredChunk(
            StoredChunk(
              text: r.object.text,
              source: r.object.source,
              index: r.object.chunkIndex,
              start: r.object.chunkStart,
              end: r.object.chunkEnd,
              embedding: (r.object.vector ?? const <double>[])
                  .take(modelDimension)
                  .toList(growable: false),
            ),
            // ObjectBox reports cosine distance (0 to 2); convert to similarity.
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
    final property = query.property(source)..distinct = distinct;
    final values = property.find();
    property.close();
    query.close();
    return values;
  }
}
