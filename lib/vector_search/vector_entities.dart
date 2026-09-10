import 'package:objectbox/objectbox.dart';

// ObjectBox entities for the vector index.
//
// ObjectBox fixes an HNSW index's width at code-generation time, so there is
// one entity per supported width. Narrower models are zero-padded up to the
// next width (see Vectors.pad). The distance type must be cosine, because the
// retrieval thresholds are cosine similarities.
//
// Changing an entity here means re-running the ObjectBox code generator.

const supportedDimensions = <int>{384, 768, 1024};

/// The fields every vector entity has. ObjectBox entities cannot inherit
/// fields, but they can implement an interface, so rows are read and written
/// in one place.
abstract interface class VecRow {
  abstract String text;
  abstract String source;
  abstract int chunkIndex;
  abstract int chunkStart; // 0 on rows written before this was saved
  abstract int chunkEnd;
  abstract List<double>? vector;
}

/// Which model built the index, so a mismatched model can be detected on load.
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
