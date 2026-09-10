import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

class IngestResult {
  const IngestResult(this.store, this.tables);
  final ObjectBoxStore store;
  final List<CsvTable> tables;
}
