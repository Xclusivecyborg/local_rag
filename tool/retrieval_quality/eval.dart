// Headless harness for the RAG pipeline.
//
// Run:  flutter test tool/retrieval_quality/eval.dart
//       KB=path/to/folder flutter test tool/retrieval_quality/eval.dart
//
// This exists because "the demo felt right" is not evidence. It indexes a
// folder, runs a fixed question set, and reports hit rate — did the chunk
// that actually contains the answer make it into the top k? Change the
// chunk size or swap the embedding model, re-run this, and you get a number
// instead of a vibe.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';

import '../bench_index.dart';
import '../eval_set.dart';

const String embedModel = 'mxbai-embed-large';
const String chatModel = 'gpt-oss:latest';

Future<void> _run() async {
  final kbPath = Platform.environment['KB'] ?? 'sample_kb';
  final dir = Directory(kbPath);
  if (!dir.existsSync()) {
    stderr.writeln('No such directory: $kbPath');
    exit(1);
  }

  final ollama = OllamaClient();

  stdout.writeln('Indexing $kbPath …');
  final sw = Stopwatch()..start();
  final files = await findSupportedFiles(dir);
  final index = await buildIndex(
    ollama: ollama,
    files: files,
    embeddingModel: embedModel,
    onProgress: (p) {
      if (p.total > 0 && p.done % 32 == 0) {
        stdout.write('\r  ${p.stage} ${p.done}/${p.total}   ');
      }
    },
  );
  final store = index.store;
  sw.stop();
  stdout.writeln('\r  ${store.size} chunks from ${files.length} files, '
      '${store.dimension}-d, in ${sw.elapsedMilliseconds}ms        ');

  // ---- retrieval quality ----------------------------------------------
  stdout.writeln('\n── Retrieval hit rate ──────────────────────────────');
  var hits1 = 0, hits3 = 0, hits5 = 0;
  final latencies = <int>[];

  for (final entry in evalSet.entries) {
    final t = Stopwatch()..start();
    final qv = await ollama.embedOne(
      model: embedModel,
      input: '${OllamaClient.mxbaiQueryPrefix}${entry.key}',
    );
    // Must mirror RagController's settings, or the eval measures a pipeline
    // the app does not actually run.
    final results = store.search(qv, k: 5, maxPerSource: 2);
    t.stop();
    latencies.add(t.elapsedMilliseconds);

    final ranked = results.map((r) => r.chunk.source).toList();
    final at1 = ranked.take(1).contains(entry.value);
    final at3 = ranked.take(3).contains(entry.value);
    final at5 = ranked.contains(entry.value);
    if (at1) hits1++;
    if (at3) hits3++;
    if (at5) hits5++;

    final mark = at1 ? '✓' : (at5 ? '~' : '✗');
    stdout.writeln('$mark ${entry.key}');
    if (!at1) {
      stdout.writeln('    expected ${entry.value}, got ${ranked.take(3)}');
    }
  }

  final n = evalSet.length;
  String pct(int h) => '${(h / n * 100).toStringAsFixed(0)}%';
  latencies.sort();
  stdout.writeln('\n  hit@1 ${pct(hits1)}   hit@3 ${pct(hits3)}   '
      'hit@5 ${pct(hits5)}   (n=$n)');
  stdout.writeln('  median retrieval latency: '
      '${latencies[latencies.length ~/ 2]}ms');

  // ---- the aggregation trap -------------------------------------------
  stdout.writeln('\n── Aggregation question (the trap) ─────────────────');
  const q = 'What was our total revenue in Q1 2026?';
  final qv = await ollama.embedOne(
    model: embedModel,
    input: '${OllamaClient.mxbaiQueryPrefix}$q',
  );
  final hits = store.search(qv, k: 5, maxPerSource: 2);
  final counts = store.chunkCountsBySource;
  final csvChunks = counts.entries
      .where((e) => e.key.endsWith('.csv'))
      .fold<int>(0, (a, e) => a + e.value);

  stdout.writeln('Q: $q');
  stdout.writeln('Retrieved ${hits.length} of $csvChunks sales chunks '
      '(${(hits.length / csvChunks * 100).toStringAsFixed(1)}% of the data).');
  stdout.writeln('Ground truth: NGN 204,740,500\n');

  final context = StringBuffer();
  for (final h in hits) {
    context.writeln('[${h.chunk.source}] ${h.chunk.text}');
  }

  stdout.write('Model answer: ');
  await for (final chunk in ollama.chat(
    model: chatModel,
    messages: [
      ChatMessage('user',
          'EXCERPTS:\n$context\n\nAnswer the question using the excerpts above.\n\nQUESTION: $q')
    ],
  )) {
    if (chunk.content != null) stdout.write(chunk.content);
  }
  stdout.writeln('\n');

  index.dispose();
  ollama.close();
}


void main() {
  test('retrieval hit rate', _run,
      timeout: const Timeout(Duration(minutes: 30)));
}
