// Renders the app's screens to PNGs, with real fonts, without running the app
// or needing screen-recording permission.
//
//   flutter test tool/ui_preview/app_preview.dart
//   OUT=/tmp/previews flutter test tool/ui_preview/app_preview.dart
//
// Writes conversation.png (optimized recipe, every kind of answer badge),
// empty.png (naive recipe, first run) and streaming.png (a reply in flight)
// into build/ui_preview/ or $OUT.
//
// flutter_test draws text in a placeholder font, so the macOS system fonts and
// Flutter's Material icons are loaded first under the names the theme asks for.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/models/message_turn.dart';
import 'package:local_rag/question_answering/rag_controller.dart';
import 'package:local_rag/rag/rag_recipe.dart';
import 'package:local_rag/ui/composer.dart';
import 'package:local_rag/ui/sidebar/sidebar.dart';
import 'package:local_rag/ui/theme/app_theme.dart';
import 'package:local_rag/ui/transcript/transcript.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';
import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart';

Future<void> loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  await (FontLoader(
    family,
  )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

ScoredChunk hit(String source, int index, double score, String text) =>
    ScoredChunk(
      StoredChunk(
        text: text,
        source: source,
        index: index,
        embedding: const [],
      ),
      score,
    );

RagController fakeController(RagRecipe recipe, ObjectBoxStore index) =>
    RagController(recipe: recipe)
      ..ollamaVersion = '0.32.5'
      ..models = [
        OllamaModel(
          name: 'gpt-oss:latest',
          capabilities: const ['completion', 'thinking'],
          parameterSize: '20.9B',
        ),
        OllamaModel(
          name: 'locusai/all-minilm-l6-v2:latest',
          capabilities: const ['embedding'],
        ),
      ]
      ..chatModel = 'gpt-oss:latest'
      ..embedModel = 'locusai/all-minilm-l6-v2:latest'
      ..index = index;

List<Turn> conversation() {
  final january = TableQuery(
    aggregate: Aggregate.sum,
    metric: 'revenue_ngn',
    range: DateRange(DateTime(2026), DateTime(2026, 2), 'January 2026'),
  );
  return [
    Turn(
      role: 'user',
      content: 'How many days do I have to return unworn shoes?',
    ),
    Turn(
      role: 'assistant',
      content:
          'You have **21 days** from purchase to return unworn footwear for a '
          'full refund. The Heritage line gets an extended **45-day** window.\n\n'
          'Source: `returns_and_warranty.md`',
      grounded: true,
      topScore: 0.64,
      threshold: 0.22,
      sources: [
        hit(
          'returns_and_warranty.md',
          1,
          0.642,
          'Customers may return unworn footwear within 21 days of purchase '
              'for a full refund. The Heritage line carries an extended 45-day '
              'returns window.',
        ),
        hit(
          'staff_handbook.md',
          4,
          0.311,
          'Staff purchases follow the same returns policy as customers.',
        ),
      ],
    ),
    Turn(
      role: 'user',
      content: "How much was Stridewell's revenue in january 2026?",
    ),
    Turn(
      role: 'assistant',
      content:
          "Stridewell's total revenue in January 2026 was **₦71,882,000**, "
          'computed over all 80 January rows in `sales_q1_2026.csv`.',
      computed: QueryResult(
        query: january,
        source: 'sales_q1_2026.csv',
        value: 71882000,
        matchedRows: 80,
        totalRows: 240,
      ),
    ),
    Turn(role: 'user', content: 'Hello!'),
    Turn(
      role: 'assistant',
      content: 'Hi! Ask me about Stridewell, or anything else.',
      topScore: 0.19,
      threshold: 0.22,
    ),
  ];
}

Future<void> capture(
  WidgetTester tester,
  RagController c,
  String file, {
  void Function()? afterPump,
}) async {
  final key = GlobalKey();
  final scroll = ScrollController();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark().copyWith(platform: TargetPlatform.macOS),
      home: RepaintBoundary(
        key: key,
        child: Scaffold(
          body: Row(
            children: [
              Sidebar(controller: c, onPick: () {}),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Transcript(
                        controller: c,
                        scroll: scroll,
                        onAsk: (_) {},
                      ),
                    ),
                    Composer(
                      controller: c,
                      input: TextEditingController(),
                      onSend: () {},
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  afterPump?.call();
  // A streaming reply shows a spinner that never settles, so pump a fixed
  // number of frames instead of waiting for it.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  final out = Platform.environment['OUT'] ?? 'build/ui_preview';
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$out/$file')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('Wrote $out/$file');
}

void main() {
  testWidgets('app preview', (tester) async {
    final flutterRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/development/flutter';
    late ObjectBoxStore index;
    late Directory dir;
    await tester.runAsync(() async {
      await loadFont('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf');
      await loadFont('Roboto', '/System/Library/Fonts/SFNS.ttf');
      await loadFont('Menlo', '/System/Library/Fonts/SFNSMono.ttf');
      await loadFont(
        'MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      // A tiny real index, so the knowledge-base card has something to show.
      dir = await Directory.systemTemp.createTemp('ui_preview');
      index = await ObjectBoxStore.create(
        Directory('${dir.path}/objectbox'),
        embeddingModel: 'locusai/all-minilm-l6-v2:latest',
        dimension: 384,
      );
      final v = [1.0, ...List<double>.filled(383, 0)];
      index.addAll([
        for (final (i, f) in [
          'company_overview.md',
          'returns_and_warranty.md',
          'sales_q1_2026.csv',
          'staff_handbook.md',
          'suppliers.md',
        ].indexed)
          Chunk(text: 'x', source: f, index: i),
      ], List.filled(5, v));
    });

    await tester.binding.setSurfaceSize(const Size(1280, 1080));
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      index.close();
      dir.deleteSync(recursive: true);
    });

    final optimized = fakeController(RagRecipe.optimized, index)
      ..turns.addAll(conversation());
    await capture(tester, optimized, 'conversation.png');

    final naive = fakeController(RagRecipe.naive, index);
    await capture(tester, naive, 'empty.png');

    final streaming = fakeController(RagRecipe.optimized, index)
      ..turns.add(
        Turn(
          role: 'user',
          content: 'What is the warranty on the Heritage line?',
        ),
      )
      ..isStreaming = true;
    streaming.streamingThinking.value =
        'The user asks about the Heritage warranty. The excerpt from '
        'returns_and_warranty.md says all footwear has six months, Heritage '
        'gets twelve…';
    streaming.streamingAnswer.value =
        'The Heritage line carries a **12-month** manufacturing warranty,';
    await capture(tester, streaming, 'streaming.png');
  });
}
