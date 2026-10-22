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

import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/rag/rag_pipeline.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// A store in a throwaway directory, plus the directory so it can be removed.
class BenchIndex {
  BenchIndex(this.store, this.dir, [this.tables = const []]);
  final ObjectBoxStore store;
  final Directory dir;

  /// The CSV tables, when the recipe keeps them for arithmetic.
  final List<CsvTable> tables;

  void dispose() {
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Chunks, embeds and indexes [files] into a fresh temporary database, the
/// way [recipe] says to. [chunkSize] overrides the recipe's.
Future<BenchIndex> buildIndex({
  required OllamaClient ollama,
  required List<File> files,
  required String embeddingModel,
  RagRecipe recipe = RagRecipe.optimized,
  int? chunkSize,
  void Function(IngestProgress)? onProgress,
}) async {
  final dir = await Directory.systemTemp.createTemp('bench_idx');
  final pipeline = RagPipeline(
    ollama,
    recipe: chunkSize == null
        ? recipe
        : RagRecipe(name: 'bench', chunkSize: chunkSize),
  );
  final result = await pipeline.ingest(
    files: files,
    embeddingModel: embeddingModel,
    onProgress: onProgress,
    createIndex: (model, dimension) => ObjectBoxStore.create(
      Directory('${dir.path}/objectbox'),
      embeddingModel: model,
      dimension: dimension,
    ),
  );
  return BenchIndex(result.index, dir, result.tables);
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
