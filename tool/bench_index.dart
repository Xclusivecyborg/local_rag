// Shared setup for the measurement scripts.
//
// Every tool here needs the same thing: a folder of documents turned into a
// searchable index. Since ObjectBox is the app's only index, the tools use it
// too — which is the point, because a harness measuring a different search
// path from the one that ships is measuring the wrong thing.
//
// One consequence worth knowing: the generated objectbox.g.dart imports
// objectbox_flutter_libs, so anything reaching ObjectBox pulls in Flutter and
// cannot be compiled by the plain Dart VM. Every script in tool/ therefore runs
// under `flutter test`, not `dart run`.

import 'dart:io';

import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// A store in a throwaway directory, plus the directory so it can be removed.
class BenchIndex {
  BenchIndex(this.store, this.dir);
  final ObjectBoxStore store;
  final Directory dir;

  void dispose() {
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Chunks, embeds and indexes [files] into a fresh temporary database.
Future<BenchIndex> buildIndex({
  required OllamaClient ollama,
  required List<File> files,
  required String embeddingModel,
  int? targetChars,
  void Function(IngestProgress)? report,
}) async {
  final dir = await Directory.systemTemp.createTemp('bench_idx');
  final result = await Ingestor(ollama).ingest(
    files: files,
    embeddingModel: embeddingModel,
    report: report,
    targetChars: targetChars ?? kDefaultTargetChars,
    indexFactory: (model, dimension) => ObjectBoxStore.create(
      Directory('${dir.path}/objectbox'),
      embeddingModel: model,
      dimension: dimension,
    ),
  );
  return BenchIndex(result.store, dir);
}

/// Indexes pre-built chunks, for tools that control their own chunking.
Future<BenchIndex> indexChunks({
  required OllamaClient ollama,
  required List<Chunk> chunks,
  required String embeddingModel,
}) async {
  final dir = await Directory.systemTemp.createTemp('bench_idx');
  final vectors = await ollama.embed(
    model: embeddingModel,
    input: [for (final c in chunks) c.text],
  );
  final store = await ObjectBoxStore.create(
    Directory('${dir.path}/objectbox'),
    embeddingModel: embeddingModel,
    dimension: vectors.first.length,
  );
  store.addAll(chunks, vectors);
  return BenchIndex(store, dir);
}
