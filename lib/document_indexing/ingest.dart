import 'dart:io';

import 'chunker.dart';
import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// What one ingest produced: an embedded index for prose, and the structured
/// tables for anything that was actually tabular.
///
/// Both, not either. A CSV is embedded *and* kept as a table — retrieval
/// answers "which supplier makes Heritage shoes", the table answers "what was
/// January's revenue", and neither can do the other's job.
class IngestResult {
  const IngestResult(this.store, this.tables);
  final ObjectBoxStore store;
  final List<CsvTable> tables;
}

/// Builds the index the embedded vectors will go into.
///
/// Injected rather than constructed here so ingestion stays ignorant of where
/// the index lives — it produces chunks and vectors, and the caller decides
/// which directory they land in. Async because opening an ObjectBox store
/// touches the filesystem.
typedef IndexFactory = Future<ObjectBoxStore> Function(
  String embeddingModel,
  int dimension,
);

class IngestProgress {
  const IngestProgress(this.stage, {this.done = 0, this.total = 0});
  final String stage;
  final int done;
  final int total;

  double? get fraction => total == 0 ? null : done / total;
}

const Set<String> kSupportedExtensions = {
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.log',
  '.json',
};

/// Turns a set of files into an embedded, searchable index.
class Ingestor {
  Ingestor(this.ollama);
  final OllamaClient ollama;

  Future<IngestResult> ingest({
    required List<File> files,
    required String embeddingModel,
    void Function(IngestProgress)? report,
    required IndexFactory indexFactory,
    int targetChars = kDefaultTargetChars,
    int overlapChars = kDefaultOverlapChars,
  }) async {
    report?.call(const IngestProgress('Reading files'));

    final chunks = <Chunk>[];
    final tables = <CsvTable>[];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final ext = _extension(name);
      String text;
      try {
        text = await file.readAsString();
      } on Object catch (e) {
        // A single unreadable file should not abort the whole ingest.
        report?.call(IngestProgress('Skipped $name ($e)'));
        continue;
      }
      if (ext == '.csv') {
        // Keep the structure before discarding it. The prose form is for
        // semantic lookup; the table is the only thing that can do arithmetic.
        final table = CsvTable.parse(text, source: name);
        if (table.rowCount > 0) tables.add(table);
        text = csvToProse(text);
      }
      chunks.addAll(chunkDocument(
        text,
        source: name,
        targetChars: targetChars,
        overlapChars: overlapChars,
      ));
    }

    if (chunks.isEmpty) {
      throw StateError(
        'No readable text found. Supported: '
        '${kSupportedExtensions.join(", ")}.\n'
        'PDF and scanned documents are not handled by this build.',
      );
    }

    report?.call(IngestProgress('Embedding', done: 0, total: chunks.length));

    final vectors = await ollama.embed(
      model: embeddingModel,
      input: [for (final c in chunks) c.text],
      onProgress: (done, total) => report?.call(
        IngestProgress('Embedding', done: done, total: total),
      ),
    );

    final dimension = vectors.first.length;
    final store = await indexFactory(embeddingModel, dimension);
    store.addAll(chunks, vectors);

    final tableNote = tables.isEmpty
        ? ''
        : ', ${tables.fold<int>(0, (a, t) => a + t.rowCount)} table rows';
    report?.call(IngestProgress(
      'Indexed ${store.size} chunks from ${files.length} file(s)$tableNote',
      done: chunks.length,
      total: chunks.length,
    ));
    return IngestResult(store, tables);
  }
}

/// Collects supported files from a directory, recursively.
Future<List<File>> collectFiles(Directory dir) async {
  final out = <File>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.startsWith('.')) continue;
    if (kSupportedExtensions.contains(_extension(name))) out.add(entity);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot).toLowerCase();
}

/// Renders CSV rows as labelled prose, one record per paragraph.
///
/// Embedding raw CSV lines works badly: `SHO-114,Lagos,2026-03-02,48,912000`
/// carries almost no semantic signal, so a question phrased in words retrieves
/// nothing useful. Restating each row as `Region: Lagos. Units sold: 48.` gives
/// the embedding model something to actually match against.
///
/// This helps for lookup-style questions. It does *not* make aggregation work
/// — see the README on why totals and counts need SQL, not retrieval.
String csvToProse(String csv) {
  final rows = parseCsvGrid(csv);
  if (rows.isEmpty) return '';

  final header = rows.first;
  final buffer = StringBuffer();

  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    if (row.every((cell) => cell.trim().isEmpty)) continue;
    final parts = <String>[];
    for (var c = 0; c < header.length && c < row.length; c++) {
      final key = header[c].trim();
      final value = row[c].trim();
      if (key.isEmpty || value.isEmpty) continue;
      parts.add('$key: $value');
    }
    if (parts.isEmpty) continue;
    buffer.writeln('Record $r. ${parts.join('. ')}.');
    buffer.writeln();
  }
  return buffer.toString();
}
