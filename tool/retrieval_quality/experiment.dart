// Diagnoses *why* retrieval misses, before changing anything.
//
//   flutter test tool/retrieval_quality/experiment.dart
//
// Three questions this answers:
//   A. What do similarity scores look like for real questions vs chitchat?
//      (needed to pick a gating threshold that isn't guessed)
//   B. Does excluding the CSV fix the misses? (corpus problem vs model problem)
//   C. Is the mxbai query prefix actually earning its place?

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

import '../bench_index.dart';
import '../eval_set.dart';

const String embedModel = 'mxbai-embed-large';

Future<BenchIndex> build(
  OllamaClient ollama,
  List<File> files, {
  int chunkSize = defaultChunkSize,
}) async {
  final chunks = <Chunk>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    var text = await f.readAsString();
    if (name.endsWith('.csv')) text = csvToProse(text);
    chunks.addAll(chunkDocument(text, source: name, chunkSize: chunkSize));
  }
  return indexChunks(
      ollama: ollama, chunks: chunks, embeddingModel: embedModel);
}

Future<double> topScore(
  OllamaClient ollama,
  ObjectBoxStore store,
  String q, {
  bool prefix = true,
}) async {
  final v = await ollama.embedOne(
    model: embedModel,
    input: prefix ? '${OllamaClient.mxbaiQueryPrefix}$q' : q,
  );
  final hits = store.search(v, k: 1);
  return hits.isEmpty ? 0 : hits.first.score;
}

Future<(int, int)> hitRate(
  OllamaClient ollama,
  ObjectBoxStore store, {
  bool prefix = true,
  int? maxPerSource,
}) async {
  var at1 = 0, at3 = 0;
  for (final e in evalSet.entries) {
    final v = await ollama.embedOne(
      model: embedModel,
      input: prefix ? '${OllamaClient.mxbaiQueryPrefix}${e.key}' : e.key,
    );
    final ranked = store
        .search(v, k: 3, maxPerSource: maxPerSource)
        .map((r) => r.chunk.source)
        .toList();
    if (ranked.take(1).contains(e.value)) at1++;
    if (ranked.contains(e.value)) at3++;
  }
  return (at1, at3);
}

String pct(int h, int n) => '${(h / n * 100).toStringAsFixed(0)}%';

Future<void> _run() async {
  final ollama = OllamaClient();
  final dir = Directory('sample_kb');
  final allFiles = await findSupportedFiles(dir);
  final proseOnly =
      allFiles.where((f) => !f.path.endsWith('.csv')).toList();

  stdout.writeln('Building indexes…');
  final fullIndex = await build(ollama, allFiles);
  final proseIndex = await build(ollama, proseOnly);
  final full = fullIndex.store;
  final prose = proseIndex.store;
  stdout.writeln('  full corpus : ${full.size} chunks');
  stdout.writeln('  prose only  : ${prose.size} chunks\n');

  // ---- B. corpus problem or model problem? ----------------------------
  stdout.writeln('── B. Does the CSV cause the misses? ───────────────');
  final n = evalSet.length;
  final (f1, f3) = await hitRate(ollama, full);
  final (p1, p3) = await hitRate(ollama, prose);
  stdout.writeln('  full corpus  hit@1 ${pct(f1, n)}  hit@3 ${pct(f3, n)}');
  stdout.writeln('  CSV excluded hit@1 ${pct(p1, n)}  hit@3 ${pct(p3, n)}');
  stdout.writeln(p1 > f1
      ? '  → the CSV is crowding out real documents (corpus problem)'
      : '  → removing the CSV does not help (look elsewhere)');

  // ---- D. how hard should we cap one source? --------------------------
  stdout.writeln('\n── D. maxPerSource sweep (full corpus) ────────────');
  for (final cap in <int?>[null, 3, 2, 1]) {
    final (a1, a3) = await hitRate(ollama, full, maxPerSource: cap);
    final label = '  cap ${cap?.toString() ?? "none"}'.padRight(14);
    stdout.writeln('$label hit@1 ${pct(a1, n)}  hit@3 ${pct(a3, n)}');
  }

  // ---- C. is the query prefix earning its place? ----------------------
  stdout.writeln('\n── C. mxbai query prefix ──────────────────────────');
  final (n1, n3) = await hitRate(ollama, full, prefix: false);
  stdout.writeln('  with prefix     hit@1 ${pct(f1, n)}  hit@3 ${pct(f3, n)}');
  stdout.writeln('  without prefix  hit@1 ${pct(n1, n)}  hit@3 ${pct(n3, n)}');

  // ---- A. score separation --------------------------------------------
  stdout.writeln('\n── A. Score separation (for gating) ───────────────');
  final onScores = <double>[];
  for (final q in evalSet.keys) {
    onScores.add(await topScore(ollama, full, q));
  }
  final offScores = <double>[];
  for (final q in offTopic) {
    offScores.add(await topScore(ollama, full, q));
  }
  onScores.sort();
  offScores.sort();

  String f(double d) => d.toStringAsFixed(3);
  stdout.writeln('  on-topic  min ${f(onScores.first)}  '
      'median ${f(onScores[onScores.length ~/ 2])}  '
      'max ${f(onScores.last)}');
  stdout.writeln('  off-topic min ${f(offScores.first)}  '
      'median ${f(offScores[offScores.length ~/ 2])}  '
      'max ${f(offScores.last)}');
  stdout.writeln('\n  worst on-topic : ${f(onScores.first)}');
  stdout.writeln('  best off-topic : ${f(offScores.last)}');
  if (onScores.first > offScores.last) {
    final gap = onScores.first - offScores.last;
    stdout.writeln('  → clean separation, gap ${f(gap)}. '
        'Threshold ≈ ${f(offScores.last + gap / 2)}');
  } else {
    stdout.writeln('  → OVERLAP. No single threshold separates them; '
        'gating on score alone will misfire.');
  }

  stdout.writeln('\n  off-topic detail:');
  for (var i = 0; i < offTopic.length; i++) {
    final s = await topScore(ollama, full, offTopic[i]);
    stdout.writeln('    ${f(s)}  "${offTopic[i]}"');
  }

  ollama.close();
}


void main() {
  test('retrieval diagnostics', _run,
      timeout: const Timeout(Duration(minutes: 30)));
}
