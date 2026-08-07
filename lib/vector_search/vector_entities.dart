import 'package:objectbox/objectbox.dart';

/// ObjectBox entities backing the HNSW index.
///
/// There is one entity per embedding dimension, and that is not a style
/// choice. `@HnswIndex(dimensions:)` is an annotation argument, so it is fixed
/// at compile time — but the app lets you switch embedding models at runtime,
/// and mxbai-embed-large (1024-d) and all-MiniLM (384-d) do not agree on a
/// number. One entity cannot serve both. Verified in the Phase 0 spike:
/// entities of different dimensions coexist happily in one store.
///
/// 768 is here for the models this project does not ship with but users
/// reach for first (nomic-embed-text, most BERT-base encoders). A dimension
/// with no entity of its own is zero-padded up to the next widest one, which
/// leaves cosine similarity exactly unchanged — so 512-d is stored at 768-d
/// and searches correctly. Only widths above the largest entity are refused.
///
/// `VectorDistanceType.cosine` is required. The default is Euclidean, and the
/// app's retrieval gates are calibrated in cosine similarity.

const supportedDimensions = <int>{384, 768, 1024};

/// The shape every vector entity shares.
///
/// ObjectBox entities cannot inherit fields from a base class, but they can
/// implement a plain Dart interface over fields they each declare. That is
/// enough to write the row-to-chunk conversion once instead of once per
/// dimension.
abstract interface class VecRow {
  String get text;
  String get source;
  int get chunkIndex;

  /// Character span this chunk covers in its source file. Persisted so a
  /// retrieved excerpt can be located in the document it came from, rather
  /// than only named. Rows written before these existed read back as 0.
  int get chunkStart;
  int get chunkEnd;

  List<double>? get vector;
}

/// Written once per index so a loaded database can say which model produced
/// it. Without this the app would happily search 384-d MiniLM vectors with a
/// mxbai query and return confident nonsense.
@Entity()
class IndexMeta {
  @Id()
  int id = 0;

  String embeddingModel = '';
  int dimension = 0;

  IndexMeta();
}

@Entity()
class Vec384 implements VecRow {
  @Id()
  int id = 0;

  @override
  String text = '';
  @override
  String source = '';
  @override
  int chunkIndex = 0;
  @override
  int chunkStart = 0;
  @override
  int chunkEnd = 0;

  @override
  @HnswIndex(dimensions: 384, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? vector;

  Vec384();
}

@Entity()
class Vec768 implements VecRow {
  @Id()
  int id = 0;

  @override
  String text = '';
  @override
  String source = '';
  @override
  int chunkIndex = 0;
  @override
  int chunkStart = 0;
  @override
  int chunkEnd = 0;

  @override
  @HnswIndex(dimensions: 768, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? vector;

  Vec768();
}

@Entity()
class Vec1024 implements VecRow {
  @Id()
  int id = 0;

  @override
  String text = '';
  @override
  String source = '';
  @override
  int chunkIndex = 0;
  @override
  int chunkStart = 0;
  @override
  int chunkEnd = 0;

  @override
  @HnswIndex(dimensions: 1024, distanceType: VectorDistanceType.cosine)
  @Property(type: PropertyType.floatVector)
  List<double>? vector;

  Vec1024();
}
