// Does the app's REAL indexing path work on ObjectBox?
//
//   flutter test test/question_answering/index_directory_test.dart
//
// Requires a running Ollama with an embedding model; skips itself otherwise.
//
// Everything else that touches ObjectBox builds an ObjectBoxStore directly.
// This drives the path the user actually triggers — indexDirectory, then save,
// then a fresh controller loading it back — because that path has parts
// nothing else covers: the index factory, closing the old native handle before
// re-indexing, and picking the index up again on startup.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/ollama/ollama_client.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/question_answering/retrieval_settings.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const embedModel = 'locusai/all-minilm-l6-v2:latest';
const chatModel = 'gpt-oss:latest';

/// Redirects application-support to a temp folder for the duration of a test.
class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

const docs = {
  'returns.md': '''
Customers may return unworn footwear within 21 days of purchase for a full
refund. The Heritage line carries an extended 45-day returns window.''',
  'staff.md': '''
Full-time employees accrue 20 working days of paid annual leave per year.
All employees receive a 40% discount on the Everyday line.''',
  'branches.md': '''
The Abuja branch is on Ademola Adetokunbo Crescent in Wuse II.
The Port Harcourt store opened in March 2024.''',
};

void main() {
  late Directory root;
  late Directory kb;
  final controllers = <RagController>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('idx_test');
    kb = Directory('${root.path}/kb')..createSync(recursive: true);
    docs.forEach((name, text) {
      File('${kb.path}/$name').writeAsStringSync(text);
    });
    PathProviderPlatform.instance = _TempPathProvider(root.path);
  });

  tearDown(() {
    for (final c in controllers) {
      c.index?.close();
    }
    controllers.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<RagController?> controllerOrSkip() async {
    final ollama = OllamaClient();
    if (await ollama.version() == null) {
      ollama.close();
      markTestSkipped('Ollama is not running — start it with: ollama serve');
      return null;
    }
    final models = await ollama.listModels();
    if (!models.any((m) => m.name == embedModel)) {
      ollama.close();
      markTestSkipped('$embedModel not installed — ollama pull $embedModel');
      return null;
    }
    final c = RagController(client: ollama)
      ..chatModel = chatModel
      ..embedModel = embedModel;
    controllers.add(c);
    return c;
  }

  test('indexDirectory builds a working ObjectBox index', () async {
    final c = await controllerOrSkip();
    if (c == null) return;

    await c.indexDirectory(kb);

    expect(c.error, isNull, reason: 'indexing must not report an error');
    expect(c.index, isNotNull);
    expect(c.hasIndex, isTrue);
    expect(c.index!.size, greaterThan(0));
    expect(c.index!.sources, containsAll(docs.keys));

    // The database really is on disk where the app expects it.
    expect(Directory('${root.path}/objectbox').existsSync(), isTrue);

    // And it retrieves.
    final qv = await c.ollama.embedOne(model: embedModel, input: 'Abuja branch');
    final hits = c.index!.search(qv, k: 3, maxPerSource: 2);
    expect(hits, isNotEmpty);
    expect(hits.first.chunk.source, 'branches.md');
    expect(hits.first.score, greaterThan(RetrievalSettings.thresholdFor(embedModel)),
        reason: 'an on-topic question must clear the gate for this model');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a fresh controller finds the ObjectBox index on startup', () async {
    final first = await controllerOrSkip();
    if (first == null) return;
    await first.indexDirectory(kb);
    final builtSize = first.index!.size;
    // Release the native handle; two Stores cannot hold one directory.
    first.index!.close();
    first.index = null;

    final second = await controllerOrSkip();
    if (second == null) return;
    await second.connect();

    expect(second.index, isNotNull,
        reason: 'the persisted index should be picked up without re-indexing');
    expect(second.index!.size, builtSize);
    expect(second.index!.embeddingModel, embedModel);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('re-indexing over an existing ObjectBox index does not append',
      () async {
    final c = await controllerOrSkip();
    if (c == null) return;

    await c.indexDirectory(kb);
    final first = c.index!.size;

    // The second run must close the old handle before re-creating the
    // directory, or ObjectBox refuses to open it.
    await c.indexDirectory(kb);
    expect(c.error, isNull);
    expect(c.index!.size, first,
        reason: 're-indexing the same folder must replace, not accumulate');
  }, timeout: const Timeout(Duration(minutes: 4)));

}
