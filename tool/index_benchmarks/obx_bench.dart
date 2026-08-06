// How does the ObjectBox HNSW index behave as the corpus grows?
//
//   flutter test tool/index_benchmarks/obx_bench.dart
//   EMBED_MODEL=mxbai-embed-large:latest flutter test tool/index_benchmarks/obx_bench.dart
//
// Run through `flutter test`, not `dart run`. The generated objectbox.g.dart
// imports objectbox_flutter_libs, so any file that reaches ObjectBox pulls in
// Flutter and the plain Dart VM cannot compile it. Living in tool/ keeps it out
// of the default `flutter test` sweep, which only scans test/.
//
// NOTE ON WHAT THIS NO LONGER MEASURES
// Earlier versions ran an exact brute-force index alongside HNSW and reported
// recall@5 — what fraction of the true nearest neighbours the approximate index
// found. That comparison needed a second, exact implementation, which has been
// removed from the project. Recorded results before removal, for the archive:
// 98–100% recall at every size up to 8,000 chunks, and identical top-5 on all
// 12 eval questions for both embedding models.
//
// hit@1 and hit@5 below are unaffected: they are scored against the document
// that is known to contain the answer, which is ground truth from the eval set
// rather than from another index.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// The eval set, unchanged from tool/retrieval_quality/eval.dart so the numbers
/// are comparable.
const Map<String, String> evalSet = {
  'How many days do I have to return unworn shoes?': 'returns_and_warranty.md',
  'What is the warranty on the Heritage line?': 'returns_and_warranty.md',
  'Can I get a refund on something I bought in a sale?':
      'returns_and_warranty.md',
  'How many people work at the company?': 'company_overview.md',
  'Where is the Abuja branch located?': 'company_overview.md',
  'When was the Port Harcourt location opened?': 'company_overview.md',
  'Who makes our Heritage leather shoes?': 'suppliers.md',
  'What are the payment terms with the Italian supplier?': 'suppliers.md',
  'Which supplier has the lowest defect rate?': 'suppliers.md',
  'How much annual leave do full-time staff get?': 'staff_handbook.md',
  'What discount do employees get on Heritage shoes?': 'staff_handbook.md',
  'What commission do staff earn on Heritage sales?': 'staff_handbook.md',
};

String bar(String t) => '\n── $t ${'─' * math.max(2, 56 - t.length)}';

void main() {
  final model =
      Platform.environment['EMBED_MODEL'] ?? 'locusai/all-minilm-l6-v2:latest';

  test('ObjectBox index behaviour', () async {
    final ollama = OllamaClient();
    if (await ollama.version() == null) {
      ollama.close();
      markTestSkipped('Ollama is not running — start it with: ollama serve');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('obx_bench');
    try {
      await _stageA(ollama, model, tmp);
      await _stageB(ollama, model, tmp);
    } finally {
      ollama.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// Stage A — does the app still answer the eval set correctly?
Future<void> _stageA(OllamaClient ollama, String model, Directory tmp) async {
  stdout.writeln(bar('A. sample_kb, real embeddings, model=$model'));

  final files = await collectFiles(Directory('sample_kb'));
  if (files.isEmpty) {
    stdout.writeln('sample_kb not found — run from the project root.');
    return;
  }

  final chunks = <Chunk>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    var text = await f.readAsString();
    if (name.endsWith('.csv')) text = csvToProse(text);
    chunks.addAll(chunkDocument(text, source: name));
  }
  final vectors =
      await ollama.embed(model: model, input: [for (final c in chunks) c.text]);
  final dims = vectors.first.length;

  if (!ObjectBoxStore.supports(dims)) {
    stdout.writeln('No HNSW index wide enough for $dims-d vectors.');
    return;
  }

  final store = await ObjectBoxStore.create(Directory('${tmp.path}/a'),
      embeddingModel: model, dimension: dims);
  store.addAll(chunks, vectors);
  stdout.writeln('${chunks.length} chunks, $dims-d '
      '(stored at ${store.storageDimension}-d)');

  var at1 = 0, at5 = 0;
  for (final entry in evalSet.entries) {
    final qv = await ollama.embedOne(model: model, input: entry.key);
    final hits = store.search(qv, k: 5, maxPerSource: 2);
    if (hits.isNotEmpty && hits.first.chunk.source == entry.value) at1++;
    if (hits.any((c) => c.chunk.source == entry.value)) at5++;
  }

  final n = evalSet.length;
  String pct(int h) => '${(h / n * 100).round()}%';
  stdout.writeln('hit@1 ${pct(at1)}   hit@5 ${pct(at5)}   (n=$n)');
  stdout.writeln('index on disk: ${(store.diskBytes / 1024).toStringAsFixed(0)} KB');
  store.close();
}

/// Stage B — how do build time, query latency and size scale?
Future<void> _stageB(OllamaClient ollama, String model, Directory tmp) async {
  stdout.writeln(bar('B. scale, still real embeddings'));

  // Synthetic *text*, real *embeddings*. The sentences are generated, but the
  // vectors come from the model the app uses, so the geometry is genuine.
  const regions = [
    'Lagos', 'Abuja', 'Port Harcourt', 'Kano', 'Ibadan', 'Enugu',
    'Benin City', 'Kaduna', 'Jos', 'Warri',
  ];
  const lines = ['Heritage', 'Classic', 'Everyday', 'Sport', 'Workwear'];
  const topics = [
    'returns and refunds', 'warranty cover', 'staff annual leave',
    'employee discount', 'supplier payment terms', 'defect rates',
    'store opening hours', 'delivery times', 'sales commission',
    'stock levels',
  ];

  final texts = <String>[];
  for (var i = 0; texts.length < 8000; i++) {
    final r = regions[i % regions.length];
    final l = lines[(i ~/ regions.length) % lines.length];
    final t = topics[(i ~/ (regions.length * lines.length)) % topics.length];
    texts.add('Branch note $i. The $r store reported on $t for the $l line '
        'this quarter, with figures reviewed by the $r regional manager.');
  }

  stdout.writeln('embedding ${texts.length} passages with $model …');
  final sw = Stopwatch()..start();
  final vectors = await ollama.embed(model: model, input: texts, batchSize: 64);
  sw.stop();
  final dims = vectors.first.length;
  stdout.writeln('embedded in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
      '(${(sw.elapsedMicroseconds / texts.length / 1000).toStringAsFixed(2)}ms each)');

  if (!ObjectBoxStore.supports(dims)) return;

  final allChunks = [
    for (var i = 0; i < texts.length; i++)
      Chunk(text: texts[i], source: 'doc${i % 40}.md', index: i),
  ];

  stdout.writeln('\nn        build      query     disk');
  final rng = math.Random(11);
  for (final n in [55, 500, 2000, 8000]) {
    final sub = allChunks.sublist(0, n);
    final subVecs = vectors.sublist(0, n);

    final buildSw = Stopwatch()..start();
    final store = await ObjectBoxStore.create(Directory('${tmp.path}/b$n'),
        embeddingModel: model, dimension: dims);
    store.addAll(sub, subVecs);
    buildSw.stop();

    // Probe with realistic queries: small perturbations of stored passages,
    // which is what a paraphrased question looks like in embedding space.
    final probes = <List<double>>[];
    for (var i = 0; i < 50; i++) {
      final anchor = subVecs[rng.nextInt(n)];
      probes.add([for (final x in anchor) x + (rng.nextDouble() - 0.5) * 0.02]);
    }

    final qSw = Stopwatch()..start();
    for (final p in probes) {
      store.search(p, k: 5);
    }
    qSw.stop();

    stdout.writeln('${n.toString().padRight(8)} '
        '${'${buildSw.elapsedMilliseconds}ms'.padRight(10)} '
        '${'${(qSw.elapsedMicroseconds / 1000 / probes.length).toStringAsFixed(2)}ms'.padRight(9)} '
        '${(store.diskBytes / 1024 / 1024).toStringAsFixed(1)}MB');

    store.close();
  }
}
