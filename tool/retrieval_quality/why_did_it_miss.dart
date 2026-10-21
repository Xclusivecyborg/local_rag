// Why did a specific question fail to retrieve?
//
//   flutter test tool/retrieval_quality/why_did_it_miss.dart
//   QUESTIONS="who is Tunde?|what does Adaeze do?" flutter test tool/retrieval_quality/why_did_it_miss.dart
//
// The eval harness answers "how often does retrieval work". This answers the
// other question, the one you actually have at 11pm: *this* question came back
// empty, and I can see the answer in the file with my own eyes. Where did it go?
//
// It prints the full top-5 with scores for each probe, so the failure mode is
// visible rather than inferred: a low score everywhere is an embedding problem,
// a good score on the wrong chunk is a chunking problem, and a good score on
// the right chunk that still lost is a gating problem.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:local_rag/question_answering/model_preferences.dart';
import 'package:local_rag/rag/retrieval_settings.dart';
import '../bench_index.dart';

/// Variants of the same information need. If one form retrieves and another
/// does not, the gap between them is the bug.
const List<String> defaultProbes = <String>[
  'Who is Tunde?',
  'Who is Tunde Balogun?',
  'Tunde',
  'Tunde Balogun',
  'Who are the founders of the company?',
  'Who founded Stridewell?',
  'Who is the Operations Director?',
  'Tell me about the directors of the company',
  // A control from the calibration set: this one is known to work.
  'How many people work at the company?',
];

Future<void> _run() async {
  final ollama = OllamaClient();
  if (await ollama.version() == null) {
    ollama.close();
    markTestSkipped('Ollama is not running — start it with: ollama serve');
    return;
  }

  final model = ModelPreferences.embedding.first;
  final installed = (await ollama.listModels()).map((m) => m.name).toSet();
  final resolved = installed.contains(model) ? model : '$model:latest';

  final probes = Platform.environment['QUESTIONS']
          ?.split('|')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList() ??
      defaultProbes;

  final files = await findSupportedFiles(Directory('sample_kb'));
  final index =
      await buildIndex(ollama: ollama, files: files, embeddingModel: resolved);
  final store = index.store;

  final gate = RetrievalSettings.thresholdFor(resolved);
  stdout.writeln('model: $resolved   gate: $gate   chunks: ${store.size}');
  stdout.writeln('chunks per file: ${store.chunkCountsBySource}');

  for (final q in probes) {
    final qv = await ollama.embedOne(model: resolved, input: q);
    final hits = store.search(qv, k: 5,
        maxPerSource: RetrievalSettings.maxChunksPerSource);
    final best = hits.isEmpty ? 0.0 : hits.first.score;
    final verdict = best >= gate ? 'RETRIEVES' : 'BLOCKED  ';

    stdout.writeln('\n$verdict  ${best.toStringAsFixed(3)}  "$q"');
    for (final h in hits) {
      final head = h.chunk.text
          .replaceAll('\n', ' ')
          .replaceAll(RegExp(r'\s+'), ' ');
      final snippet = head.length > 88 ? '${head.substring(0, 88)}…' : head;
      final mentions = h.chunk.text.contains('Tunde') ? ' *' : '  ';
      stdout.writeln('    ${h.score.toStringAsFixed(3)}$mentions '
          '${h.chunk.source}#${h.chunk.index}  $snippet');
    }
  }

  stdout.writeln('\n* = chunk actually contains "Tunde"');

  index.dispose();
  ollama.close();
}

void main() {
  test('retrieval post-mortem', _run,
      timeout: const Timeout(Duration(minutes: 10)));
}
