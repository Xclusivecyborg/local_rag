// Integration test — REQUIRES a running Ollama with gpt-oss and
// mxbai-embed-large. Skipped automatically if Ollama is unreachable.
//
//   flutter test test/conversation_test.dart
//
// This drives the real RagController, not a copy of its logic, because the
// thing being tested is the retrieval gate and the system prompt working
// together on a live model.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/table_arithmetic/csv_table.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

const chatModel = 'gpt-oss:latest';
const embedModel = 'mxbai-embed-large';
const timeout = Timeout(Duration(minutes: 4));

const docs = {
  'returns.md': '''
Customers may return unworn footwear within 21 days of purchase for a full
refund. The Heritage line carries an extended 45-day returns window.
All footwear carries a six-month manufacturing warranty.''',
  'staff.md': '''
Full-time employees accrue 20 working days of paid annual leave per year,
rising to 25 days after three years of continuous service.
All employees receive a 40% discount on Everyday, Formal and Athletic lines.''',
};

Future<bool> ollamaUp(OllamaClient c) async {
  try {
    await c.listModels();
    return true;
  } on Object {
    return false;
  }
}

Future<RagController> buildController(OllamaClient ollama) async {
  final chunks = <Chunk>[];
  docs.forEach((name, text) {
    chunks.addAll(chunkDocument(text, source: name));
  });
  final vectors = await ollama.embed(
    model: embedModel,
    input: [for (final c in chunks) c.text],
  );
  final dir = await Directory.systemTemp.createTemp('conv_test');
  final store = await ObjectBoxStore.create(
    Directory('${dir.path}/objectbox'),
    embeddingModel: embedModel,
    dimension: vectors.first.length,
  )
    ..addAll(chunks, vectors);

  return RagController(client: ollama)
    ..chatModel = chatModel
    ..embedModel = embedModel
    ..index = store
    ..tables = [
      CsvTable.parse(
        File('sample_kb/sales_q1_2026.csv').readAsStringSync(),
        source: 'sales_q1_2026.csv',
      )
    ];
}

void main() {
  late OllamaClient ollama;
  late bool up;

  setUpAll(() async {
    ollama = OllamaClient();
    up = await ollamaUp(ollama);
  });

  test('greeting is answered conversationally, without retrieval', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);

    await c.ask('Hello');

    final reply = c.turns.last;
    expect(reply.role, 'assistant');
    expect(reply.grounded, isFalse,
        reason: 'a greeting should not trigger document retrieval');
    expect(reply.sources, isEmpty);
    expect(reply.content.trim(), isNotEmpty);
    expect(reply.content.toLowerCase(), isNot(contains('21 days')),
        reason: 'should not leak document content into a greeting');
    expect(reply.topScore, lessThan(c.retrievalThreshold));
  }, timeout: timeout);

  test('general knowledge question is answered without retrieval', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);

    await c.ask('What is the capital of France?');

    final reply = c.turns.last;
    expect(reply.grounded, isFalse);
    expect(reply.content.toLowerCase(), contains('paris'));
  }, timeout: timeout);

  test('company question retrieves and answers from documents', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);

    await c.ask('How many days do I have to return unworn shoes?');

    final reply = c.turns.last;
    expect(reply.grounded, isTrue, reason: 'should have cleared the gate');
    expect(reply.sources, isNotEmpty);
    expect(reply.topScore, greaterThanOrEqualTo(c.retrievalThreshold));
    expect(reply.content, contains('21'));
  }, timeout: timeout);

  test('follow-up question uses conversation history', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);

    await c.ask('How much annual leave do full-time staff get?');
    expect(c.turns.last.content, contains('20'));

    // No noun here — this only resolves if prior turns were replayed.
    await c.ask('And after three years?');

    expect(c.turns.last.content, contains('25'),
        reason: 'follow-up should resolve against the previous turn');
  }, timeout: timeout);

  test('chat works with no index at all', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = RagController(client: ollama)..chatModel = chatModel;

    expect(c.hasIndex, isFalse);
    expect(c.canChat, isTrue);

    await c.ask('Hi there');

    expect(c.turns.last.content.trim(), isNotEmpty);
    expect(c.turns.last.grounded, isFalse);
    expect(c.turns.last.topScore, isNull);
  }, timeout: timeout);

  // ---- The aggregation trap, and the fix ------------------------------

  test('an aggregation is computed exactly, not retrieved', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);
    await c.ask("How much was Stridewell's revenue in ngn in january 2026?");

    final reply = c.turns.last;

    // Answered by computing, not by retrieval. These are mutually exclusive.
    expect(reply.isComputed, isTrue,
        reason: 'should have been routed to the table, not the retriever');
    expect(reply.grounded, isFalse);
    expect(reply.sources, isEmpty);

    // Every January row, not a sample.
    expect(reply.computed!.value, 71882000);
    expect(reply.computed!.matchedRows, 80);
    expect(reply.computed!.totalRows, 240);

    // And the model reported the real figure rather than inventing one.
    final digits = reply.content.replaceAll(RegExp(r'[^0-9]'), '');
    expect(digits, contains('71882000'),
        reason: 'answer should carry the computed total: \n${reply.content}');

    // The number retrieval produced for this exact question was 7,663,000.
    expect(reply.content, isNot(contains('7,663,000')));
  }, timeout: timeout);

  test('a computed answer does not hedge about partial data', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);
    await c.ask('What was our total revenue in Q1 2026?');

    final reply = c.turns.last;
    expect(reply.isComputed, isTrue);
    expect(reply.computed!.value, 204740500);
    expect(reply.computed!.matchedRows, 240);

    // The old prompt made the model warn about partial samples. When the
    // figure is exact, that warning is actively misleading.
    final lower = reply.content.toLowerCase();
    expect(lower, isNot(contains('partial sample')));
    expect(lower, isNot(contains('could be higher')));
  }, timeout: timeout);

  test('prose questions still go through retrieval', () async {
    if (!up) return markTestSkipped('Ollama not running');
    final c = await buildController(ollama);
    await c.ask('How many days do I have to return unworn shoes?');

    final reply = c.turns.last;
    // "How many" is an aggregation word, but no numeric column matches, so
    // the planner must decline and leave this to the retriever.
    expect(reply.isComputed, isFalse);
    expect(reply.grounded, isTrue);
    expect(reply.content, contains('21'));
  }, timeout: timeout);
}
