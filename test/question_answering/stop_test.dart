import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

const embedModel = 'test-embed';
final vector = List<double>.filled(384, 0.1);

/// A fake Ollama. The first /api/embed call waits for [releaseFirstEmbed], so
/// a test can press Stop while the search is still running. Later embed calls
/// answer at once.
class FakeOllama {
  final firstEmbedStarted = Completer<void>();
  final releaseFirstEmbed = Completer<void>();
  int embedCalls = 0;
  int chatCalls = 0;

  OllamaClient get client => OllamaClient(
    client: MockClient.streaming((request, _) async {
      String body;
      if (request.url.path == '/api/embed') {
        if (embedCalls++ == 0) {
          firstEmbedStarted.complete();
          await releaseFirstEmbed.future;
        }
        body = jsonEncode({
          'embeddings': [vector],
        });
      } else {
        chatCalls++;
        body = [
          jsonEncode({
            'message': {'content': 'answer'},
            'done': false,
          }),
          jsonEncode({'done': true}),
        ].join('\n');
      }
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    }),
  );
}

void main() {
  late Directory dir;
  late RagController controller;
  late FakeOllama fake;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stop_test');
    final index = await ObjectBoxStore.create(
      Directory('${dir.path}/objectbox'),
      embeddingModel: embedModel,
      dimension: vector.length,
    );
    index.addAll([const Chunk(text: 'x', source: 'a.md', index: 0)], [vector]);
    fake = FakeOllama();
    controller = RagController(client: fake.client)
      ..chatModel = 'test-chat'
      ..embedModel = embedModel
      ..index = index
      ..condenseQueries = false; // so /api/chat is only the answer
  });

  tearDown(() {
    controller.index?.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('Stop during the search stops the answer', () async {
    final asking = controller.ask('Hello there');
    await fake.firstEmbedStarted.future;

    await controller.stop();
    fake.releaseFirstEmbed.complete();
    await asking;

    expect(fake.chatCalls, 0, reason: 'no answer should be requested');
    expect(controller.turns.map((t) => t.role), ['user']);
    expect(controller.isStreaming, isFalse);
    expect(controller.streamingAnswer.value, isEmpty);
  });

  test('a stopped question does not answer after a newer one', () async {
    final first = controller.ask('First question');
    await fake.firstEmbedStarted.future;
    await controller.stop();

    await controller.ask('Second question');
    fake.releaseFirstEmbed.complete();
    await first;

    expect(fake.chatCalls, 1, reason: 'only the second question is answered');
    expect(controller.turns.map((t) => t.role), ['user', 'user', 'assistant']);
    expect(controller.isStreaming, isFalse);
  });
}
