// Normal RAG vs optimized RAG, on the same questions, through the same code.
//
//   flutter test tool/retrieval_quality/before_after.dart
//   EMBED=mxbai-embed-large:latest flutter test tool/retrieval_quality/before_after.dart
//
// Both recipes run through RagPipeline.prepare, the exact path the app takes,
// so the only difference between the two columns is the switches in
// RagRecipe. Writes talk/eval/before_after.json.
//
// Three things are measured:
//
//   lookups     Did the excerpts the model saw include the file that holds the
//               answer? (23 questions: long, short and in between)
//   small talk  Was "Hello" answered without dragging in documents? (12)
//   questions   Was the final answer right? The showcase in eval_set.dart:
//               questions normal RAG gets wrong and optimized RAG gets right,
//               plus controls both get right. This one runs the chat model,
//               so it is the slow part.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/rag/rag_pipeline.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:rag_blocks/rag_blocks.dart';

import '../bench_index.dart';
import '../eval_set.dart';

final String embedModel =
    Platform.environment['EMBED'] ?? 'locusai/all-minilm-l6-v2:latest';
final String chatModel = Platform.environment['CHAT'] ?? 'gpt-oss:latest';
const String outputPath = 'talk/eval/before_after.json';

const Map<String, String> lookupEval = {
  ...evalSet,
  ...shortFormEval,
  ...longFormEval,
};

Future<Map<String, Object?>> evaluate(
  OllamaClient ollama,
  RagRecipe recipe,
) async {
  stdout.writeln('\n══ ${recipe.name} ═══════════════════════════════════');
  final index = await buildIndex(
    ollama: ollama,
    files: await findSupportedFiles(Directory('sample_kb')),
    embeddingModel: embedModel,
    recipe: recipe,
  );
  final chunkCount = index.store.size;
  stdout.writeln('$chunkCount chunks, ${index.tables.length} table(s)');
  final pipeline = RagPipeline(ollama, recipe: recipe);

  Future<PreparedPrompt> prepare(String question) => pipeline.prepare(
    question: question,
    chatModel: chatModel,
    embeddingModel: embedModel,
    index: index.store,
    tables: index.tables,
    thinkingModel: true,
  );

  // ---- Lookups --------------------------------------------------------
  final lookups = <Map<String, Object?>>[];
  final prepareMs = <int>[];
  for (final MapEntry(key: question, value: expected) in lookupEval.entries) {
    final clock = Stopwatch()..start();
    final prompt = await prepare(question);
    prepareMs.add(clock.elapsedMilliseconds);
    final seen = [for (final s in prompt.sources) s.chunk.source];
    final hit = seen.contains(expected);
    lookups.add({
      'question': question,
      'expected': expected,
      'seen': seen,
      'hit': hit,
      'hitAt1': seen.firstOrNull == expected,
      'searchedFor': prompt.searchedFor,
    });
    stdout.writeln('${hit ? '✓' : '✗'} $question');
  }

  // ---- Small talk -----------------------------------------------------
  final smallTalk = <Map<String, Object?>>[];
  for (final question in offTopic) {
    final prompt = await prepare(question);
    smallTalk.add({
      'question': question,
      'clean': !prompt.grounded,
      'topScore': prompt.topScore,
    });
    stdout.writeln(
      '${prompt.grounded ? '✗ excerpts' : '✓ clean    '} $question',
    );
  }

  // ---- Questions, end to end -----------------------------------------
  final questions = <Map<String, Object?>>[];
  for (final q in showcase) {
    final prompt = await prepare(q.question);
    final answer = StringBuffer();
    await for (final chunk in pipeline.generate(chatModel, prompt)) {
      if (chunk.content != null) answer.write(chunk.content);
    }
    final text = answer.toString().trim();
    final passed = q.passes(text);
    questions.add({
      'question': q.question,
      'fixedBy': q.fixedBy,
      'passed': passed,
      'grounded': prompt.grounded,
      'computed': prompt.computed != null,
      'answer': text,
    });
    stdout.writeln('${passed ? '✓' : '✗'} ${q.question}');
  }

  index.dispose();
  prepareMs.sort();
  int count(List<Map<String, Object?>> rows, String key) =>
      rows.where((r) => r[key] == true).length;
  return {
    'recipe': recipe.name,
    'optimizations': {for (final o in recipe.optimizations) o.label: o.enabled},
    'chunks': chunkCount,
    'summary': {
      'lookupHit': count(lookups, 'hit'),
      'lookupHitAt1': count(lookups, 'hitAt1'),
      'lookupTotal': lookups.length,
      'smallTalkClean': count(smallTalk, 'clean'),
      'smallTalkTotal': smallTalk.length,
      'questionsPassed': count(questions, 'passed'),
      'questionsTotal': questions.length,
      'medianPrepareMs': prepareMs[prepareMs.length ~/ 2],
    },
    'lookups': lookups,
    'smallTalk': smallTalk,
    'questions': questions,
  };
}

Future<void> _run() async {
  final ollama = OllamaClient();
  final results = [
    for (final recipe in [RagRecipe.normal, RagRecipe.optimized])
      await evaluate(ollama, recipe),
  ];
  ollama.close();

  stdout.writeln('\n── Normal vs optimized ($embedModel, $chatModel) ──');
  String pct(Map s, String hit, String total) =>
      '${(s[hit] / s[total] * 100).round()}% (${s[hit]}/${s[total]})';
  for (final r in results) {
    final s = r['summary'] as Map;
    stdout.writeln(
      '${(r['recipe'] as String).padRight(10)} '
      'lookups ${pct(s, 'lookupHit', 'lookupTotal').padRight(13)} '
      'small talk ${pct(s, 'smallTalkClean', 'smallTalkTotal').padRight(13)} '
      'questions ${pct(s, 'questionsPassed', 'questionsTotal').padRight(10)} '
      'median prepare ${s['medianPrepareMs']}ms',
    );
  }

  final out = File(outputPath)..parent.createSync(recursive: true);
  out.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'measuredOn': DateTime.now().toIso8601String().substring(0, 10),
      'embeddingModel': embedModel,
      'chatModel': chatModel,
      'corpus': 'sample_kb',
      'results': results,
    }),
  );
  stdout.writeln('\nWrote $outputPath');
}

void main() {
  test(
    'normal vs optimized RAG',
    _run,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
