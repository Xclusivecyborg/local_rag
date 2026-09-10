import 'dart:io';

import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/ingest_result.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

import 'chunker.dart';

/// File types the indexer can read.
const Set<String> supportedExtensions = {
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.log',
  '.json',
};

/// Creates the empty index that the embedded chunks are written into.
typedef CreateIndex =
    Future<ObjectBoxStore> Function(String embeddingModel, int dimension);

/// Turns files into a searchable index, plus tables for any CSV files.
///
/// A CSV is used both ways: as prose for retrieval ("which supplier makes
/// Heritage shoes?") and as a table for arithmetic ("January's revenue").
class Ingestor {
  Ingestor(this.ollama);
  final OllamaClient ollama;

  Future<IngestResult> ingest({
    required List<File> files,
    required String embeddingModel,
    required CreateIndex createIndex,
    void Function(IngestProgress)? onProgress,
    int chunkSize = defaultChunkSize,
    int chunkOverlap = defaultChunkOverlap,
  }) async {
    onProgress?.call(const IngestProgress('Reading files'));

    final chunks = <Chunk>[];
    final tables = <CsvTable>[];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      String text;
      try {
        text = await file.readAsString();
      } on Object catch (e) {
        onProgress?.call(IngestProgress('Skipped $name ($e)'));
        continue;
      }
      if (_extension(name) == '.csv') {
        final table = CsvTable.parse(text, source: name);
        if (table.rowCount > 0) tables.add(table);
        text = csvToProse(text);
      }
      chunks.addAll(
        chunkDocument(
          text,
          source: name,
          chunkSize: chunkSize,
          chunkOverlap: chunkOverlap,
        ),
      );
    }

    if (chunks.isEmpty) {
      throw StateError(
        'No readable text found. Supported: '
        '${supportedExtensions.join(", ")}.\n'
        'PDF and scanned documents are not handled by this build.',
      );
    }

    onProgress?.call(
      IngestProgress('Embedding', done: 0, total: chunks.length),
    );
    final vectors = await ollama.embed(
      model: embeddingModel,
      input: [for (final c in chunks) c.text],
      onProgress: (done, total) => onProgress?.call(
        IngestProgress('Embedding', done: done, total: total),
      ),
    );

    final index = await createIndex(embeddingModel, vectors.first.length);
    index.addAll(chunks, vectors);

    final tableRows = tables.fold<int>(0, (sum, t) => sum + t.rowCount);
    onProgress?.call(
      IngestProgress(
        'Indexed ${index.size} chunks from ${files.length} file(s)'
        '${tables.isEmpty ? '' : ', $tableRows table rows'}',
        done: chunks.length,
        total: chunks.length,
      ),
    );
    return IngestResult(index, tables);
  }
}

/// Every supported, non-hidden file under [folder], sorted by path.
Future<List<File>> findSupportedFiles(Directory folder) async {
  final files = <File>[];
  await for (final entity in folder.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.startsWith('.')) continue;
    if (supportedExtensions.contains(_extension(name))) files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot).toLowerCase();
}

/// Rewrites CSV rows as labelled sentences, one record per paragraph.
///
/// A raw line like `SHO-114,Lagos,2026-03-02,48` gives an embedding model
/// almost nothing to match. `Region: Lagos. Units sold: 48.` does.
String csvToProse(String csv) {
  final rows = parseCsvGrid(csv);
  if (rows.isEmpty) return '';

  final header = rows.first;
  final buffer = StringBuffer();
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final parts = [
      for (var c = 0; c < header.length && c < row.length; c++)
        if (header[c].trim().isNotEmpty && row[c].trim().isNotEmpty)
          '${header[c].trim()}: ${row[c].trim()}',
    ];
    if (parts.isEmpty) continue;
    buffer
      ..writeln('Record $r. ${parts.join('. ')}.')
      ..writeln();
  }
  return buffer.toString();
}
