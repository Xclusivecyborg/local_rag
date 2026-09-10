// Can the retrieval gate be made to pass short entity questions without also
// passing small talk?
//
//   flutter test tool/retrieval_quality/gate_shape.dart
//
// The current gate is a single number compared against the top score. It was
// calibrated on 12 long descriptive questions, and it works for those. Short
// entity questions ("Who is Tunde?") score *below* it while still ranking the
// correct chunk first, and they land in the same band as small talk — so no
// value of that single number separates them.
//
// This measures two alternatives that use information the current gate throws
// away:
//
//   MARGIN  — how far the top hit is ahead of the runner-up. A question the
//             corpus can answer should have one clear winner; small talk
//             should match everything equally badly.
//   CHUNK   — whether smaller chunks raise the score, on the theory that the
//             score is low because a 1200-char chunk's vector is an average of
//             four topics and cannot match a three-word question strongly.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/ingest.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/question_answering/model_preferences.dart';
import 'package:local_rag/question_answering/retrieval_settings.dart';
import 'package:local_rag/vector_search/stored_chunk.dart';
import '../bench_index.dart';
import '../eval_set.dart';

class Probe {
  Probe(this.question, this.hits);
  final String question;
  final List<ScoredChunk> hits;

  double get top => hits.isEmpty ? 0 : hits.first.score;
  double get second => hits.length < 2 ? 0 : hits[1].score;

  /// How far ahead the winner is, relative to the winner's own score. Relative
  /// rather than absolute because the absolute scale differs per model, which
  /// is the trap the fixed gate already fell into.
  double get margin => top <= 0 ? 0 : (top - second) / top;
}

String f3(double d) => d.toStringAsFixed(3);

Future<List<Probe>> probeAll(
  OllamaClient ollama,
  dynamic store,
  String model,
  List<String> questions,
) async {
  final out = <Probe>[];
  for (final q in questions) {
    final qv = await ollama.embedOne(model: model, input: q);
    out.add(Probe(
      q,
      store.search(qv, k: 5, maxPerSource: RetrievalSettings.maxChunksPerSource)
          as List<ScoredChunk>,
    ));
  }
  return out;
}

/// Best accuracy achievable by thresholding [value] alone, and where.
({double at, int correct, int total}) bestSplit(
  List<Probe> on,
  List<Probe> off,
  double Function(Probe) value,
) {
  final candidates = <double>{
    for (final p in [...on, ...off]) value(p),
  }.toList()
    ..sort();

  var bestAt = 0.0, bestCorrect = -1;
  for (final c in candidates) {
    final correct = on.where((p) => value(p) >= c).length +
        off.where((p) => value(p) < c).length;
    if (correct > bestCorrect) {
      bestCorrect = correct;
      bestAt = c;
    }
  }
  return (at: bestAt, correct: bestCorrect, total: on.length + off.length);
}

Future<void> _report(
  OllamaClient ollama,
  List<File> files,
  String model,
  int chunkSize,
) async {
  final index = await buildIndex(
    ollama: ollama,
    files: files,
    embeddingModel: model,
    chunkSize: chunkSize,
  );
  final store = index.store;

  final on = await probeAll(ollama, store, model, gateProbes);
  final off = await probeAll(ollama, store, model, offTopic);

  final onTop = on.map((p) => p.top).toList()..sort();
  final offTop = off.map((p) => p.top).toList()..sort();
  final onMargin = on.map((p) => p.margin).toList()..sort();
  final offMargin = off.map((p) => p.margin).toList()..sort();

  final byTop = bestSplit(on, off, (p) => p.top);
  final byMargin = bestSplit(on, off, (p) => p.margin);

  stdout.writeln('\n══ chunk size $chunkSize chars '
      '(${store.size} chunks) ══════════════');
  stdout.writeln('              worst on-topic   best off-topic   overlap?');
  stdout.writeln('  top score   ${f3(onTop.first).padLeft(12)}   '
      '${f3(offTop.last).padLeft(14)}   '
      '${onTop.first > offTop.last ? "no" : "YES"}');
  stdout.writeln('  margin      ${f3(onMargin.first).padLeft(12)}   '
      '${f3(offMargin.last).padLeft(14)}   '
      '${onMargin.first > offMargin.last ? "no" : "YES"}');
  stdout.writeln('  best split by top score: ${byTop.correct}/${byTop.total} '
      'correct at ${f3(byTop.at)}');
  stdout.writeln('  best split by margin:    '
      '${byMargin.correct}/${byMargin.total} correct at ${f3(byMargin.at)}');

  final gate = RetrievalSettings.thresholdFor(model);
  final passing = on.where((p) => p.top >= gate).length;
  stdout.writeln('  with the shipping gate ($gate): '
      '$passing/${on.length} real questions retrieve');

  // Does helping the short questions cost the long ones anything? A fix that
  // trades one failure for another is not a fix, and without this it looks
  // like one.
  var at1 = 0, at5 = 0, cleared = 0;
  for (final e in evalSet.entries) {
    final qv = await ollama.embedOne(model: model, input: e.key);
    final hits = store.search(qv, k: 5,
        maxPerSource: RetrievalSettings.maxChunksPerSource);
    final ranked = hits.map((h) => h.chunk.source).toList();
    if (ranked.take(1).contains(e.value)) at1++;
    if (ranked.contains(e.value)) at5++;
    if (hits.isNotEmpty && hits.first.score >= gate) cleared++;
  }
  final n = evalSet.length;
  stdout.writeln('  canonical eval: hit@1 $at1/$n  hit@5 $at5/$n  '
      'clears gate $cleared/$n');

  stdout.writeln('  --- on-topic ---');
  for (final p in on) {
    stdout.writeln('  ${f3(p.top)}  margin ${f3(p.margin)}  '
        '${p.top >= gate ? " " : "✗"} ${p.question}');
  }
  stdout.writeln('  --- off-topic ---');
  for (final p in off) {
    stdout.writeln('  ${f3(p.top)}  margin ${f3(p.margin)}  '
        '${p.top >= gate ? "!" : " "} ${p.question}');
  }

  index.dispose();
}

Future<void> _run() async {
  final ollama = OllamaClient();
  if (await ollama.version() == null) {
    ollama.close();
    markTestSkipped('Ollama is not running — start it with: ollama serve');
    return;
  }

  final want = ModelPreferences.embedding.first;
  final installed = (await ollama.listModels()).map((m) => m.name).toSet();
  final model = installed.contains(want) ? want : '$want:latest';

  final files = await findSupportedFiles(Directory('sample_kb'));

  stdout.writeln('model: $model');
  stdout.writeln('✗ = a real question the gate blocks   '
      '! = small talk the gate lets through');

  for (final size in [1200, 600, 350]) {
    await _report(ollama, files, model, size);
  }

  ollama.close();
}

void main() {
  test('gate shape', _run, timeout: const Timeout(Duration(minutes: 20)));
}
