// Extra screens for the FlutterBytes slides, rendered the same way as
// app_preview.dart.
//
//   OUT=/tmp/talk flutter test tool/ui_preview/talk_shots.dart
//
// Writes normal_answer.png (the normal recipe's real reply to the revenue
// question, from talk/eval/before_after.json), stopped.png (Ollama stopped)
// and indexing.png (indexing in progress).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/models/ingest_progress.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:rag_blocks/rag_blocks.dart';

import 'app_preview.dart' as preview;

void main() {
  testWidgets('talk shots', (tester) async {
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/development/flutter';
    late ObjectBoxStore index;
    late Directory dir;
    await tester.runAsync(() async {
      await preview.loadFont(
        '.AppleSystemUIFont',
        '/System/Library/Fonts/SFNS.ttf',
      );
      await preview.loadFont('Roboto', '/System/Library/Fonts/SFNS.ttf');
      await preview.loadFont('Menlo', '/System/Library/Fonts/SFNSMono.ttf');
      await preview.loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      dir = await Directory.systemTemp.createTemp('talk_shots');
      index = await ObjectBoxStore.create(
        Directory('${dir.path}/objectbox'),
        embeddingModel: 'locusai/all-minilm-l6-v2:latest',
        dimension: 384,
      );
      final v = [1.0, ...List<double>.filled(383, 0)];
      // 146 chunks, the optimized recipe's count on sample_kb.
      const files = [
        'company_overview.md',
        'returns_and_warranty.md',
        'sales_q1_2026.csv',
        'staff_handbook.md',
        'suppliers.md',
      ];
      index.addAll([
        for (var i = 0; i < 146; i++)
          Chunk(text: 'x', source: files[i % files.length], index: i),
      ], List.filled(146, v));
    });

    await tester.binding.setSurfaceSize(const Size(1280, 1080));
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      index.close();
      dir.deleteSync(recursive: true);
    });

    // The normal recipe's actual answer, measured on 2026-10-14.
    final normal = preview.fakeController(RagRecipe.normal, index)
      ..turns.addAll([
        Turn(
          role: 'user',
          content: "How much was Stridewell's revenue in ngn in january 2026?",
        ),
        Turn(
          role: 'assistant',
          content:
              'I’m sorry, but none of the excerpts you shared contain a figure '
              'for Stridewell Footwear’s revenue in January 2026. The documents '
              '(company_overview.md, returns_and_warranty.md, suppliers.md) '
              'provide details on structure, locations, staffing, supplier '
              'terms and return policy, but they do not report monthly or '
              'quarterly sales figures.',
          grounded: true,
          sources: [
            preview.hit('company_overview.md', 0, 0.41, 'Stridewell Footwear…'),
            preview.hit('suppliers.md', 2, 0.33, 'Supplier terms…'),
          ],
        ),
      ]);
    await preview.capture(tester, normal, 'normal_answer.png');

    final stopped = preview.fakeController(RagRecipe.normal, index)
      ..ollamaVersion = null
      ..stoppedByUser = true;
    await preview.capture(tester, stopped, 'stopped.png');

    // Taller, so the knowledge-base card below the models is in view.
    await tester.binding.setSurfaceSize(const Size(1280, 1700));
    final indexing = preview.fakeController(RagRecipe.optimized, index)
      ..isIndexing = true
      ..indexingProgress = const IngestProgress('Embedding', done: 92, total: 146);
    await preview.capture(tester, indexing, 'indexing.png');

    final indexed = preview.fakeController(RagRecipe.optimized, index);
    await preview.capture(tester, indexed, 'indexed.png');
  });
}
