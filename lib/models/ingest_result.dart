import 'package:rag_blocks/rag_blocks.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// What indexing a folder produced.
class IngestResult {
  const IngestResult(this.index, this.tables);
  final ObjectBoxStore index;
  final List<CsvTable> tables;
}
