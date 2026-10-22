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
import 'package:local_rag/rag/optimized_prompt.dart';
import 'package:local_rag/rag/rag_pipeline.dart';
import 'package:local_rag/rag/rag_prompts.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:local_rag/tables/csv_table.dart';
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
/// Every chat request gets [chatReply], except that a request offering tools
/// gets a call to `calculate` with [calculateArguments] when they are given,
/// until a tool result has been sent back.
OllamaClient fakeOllama({
  List<String>? chatRequests,
  List<bool>? toolsOffered,
  String chatReply = 'short query',
  Map<String, dynamic>? calculateArguments,
}) => OllamaClient(
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
      final messages = json['messages'] as List;
      chatRequests?.add(jsonEncode(messages));
      final offered = json['tools'] != null;
      toolsOffered?.add(offered);
      final answered = messages.any((m) => (m as Map)['role'] == 'tool');
      reply = jsonEncode({
        'message': offered && calculateArguments != null && !answered
            ? {
                'content': '',
                'tool_calls': [
                  {
                    'function': {
                      'name': 'calculate',
                      'arguments': calculateArguments,
                    },
                  },
                ],
              }
            : {'content': chatReply},
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
    // A second prose file keeps documents embedding in a batch, which is
    // how the fake tells them from queries, once the CSV is not embedded.
    File(
      '${kb.path}/stores.md',
    ).writeAsStringSync('Stridewell has stores in Lagos and Abuja.');
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

  test('normal indexes raw CSV lines and keeps no tables', () async {
    final index = await ingest(RagRecipe.normal);
    expect(index.tables, isEmpty);

    final hits = index.store.search(docVector, k: 10);
    final csv = hits.where((h) => h.chunk.source == 'sales.csv');
    expect(csv.single.chunk.text, contains('2026-01-05,Lagos,Everyday,1000'));
  });

  test('optimized keeps the CSV as a table and does not embed it', () async {
    final index = await ingest(RagRecipe.optimized);
    expect(index.tables.single.rowCount, 3);

    final hits = index.store.search(docVector, k: 10);
    expect(hits.where((h) => h.chunk.source == 'sales.csv'), isEmpty);
    expect(hits.where((h) => h.chunk.source == 'returns.md'), isNotEmpty);
  });

  test('normal pastes excerpts into every question, even "Hello"', () async {
    final index = await ingest(RagRecipe.normal);
    final prompt = await RagPipeline(fakeOllama(), recipe: RagRecipe.normal)
        .prepare(
          question: 'Hello',
          chatModel: 'test-chat',
          embeddingModel: embedModel,
          index: index.store,
        );

    expect(prompt.threshold, isNull, reason: 'normal has no relevance gate');
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

  test('optimized lets the model calculate; normal never offers it', () async {
    // Short, so the search condenser leaves it alone and every chat
    // request below is the answer.
    const question = 'Total revenue in January 2026?';
    const january = {
      'table': 'sales.csv',
      'aggregate': 'sum',
      'measure': 'revenue_ngn',
      'from': '2026-01-01',
      'to': '2026-01-31',
    };

    final optimized = await ingest(RagRecipe.optimized);
    final chats = <String>[];
    final offered = <bool>[];
    final pipeline = RagPipeline(
      fakeOllama(
        chatRequests: chats,
        toolsOffered: offered,
        chatReply: 'It was 3,500.',
        calculateArguments: january,
      ),
      recipe: RagRecipe.optimized,
    );
    final prompt = await pipeline.prepare(
      question: question,
      chatModel: 'test-chat',
      embeddingModel: embedModel,
      index: optimized.store,
      tables: optimized.tables,
    );
    final answer = await pipeline
        .generate('test-chat', prompt)
        .map((c) => c.content ?? '')
        .join();

    expect(answer, 'It was 3,500.');
    expect(prompt.calculations.single.succeeded, isTrue);
    expect(prompt.computed?.value, 3500);
    // The model was asked again with the result, and tools still offered.
    expect(offered, [true, true]);
    expect(chats.last, contains('"role":"tool"'));
    expect(chats.last, contains('Total revenue_ngn in January 2026: 3,500'));
    expect(prompt.messages.first.content, contains('TABLES YOU CAN CALCULATE'));

    final normal = await ingest(RagRecipe.normal);
    final normalOffered = <bool>[];
    final normalPipeline = RagPipeline(
      fakeOllama(toolsOffered: normalOffered, calculateArguments: january),
      recipe: RagRecipe.normal,
    );
    final retrieved = await normalPipeline.prepare(
      question: question,
      chatModel: 'test-chat',
      embeddingModel: embedModel,
      index: normal.store,
      // Even handed a table, normal does not use it.
      tables: optimized.tables,
    );
    await normalPipeline.generate('test-chat', retrieved).drain<void>();
    expect(normalOffered, [false]);
    expect(retrieved.computed, isNull);
    expect(retrieved.grounded, isTrue);
  });

  test('a calculation that cannot run is sent back as a message', () async {
    final index = await ingest(RagRecipe.optimized);
    final chats = <String>[];
    final pipeline = RagPipeline(
      fakeOllama(
        chatRequests: chats,
        calculateArguments: {
          'table': 'sales.csv',
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'filters': [
            {
              'column': 'location',
              'op': 'is',
              'values': ['Ikeja'],
            },
          ],
        },
      ),
      recipe: RagRecipe.optimized,
    );
    final prompt = await pipeline.prepare(
      question: 'Total revenue for Ikeja?',
      chatModel: 'test-chat',
      embeddingModel: embedModel,
      index: index.store,
      tables: index.tables,
    );
    await pipeline.generate('test-chat', prompt).drain<void>();

    expect(prompt.computed, isNull);
    expect(chats.last, contains('There is no location called'));
  });

  test('only optimized asks the chat model to condense the question', () async {
    const longQuestion =
        'Can you tell me please what the returns window is for the Heritage '
        'line if I bought it last month?';
    for (final recipe in [RagRecipe.normal, RagRecipe.optimized]) {
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

  test('normal gets the tutorial prompt, optimized the guarded one', () async {
    for (final recipe in [RagRecipe.normal, RagRecipe.optimized]) {
      final index = await ingest(recipe);
      final prompt = await RagPipeline(fakeOllama(), recipe: recipe).prepare(
        question: 'Hello',
        chatModel: 'test-chat',
        embeddingModel: embedModel,
        index: index.store,
      );
      expect(
        prompt.messages.first.content.contains('Never invent facts'),
        recipe.fineTunedPrompt,
        reason: recipe.name,
      );
    }
  });

  test('a tool call Ollama cannot read is retried, not fatal', () async {
    final index = await ingest(RagRecipe.optimized);
    var chats = 0;
    final sent = <String>[];
    final ollama = OllamaClient(
      client: MockClient.streaming((request, body) async {
        final json = jsonDecode(await body.bytesToString()) as Map;
        if (request.url.path == '/api/embed') {
          final input = json['input'] as List;
          final reply = jsonEncode({
            'embeddings': [for (final _ in input) queryVector],
          });
          return http.StreamedResponse(Stream.value(utf8.encode(reply)), 200);
        }
        sent.add(jsonEncode(json['messages']));
        final reply = chats++ == 0
            // What Ollama sends when gpt-oss writes `"operator">=`.
            ? jsonEncode({
                'error':
                    'error parsing tool call: raw=\'{"operator">=}\', '
                    "err=invalid character '>' after object key",
              })
            : jsonEncode({
                'message': {'content': 'Which month do you mean?'},
                'done': true,
              });
        return http.StreamedResponse(Stream.value(utf8.encode(reply)), 200);
      }),
    );
    final pipeline = RagPipeline(ollama, recipe: RagRecipe.optimized);
    final prompt = await pipeline.prepare(
      question: 'and February?',
      chatModel: 'test-chat',
      embeddingModel: embedModel,
      index: index.store,
      tables: index.tables,
    );
    final answer = await pipeline
        .generate('test-chat', prompt)
        .map((c) => c.content ?? '')
        .join();

    expect(answer, 'Which month do you mean?');
    expect(sent.last, contains('was not valid JSON'));
  });

  test('optimized asks for missing details; normal does not', () {
    const rule = 'Ask for the missing detail';
    bool asks({required bool grounded}) => RagPrompts.system(
      grounded: grounded,
      strictGrounding: true,
    ).contains(rule);

    expect(asks(grounded: true), isTrue);
    expect(asks(grounded: false), isTrue);
    expect(
      RagPrompts.system(
        grounded: true,
        strictGrounding: false,
        fineTuned: false,
      ).contains(rule),
      isFalse,
      reason: 'normal',
    );
  });

  test('the tool rules and tables come last, only with tables', () {
    const tables = 'TABLES YOU CAN CALCULATE OVER';
    for (final grounded in [true, false]) {
      final prompt = RagPrompts.system(
        grounded: grounded,
        strictGrounding: true,
        tables: tables,
      );
      expect(prompt, endsWith('${OptimizedPrompt.toolRules}\n\n$tables'));
    }
    expect(
      RagPrompts.system(grounded: true, strictGrounding: true),
      isNot(contains('calculate tool')),
    );
  });

  test('each recipe has its own index folder', () {
    expect(RagRecipe.optimized.indexFolder, 'objectbox');
    expect(
      RagRecipe.normal.indexFolder,
      isNot(RagRecipe.optimized.indexFolder),
    );
    expect(RagRecipe.normal.tablesFile, isNot(RagRecipe.optimized.tablesFile));
  });
}
