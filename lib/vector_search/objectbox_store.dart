import 'dart:io';

import 'package:rag_blocks/rag_blocks.dart';

import 'objectbox.g.dart';
import 'vector_entities.dart';
import 'vectors.dart';

/// The vector index: ObjectBox HNSW graphs stored on disk.
///
/// Spreadsheet rows and documents live in two separate indexes, each with its
/// own HNSW graph, and a search asks both. Rows from one CSV read almost
/// alike, and in a shared graph that cluster traps the search: built with
/// sales_q1_2026.csv ahead of staff_handbook.md, "How much annual leave?" got
/// only sales rows back in 4 of 5 builds, even at k=40, though the handbook
/// scores 0.635 against the rows' best 0.307. Kept apart, neither can hide
/// the other, at any size.
///
/// ObjectBox fixes the vector width at code-generation time, so only the
/// widths in [supportedDimensions] can be stored. Narrower vectors are
/// zero-padded up to the next one, which leaves cosine similarity unchanged.
class ObjectBoxStore implements VectorStore {
  ObjectBoxStore._(
    this._documents,
    this._tables,
    this.embeddingModel,
    this.dimension,
    this._dir,
  ) : storageDimension = Vectors.storageDimensionFor(dimension) {
    _shelves = [
      for (final store in [_documents, _tables])
        _EntityAccess.forWidth(store, storageDimension),
    ];
  }

  final Store _documents; // prose, and the IndexMeta row
  final Store _tables; // one chunk per spreadsheet row
  final Directory _dir;
  late final List<_EntityAccess> _shelves; // documents, then tables

  /// The model that produced these vectors. Vectors from different models
  /// cannot be compared, hence [isCompatibleWith].
  @override
  final String embeddingModel;
  final int dimension;

  /// [dimension] rounded up to the nearest supported width.
  final int storageDimension;

  /// With a per-file cap, HNSW is asked for this many times `k` candidates so
  /// enough are left after the cap to fill `k`.
  static const int _overFetchFactor = 8;

  /// Spreadsheet rows go to the tables index; everything else is a document.
  static bool _isTableRow(Chunk chunk) =>
      chunk.source.toLowerCase().endsWith('.csv');

  static Directory _documentsIn(Directory dir) =>
      Directory('${dir.path}/documents');
  static Directory _tablesIn(Directory dir) => Directory('${dir.path}/tables');

  /// Whether this build can index vectors of this width at all.
  static bool supports(int dimension) =>
      supportedDimensions.any((width) => dimension > 0 && dimension <= width);

  /// Where the database lives inside the app's support directory. Each RAG
  /// recipe passes its own [folder], since each chunks differently.
  static Directory directoryIn(
    Directory supportDir, {
    String folder = 'objectbox',
  }) => Directory('${supportDir.path}/$folder');

  /// Opens the index in [dir], or returns null if there is no usable one
  /// (missing, corrupt, or from an older build). Either way: re-index.
  static Future<ObjectBoxStore?> open(Directory dir) async {
    if (!await _documentsIn(dir).exists() || !await _tablesIn(dir).exists()) {
      return null; // missing, or the single-index layout of an older build
    }
    Store? documents;
    Store? tables;
    try {
      documents = await openStore(directory: _documentsIn(dir).path);
      tables = await openStore(directory: _tablesIn(dir).path);
      final meta = documents.box<IndexMeta>().getAll().firstOrNull;
      if (meta == null || !supports(meta.dimension)) {
        documents.close();
        tables.close();
        return null;
      }
      return ObjectBoxStore._(
        documents,
        tables,
        meta.embeddingModel,
        meta.dimension,
        dir,
      );
    } on Object {
      documents?.close();
      tables?.close();
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
    await _documentsIn(dir).create(recursive: true);
    await _tablesIn(dir).create(recursive: true);
    final documents = await openStore(directory: _documentsIn(dir).path);
    final tables = await openStore(directory: _tablesIn(dir).path);
    documents.box<IndexMeta>().put(
      IndexMeta()
        ..embeddingModel = embeddingModel
        ..dimension = dimension,
    );
    return ObjectBoxStore._(documents, tables, embeddingModel, dimension, dir);
  }

  @override
  int get size => _shelves.fold(0, (sum, shelf) => sum + shelf.count());
  @override
  bool get isEmpty => size == 0;
  Set<String> get sources => {for (final shelf in _shelves) ...shelf.sources()};
  Map<String, int> get chunkCountsBySource => {
    for (final shelf in _shelves) ...shelf.countsBySource(),
  };

  bool isCompatibleWith(String model) => model == embeddingModel;

  @override
  void addAll(List<Chunk> chunks, List<List<double>> embeddings) {
    if (chunks.length != embeddings.length) {
      throw ArgumentError(
        'chunk/embedding count mismatch: '
        '${chunks.length} vs ${embeddings.length}',
      );
    }
    final documents = <StoredChunk>[];
    final tables = <StoredChunk>[];
    for (var i = 0; i < chunks.length; i++) {
      Vectors.checkDimension(embeddings[i].length, dimension, isQuery: false);
      (_isTableRow(chunks[i]) ? tables : documents).add(
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
    _shelves[0].putAll(documents);
    _shelves[1].putAll(tables);
  }

  /// The [k] chunks closest to [queryEmbedding] across both indexes, best
  /// first, with at most [maxPerSource] from any one file.
  @override
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
    final merged = [
      for (final shelf in _shelves)
        ...shelf.nearest(query, candidates, dimension),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return capPerSource(merged, k, maxPerSource);
  }

  /// Releases the database. Without this the folder stays locked and the
  /// next open of it fails.
  void close() {
    _documents.close();
    _tables.close();
  }

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
            _toChunk(r.object, modelDimension),
            // ObjectBox reports cosine distance (0 to 2); convert to similarity.
            1.0 - r.score,
          ),
      ];
    },
  );

  static StoredChunk _toChunk(VecRow row, int modelDimension) => StoredChunk(
    text: row.text,
    source: row.source,
    index: row.chunkIndex,
    start: row.chunkStart,
    end: row.chunkEnd,
    embedding: (row.vector ?? const <double>[])
        .take(modelDimension)
        .toList(growable: false),
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
