// Head-to-head comparison of embedding models on this corpus.
//
//   flutter test tool/retrieval_quality/compare_embedders.dart [model...]
//
// Swapping embedders on a hunch is how you spend an afternoon and change
// nothing. This indexes the same folder with each model, runs the same question
// set, and reports hit rate — plus the score separation each model needs for
// its own retrieval threshold, because that number is per-model and copying
// one across is a silent bug.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import '../bench_index.dart';
import '../eval_set.dart';

/// What gets measured when no models are named.
///
/// These are the two the app ships with. Others can be compared without
/// editing this file:
///
///   MODELS="all-minilm:22m,all-minilm:33m" flutter test tool/retrieval_quality/compare_embedders.dart
const List<String> defaultModels = <String>[
  'locusai/all-minilm-l6-v2:latest', // all-MiniLM-L6-v2, the default
  'mxbai-embed-large:latest',
];

class Result {
  Result(this.model, this.dimension, this.chunks, this.at1, this.at3, this.at5,
      this.indexMs, this.queryMs, this.onScores, this.offScores);

  final String model;
  final int dimension;
  final int chunks;
  final int at1, at3, at5;
  final int indexMs, queryMs;

  /// Top score for every on-topic question, ascending.
  final List<double> onScores;

  /// Top score for every off-topic input, ascending.
  final List<double> offScores;

  double get worstOnTopic => onScores.first;
  double get bestOffTopic => offScores.last;

  bool get separates => worstOnTopic > bestOffTopic;
  double get gap => worstOnTopic - bestOffTopic;

  /// Where to put the gate.
  ///
  /// When the two bands separate cleanly, the midpoint. When they overlap
  /// there is no clean answer, and the policy is **never miss a real
  /// question**: sit at the worst on-topic score and accept that the noisiest
  /// small talk gets through. A gate set too high fails silently — the user
  /// sees "I don't have that information" about a document they are looking
  /// at. Set too low it merely pulls an excerpt into a greeting, which is
  /// visible on screen and labelled as such.
  double get threshold =>
      separates ? bestOffTopic + gap / 2 : (worstOnTopic * 100).floor() / 100;

  /// How many off-topic inputs get through at [threshold] — the price of the
  /// policy above, stated rather than hidden.
  int get leaks => offScores.where((s) => s >= threshold).length;

  /// How many real questions the gate would block. The number that matters,
  /// because each one is a silent failure.
  int get missed => onScores.where((s) => s < threshold).length;
}

Future<Result> measure(OllamaClient ollama, List<File> files, String model,
    {bool prefix = false}) async {
  final indexWatch = Stopwatch()..start();
  final chunks = <Chunk>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    var text = await f.readAsString();
    if (name.endsWith('.csv')) text = csvToProse(text);
    chunks.addAll(chunkDocument(text, source: name));
  }
  final index = await indexChunks(
      ollama: ollama, chunks: chunks, embeddingModel: model);
  final store = index.store;
  indexWatch.stop();

  // Only mxbai documents an asymmetric query prefix; MiniLM is symmetric.
  String asQuery(String q) =>
      prefix ? '${OllamaClient.mxbaiQueryPrefix}$q' : q;

  var at1 = 0, at3 = 0, at5 = 0;
  final onScores = <double>[];
  final latencies = <int>[];

  for (final entry in evalSet.entries) {
    final watch = Stopwatch()..start();
    final qv = await ollama.embedOne(model: model, input: asQuery(entry.key));
    watch.stop();
    latencies.add(watch.elapsedMilliseconds);

    // Mirrors RagController exactly, or the eval measures a pipeline the app
    // does not actually run.
    final hits = store.search(qv, k: 5, maxPerSource: 2);
    final ranked = hits.map((h) => h.chunk.source).toList();
    if (ranked.take(1).contains(entry.value)) at1++;
    if (ranked.take(3).contains(entry.value)) at3++;
    if (ranked.contains(entry.value)) at5++;
    if (hits.isNotEmpty) onScores.add(hits.first.score);
  }

  // Short questions contribute to the gate but not to hit@k above. A gate that
  // only clears long sentences is the bug this set exists to catch.
  for (final question in shortFormEval.keys) {
    final qv = await ollama.embedOne(model: model, input: asQuery(question));
    final hits = store.search(qv, k: 5, maxPerSource: 2);
    if (hits.isNotEmpty) onScores.add(hits.first.score);
  }

  final offScores = <double>[];
  for (final q in offTopic) {
    final qv = await ollama.embedOne(model: model, input: asQuery(q));
    final hits = store.search(qv, k: 1);
    offScores.add(hits.isEmpty ? 0 : hits.first.score);
  }

  onScores.sort();
  offScores.sort();
  latencies.sort();

  index.dispose();
  return Result(
    model,
    store.dimension,
    chunks.length,
    at1,
    at3,
    at5,
    indexWatch.elapsedMilliseconds,
    latencies[latencies.length ~/ 2],
    onScores,
    offScores,
  );
}

Future<void> _run() async {
  final requested = Platform.environment['MODELS'];
  final models = requested == null || requested.isEmpty
      ? defaultModels
      : requested.split(',').map((s) => s.trim()).toList();
  final ollama = OllamaClient();

  final installed = (await ollama.listModels()).map((m) => m.name).toSet();
  final missing = models.where((m) => !installed.contains(m)).toList();
  if (missing.isNotEmpty) {
    stderr.writeln('Not installed: ${missing.join(', ')}');
    stderr.writeln('Pull them first, e.g. ollama pull ${missing.first}');
    exit(1);
  }

  final files = await findSupportedFiles(Directory('sample_kb'));
  final n = evalSet.length;
  String pct(int h) => '${(h / n * 100).round()}%';
  String f3(double d) => d.toStringAsFixed(3);

  final results = <Result>[];
  for (final model in models) {
    stdout.write('Measuring $model … ');
    results.add(await measure(ollama, files, model,
        prefix: model.startsWith('mxbai')));
    stdout.writeln('done');
  }

  stdout.writeln('\n── Retrieval quality (n=$n, k=5, maxPerSource=2) ──────');
  stdout.writeln('model                      dim   hit@1  hit@3  hit@5');
  for (final r in results) {
    stdout.writeln('${r.model.padRight(26)} ${r.dimension.toString().padLeft(4)}  '
        '${pct(r.at1).padLeft(5)}  ${pct(r.at3).padLeft(5)}  ${pct(r.at5).padLeft(5)}');
  }

  stdout.writeln('\n── Cost ───────────────────────────────────────────────');
  stdout.writeln('model                      index      query');
  for (final r in results) {
    stdout.writeln('${r.model.padRight(26)} ${'${r.indexMs}ms'.padLeft(7)}  '
        '${'${r.queryMs}ms'.padLeft(9)}');
  }

  stdout.writeln('\n── Retrieval gating (threshold is PER MODEL) ──────────');
  stdout.writeln('model                      worst on  best off   gap  → use    '
      'misses  leaks');
  for (final r in results) {
    stdout.writeln('${r.model.padRight(26)} ${f3(r.worstOnTopic).padLeft(8)}  '
        '${f3(r.bestOffTopic).padLeft(8)}  ${f3(r.gap).padLeft(6)}  '
        '${f3(r.threshold).padLeft(5)}${r.separates ? " " : "*"}  '
        '${'${r.missed}/${r.onScores.length}'.padLeft(6)}  '
        '${'${r.leaks}/${r.offScores.length}'.padLeft(5)}');
  }
  stdout.writeln('\n* = the two bands overlap, so no single number is clean.');
  stdout.writeln('The gate then sits at the worst real question and accepts the');
  stdout.writeln('leaks: a blocked question fails silently, a leak is visible.');
  stdout.writeln('misses = real questions the gate blocks. leaks = small talk');
  stdout.writeln('it lets through.');

  // The failure that has no error message: swap the model, keep the constant.
  const hardcoded = 0.57;
  stdout.writeln('\n── If you keep the hardcoded threshold ($hardcoded) ─────────');
  stdout.writeln('model                      on-topic questions still retrieving');
  for (final r in results) {
    final kept = r.onScores.where((s) => s >= hardcoded).length;
    final total = r.onScores.length;
    final flag = kept == 0 ? '  ← RETRIEVAL SILENTLY DEAD' : '';
    stdout.writeln('${r.model.padRight(26)} ${'$kept/$total'.padLeft(6)}  '
        '(range ${f3(r.onScores.first)}–${f3(r.onScores.last)})$flag');
  }

  ollama.close();
}


void main() {
  test('embedding model comparison', _run,
      timeout: const Timeout(Duration(minutes: 30)));
}
