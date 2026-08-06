import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/ui/markdown_text.dart';

const base = TextStyle(fontSize: 14);

/// Flattens spans into (text, style) pairs for assertion.
List<(String, TextStyle)> flatten(List<InlineSpan> spans) {
  final out = <(String, TextStyle)>[];
  for (final s in spans) {
    if (s is TextSpan && s.text != null) {
      out.add((s.text!, s.style ?? base));
    }
  }
  return out;
}

List<(String, TextStyle)> inline(String md) => flatten(parseInline(md, base));

String textOf(String md) => inline(md).map((e) => e.$1).join();

TextStyle styleOf(String md, String needle) =>
    inline(md).firstWhere((e) => e.$1 == needle).$2;

void main() {
  group('inline: bold', () {
    test('renders **James** bold and strips the markers', () {
      const md =
          'Hello, My name is **James** and I am your AI assistant.';
      expect(textOf(md),
          'Hello, My name is James and I am your AI assistant.');
      expect(styleOf(md, 'James').fontWeight, FontWeight.w700);
    });

    test('leaves surrounding text unbolded', () {
      const md = 'a **b** c';
      expect(styleOf(md, 'a ').fontWeight, isNot(FontWeight.w700));
      expect(styleOf(md, 'b').fontWeight, FontWeight.w700);
      expect(styleOf(md, ' c').fontWeight, isNot(FontWeight.w700));
    });

    test('handles several bold runs in one line', () {
      const md = '**one** and **two**';
      expect(textOf(md), 'one and two');
      expect(styleOf(md, 'one').fontWeight, FontWeight.w700);
      expect(styleOf(md, 'two').fontWeight, FontWeight.w700);
    });

    test('styles an unterminated run instead of showing asterisks', () {
      // Mid-stream state: the closing ** has not arrived yet.
      const md = 'Hello, My name is **Jam';
      expect(textOf(md), 'Hello, My name is Jam');
      expect(textOf(md), isNot(contains('*')));
      expect(styleOf(md, 'Jam').fontWeight, FontWeight.w700);
    });

    test('bold survives the whole streaming sequence', () {
      const target = 'Hello, My name is **James** and I am here.';
      for (var i = 1; i <= target.length; i++) {
        final partial = target.substring(0, i);
        expect(textOf(partial), isNot(contains('**')),
            reason: 'literal asterisks visible at prefix length $i');
      }
    });
  });

  group('inline: other emphasis', () {
    test('italic', () {
      expect(textOf('an *emphasised* word'), 'an emphasised word');
      expect(styleOf('an *emphasised* word', 'emphasised').fontStyle,
          FontStyle.italic);
    });

    test('italic nested inside bold', () {
      const md = '**bold with *inner* text**';
      expect(textOf(md), 'bold with inner text');
      final s = styleOf(md, 'inner');
      expect(s.fontWeight, FontWeight.w700);
      expect(s.fontStyle, FontStyle.italic);
    });

    test('inline code is monospaced and unstyled otherwise', () {
      const md = 'call `search()` now';
      expect(textOf(md), 'call search() now');
      expect(styleOf(md, 'search()').fontFamily, 'Menlo');
    });

    test('strikethrough', () {
      expect(styleOf('~~gone~~', 'gone').decoration, TextDecoration.lineThrough);
    });

    test('underscores are literal, so identifiers survive', () {
      // This is why `_` is not treated as emphasis: real content is full of
      // snake_case, and italicising it silently corrupts the text.
      expect(textOf('the revenue_ngn column'), 'the revenue_ngn column');
      expect(textOf('model all-MiniLM_L6_v2 here'), 'model all-MiniLM_L6_v2 here');
    });

    test('a lone asterisk is literal', () {
      expect(textOf('2 * 3 = 6'), '2 * 3 = 6');
    });

    test('plain text passes through untouched', () {
      expect(textOf('nothing to see here'), 'nothing to see here');
    });
  });

  group('blocks', () {
    test('headings by level', () {
      final b = parseBlocks('# One\n## Two\n### Three');
      expect(b.map((x) => x.kind), everyElement(BlockKind.heading));
      expect(b.map((x) => x.level), [1, 2, 3]);
      expect(b.map((x) => x.text), ['One', 'Two', 'Three']);
    });

    test('bullet list', () {
      final b = parseBlocks('- first\n- second\n');
      expect(b.map((x) => x.kind), everyElement(BlockKind.bullet));
      expect(b.map((x) => x.text), ['first', 'second']);
    });

    test('numbered list keeps its marker', () {
      final b = parseBlocks('1. first\n2. second');
      expect(b.map((x) => x.kind), everyElement(BlockKind.numbered));
      expect(b.map((x) => x.marker), ['1.', '2.']);
    });

    test('fenced code block keeps its body verbatim', () {
      final b = parseBlocks('before\n\n```\nvar x = 1;\nvar y = 2;\n```\n\nafter');
      final code = b.firstWhere((x) => x.kind == BlockKind.code);
      expect(code.text, 'var x = 1;\nvar y = 2;');
    });

    test('unclosed fence still renders as code while streaming', () {
      final b = parseBlocks('```\nvar x = 1;');
      expect(b.single.kind, BlockKind.code);
      expect(b.single.text, 'var x = 1;');
    });

    test('block quote', () {
      final b = parseBlocks('> quoted line');
      expect(b.single.kind, BlockKind.quote);
      expect(b.single.text, 'quoted line');
    });

    test('blank lines separate paragraphs', () {
      final b = parseBlocks('one\n\ntwo');
      expect(b.length, 2);
      expect(b.map((x) => x.text), ['one', 'two']);
    });

    test('empty input yields one empty paragraph, not a crash', () {
      final b = parseBlocks('');
      expect(b, hasLength(1));
      expect(b.single.text, isEmpty);
    });
  });

  group('widget', () {
    testWidgets('renders bold text on screen without markers',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MarkdownText(
            'Hello, My name is **James** and I am your AI assistant.',
            style: base,
          ),
        ),
      ));

      final widget = tester.widget<Text>(find.byType(Text).first);
      final rendered = widget.textSpan!.toPlainText();
      expect(rendered, 'Hello, My name is James and I am your AI assistant.');
      expect(rendered, isNot(contains('*')));
    });

    testWidgets('renders a mixed document without throwing', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownText(
              '## Summary\n\n'
              'Revenue was **₦45,218,000** across *five* regions.\n\n'
              '- Lagos led with `67M`\n'
              '- Abuja followed\n\n'
              '1. First\n2. Second\n\n'
              '> Note the caveat\n\n'
              '```\ntotal = sum(rows)\n```',
              style: base,
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Summary'), findsWidgets);
    });
  });
}
