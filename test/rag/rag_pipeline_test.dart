// What each recipe switch actually changes, against a fake Ollama.
//
// The fake embeds every document as one unit vector and every query as a
// vector at right angles to it, so every retrieval score is 0: well below any
// relevance gate. That makes the gate's effect visible without a live model.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_rag/rag/rag_pipeline.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:rag_blocks/rag_blocks.dart';

const embedModel = 'test-embed';
final docVector = [1.0, ...List<double>.filled(383, 0)];
final queryVector = [0.0, 1.0, ...List<double>.filled(382, 0)];

const salesCsv = '''
week_starting,location,product_line,revenue_ngn
2026-01-05,Lagos,Everyday,1000
2026-01-12,Lagos,Formal,2500
2026-02-02,Abuja,Everyday,4000
''';

/// Batches of more than one input are documents; a single input is a query.
OllamaClient fakeOllama({List<String>? chatRequests}) => OllamaClient(
  client: MockClient.streaming((request, body) async {
    final json = jsonDecode(await body.bytesToString()) as Map;
    String reply;
    if (request.url.path == '/api/embed') {
      final input = json['input'] as List;
      reply = jsonEncode({
        'embeddings': [
          for (final _ in input) input.length == 1 ? queryVector : docVector,
        ],
      });
    } else {
      chatRequests?.add(jsonEncode(json['messages']));
      reply = jsonEncode({
        'message': {'content': 'short query'},
        'done': true,
      });
    }
    return http.StreamedResponse(Stream.value(utf8.encode(reply)), 200);
  }),
);

void main() {
  late Directory dir;
  late Directory kb;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pipeline_test');
    kb = Directory('${dir.path}/kb')..createSync();
    File('${kb.path}/sales.csv').writeAsStringSync(salesCsv);
    File('${kb.path}/returns.md').writeAsStringSync(
      'Unworn footwear may be returned within 21 days.\n\n'
      'The Heritage line has a 45-day returns window.',
    );
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<({ObjectBoxStore store, List<CsvTable> tables})> ingest(
    RagRecipe recipe,
  ) async {
    final result = await RagPipeline(fakeOllama(), recipe: recipe).ingest(
      files: await findSupportedFiles(kb),
      embeddingModel: embedModel,
      createIndex: (model, dimension) => ObjectBoxStore.create(
        Directory('${dir.path}/${recipe.indexFolder}'),
        embeddingModel: model,
        dimension: dimension,
      ),
    );
    addTearDown(result.index.close);
    return (store: result.index, tables: result.tables);
  }

  test('naive indexes raw CSV lines and keeps no tables', () async {
    final index = await ingest(RagRecipe.naive);
    expect(index.tables, isEmpty);

    final hits = index.store.search(docVector, k: 10);
    final csv = hits.where((h) => h.chunk.source == 'sales.csv');
    expect(csv.single.chunk.text, contains('2026-01-05,Lagos,Everyday,1000'));
  });

  test('optimized indexes CSV rows as prose and keeps the table', () async {
    final index = await ingest(RagRecipe.optimized);
    expect(index.tables.single.rowCount, 3);

    final hits = index.store.search(docVector, k: 10);
    final csv = hits.where((h) => h.chunk.source == 'sales.csv');
    expect(csv.first.chunk.text, contains('location: Lagos'));
  });

  test('naive pastes excerpts into every question, even "Hello"', () async {
    final index = await ingest(RagRecipe.naive);
    final prompt = await RagPipeline(fakeOllama(), recipe: RagRecipe.naive)
        .prepare(
          question: 'Hello',
          chatModel: 'test-chat',
          embeddingModel: embedModel,
          index: index.store,
        );

    expect(prompt.threshold, isNull, reason: 'naive has no relevance gate');
    expect(prompt.grounded, isTrue);
    expect(prompt.sources, isNotEmpty);
    expect(prompt.messages.last.content, contains('EXCERPTS'));
  });

  test('optimized drops excerpts that miss the relevance gate', () async {
    final index = await ingest(RagRecipe.optimized);
    final prompt = await RagPipeline(fakeOllama(), recipe: RagRecipe.optimized)
        .prepare(
          question: 'Hello',
          chatModel: 'test-chat',
          embeddingModel: embedModel,
          index: index.store,
        );

    expect(prompt.threshold, isNotNull);
    expect(prompt.topScore, lessThan(prompt.threshold!));
    expect(prompt.grounded, isFalse);
    expect(prompt.sources, isEmpty);
    expect(prompt.messages.last.content, 'Hello');
  });

  test('optimized computes totals; naive retrieves for them', () async {
    const question = 'What was the total revenue in January 2026?';

    final optimized = await ingest(RagRecipe.optimized);
    final computed =
        await RagPipeline(fakeOllama(), recipe: RagRecipe.optimized).prepare(
          question: question,
          chatModel: 'test-chat',
          embeddingModel: embedModel,
          index: optimized.store,
          tables: optimized.tables,
        );
    expect(computed.computed?.value, 3500);
    expect(computed.messages.last.content, contains('COMPUTED RESULT'));

    final naive = await ingest(RagRecipe.naive);
    final retrieved = await RagPipeline(fakeOllama(), recipe: RagRecipe.naive)
        .prepare(
          question: question,
          chatModel: 'test-chat',
          embeddingModel: embedModel,
          index: naive.store,
          // Even handed a table, naive does not use it.
          tables: optimized.tables,
        );
    expect(retrieved.computed, isNull);
    expect(retrieved.grounded, isTrue);
  });

  test('only optimized asks the chat model to condense the question', () async {
    const longQuestion =
        'Can you tell me please what the returns window is for the Heritage '
        'line if I bought it last month?';
    for (final recipe in [RagRecipe.naive, RagRecipe.optimized]) {
      final index = await ingest(recipe);
      final chats = <String>[];
      final prompt =
          await RagPipeline(
            fakeOllama(chatRequests: chats),
            recipe: recipe,
          ).prepare(
            question: longQuestion,
            chatModel: 'test-chat',
            embeddingModel: embedModel,
            index: index.store,
          );
      expect(
        chats,
        hasLength(recipe.condenseQueries ? 1 : 0),
        reason: recipe.name,
      );
      expect(
        prompt.searchedFor,
        recipe.condenseQueries ? 'short query' : isNull,
        reason: recipe.name,
      );
    }
  });

  test('naive gets the tutorial prompt, optimized the guarded one', () async {
    for (final recipe in [RagRecipe.naive, RagRecipe.optimized]) {
      final index = await ingest(recipe);
      final prompt = await RagPipeline(fakeOllama(), recipe: recipe).prepare(
        question: 'Hello',
        chatModel: 'test-chat',
        embeddingModel: embedModel,
        index: index.store,
      );
      expect(
        prompt.messages.first.content.contains('Never invent facts'),
        recipe.guardedPrompt,
        reason: recipe.name,
      );
    }
  });

  test('each recipe has its own index folder', () {
    expect(RagRecipe.optimized.indexFolder, 'objectbox');
    expect(RagRecipe.naive.indexFolder, isNot(RagRecipe.optimized.indexFolder));
    expect(RagRecipe.naive.tablesFile, isNot(RagRecipe.optimized.tablesFile));
  });
}
