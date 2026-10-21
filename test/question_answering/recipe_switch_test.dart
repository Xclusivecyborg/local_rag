// Does the Optimize switch swap the index along with the recipe?
//
//   flutter test test/question_answering/recipe_switch_test.dart
//
// No Ollama needed: the saved indexes are built here, straight on disk, the
// way an earlier indexing run would have left them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rag_blocks/rag_blocks.dart';

const embedModel = 'locusai/all-minilm-l6-v2:latest';

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

void main() {
  late Directory root;
  late RagController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recipe_switch_test');
    PathProviderPlatform.instance = _TempPathProvider(root.path);
    controller = RagController(recipe: RagRecipe.naive)
      ..embedModel = embedModel;
  });

  tearDown(() {
    controller.index?.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Leaves a saved index with [chunkCount] chunks for [recipe], as indexing
  /// would, and closes it so the controller can open it.
  Future<void> saveIndex(RagRecipe recipe, int chunkCount) async {
    final store = await ObjectBoxStore.create(
      ObjectBoxStore.directoryIn(root, folder: recipe.indexFolder),
      embeddingModel: embedModel,
      dimension: 384,
    );
    store.addAll(
      [
        for (var i = 0; i < chunkCount; i++)
          Chunk(text: '${recipe.name} chunk $i', source: 'a.md', index: i),
      ],
      [for (var i = 0; i < chunkCount; i++) List.filled(384, 1 / 384)],
    );
    store.close();
  }

  test('switching opens that recipe\'s own index', () async {
    await saveIndex(RagRecipe.naive, 2);
    await saveIndex(RagRecipe.optimized, 5);

    await controller.setRecipe(RagRecipe.optimized);
    expect(controller.recipe.name, 'optimized');
    expect(controller.index?.size, 5);
    expect(controller.error, isNull);

    await controller.setRecipe(RagRecipe.naive);
    expect(controller.recipe.name, 'naive');
    expect(controller.index?.size, 2);
    expect(controller.error, isNull);
  });

  test('switching to a recipe with no index says how to build one', () async {
    await saveIndex(RagRecipe.naive, 2);
    await controller.setRecipe(RagRecipe.optimized);

    expect(controller.recipe.name, 'optimized');
    expect(controller.index, isNull);
    expect(controller.error, contains('No optimized index yet'));
  });

  test('the conversation survives a switch', () async {
    controller.turns.add(
      Turn(role: 'user', content: 'What is the returns window?'),
    );
    await controller.setRecipe(RagRecipe.optimized);
    expect(controller.turns, hasLength(1));
  });

  test('cannot switch while an answer is streaming', () async {
    controller.isStreaming = true;
    expect(controller.canSwitchRecipe, isFalse);

    await controller.setRecipe(RagRecipe.optimized);
    expect(controller.recipe.name, 'naive');
  });
}
