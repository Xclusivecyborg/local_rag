import 'package:flutter/material.dart';

/// A small Markdown renderer for chat replies.
///
/// Covers what models actually write: bold, italic, inline code,
/// strikethrough, headings, lists, quotes and fenced code. Two deliberate
/// differences from standard Markdown:
///
///  * `_underscores_` are not italic, so names like `revenue_ngn` survive.
///  * An unclosed `**` styles the rest of the line, so while a reply streams
///    in, bold words appear bold instead of flashing asterisks.
///
/// Uses [Text.rich] so one [SelectionArea] can select across messages.
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.data, {super.key, this.style});

  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final blocks = parseBlocks(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : _gapBefore(blocks[i])),
            child: _buildBlock(context, blocks[i], base),
          ),
      ],
    );
  }

  double _gapBefore(MarkdownBlock block) => switch (block.kind) {
    BlockKind.heading => 14,
    BlockKind.code => 10,
    BlockKind.bullet || BlockKind.numbered => 4,
    _ => 8,
  };

  Widget _buildBlock(
    BuildContext context,
    MarkdownBlock block,
    TextStyle base,
  ) {
    final theme = Theme.of(context);
    Widget inline(TextStyle style) => Text.rich(
      TextSpan(children: parseInline(block.text, base)),
      style: style,
    );

    switch (block.kind) {
      case BlockKind.heading:
        final scale = switch (block.level) {
          1 => 1.35,
          2 => 1.2,
          _ => 1.08,
        };
        return inline(
          base.copyWith(
            fontSize: base.fontSize! * scale,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        );

      case BlockKind.code:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              block.text,
              style: base.copyWith(
                fontFamily: 'Menlo',
                fontSize: (base.fontSize ?? 14) - 1.5,
                height: 1.45,
              ),
            ),
          ),
        );

      case BlockKind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.dividerColor, width: 3),
            ),
          ),
          child: inline(base.copyWith(color: theme.hintColor)),
        );

      case BlockKind.bullet:
      case BlockKind.numbered:
        final isBullet = block.kind == BlockKind.bullet;
        return Padding(
          padding: EdgeInsets.only(left: 4.0 + block.level * 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: isBullet ? 18 : 26,
                child: Text(
                  isBullet ? '•' : block.marker!,
                  style: base.copyWith(color: theme.hintColor),
                ),
              ),
              Expanded(child: inline(base)),
            ],
          ),
        );

      case BlockKind.paragraph:
        return inline(base);
    }
  }
}

enum BlockKind { paragraph, heading, bullet, numbered, code, quote }

class MarkdownBlock {
  const MarkdownBlock(this.kind, this.text, {this.level = 0, this.marker});
  final BlockKind kind;
  final String text;
  final int level; // heading level, or list nesting depth
  final String? marker; // "1." etc., for numbered items
}

final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+[.)])\s+(.*)$');
final _quote = RegExp(r'^>\s?(.*)$');
final _fence = RegExp(r'^\s*```');

List<MarkdownBlock> parseBlocks(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];

  void finishParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MarkdownBlock(BlockKind.paragraph, paragraph.join('\n').trim()));
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    if (_fence.hasMatch(line)) {
      finishParagraph();
      final code = <String>[];
      for (i++; i < lines.length && !_fence.hasMatch(lines[i]); i++) {
        code.add(lines[i]);
      }
      // An unclosed fence (still streaming) renders as code too.
      blocks.add(MarkdownBlock(BlockKind.code, code.join('\n')));
      continue;
    }

    if (line.trim().isEmpty) {
      finishParagraph();
      continue;
    }

    final MarkdownBlock? block;
    if (_heading.firstMatch(line) case final m?) {
      block = MarkdownBlock(
        BlockKind.heading,
        m.group(2)!.trim(),
        level: m.group(1)!.length,
      );
    } else if (_quote.firstMatch(line) case final m?) {
      block = MarkdownBlock(BlockKind.quote, m.group(1)!.trim());
    } else if (_numbered.firstMatch(line) case final m?) {
      block = MarkdownBlock(
        BlockKind.numbered,
        m.group(3)!.trim(),
        level: m.group(1)!.length ~/ 2,
        marker: m.group(2),
      );
    } else if (_bullet.firstMatch(line) case final m?) {
      block = MarkdownBlock(
        BlockKind.bullet,
        m.group(2)!.trim(),
        level: m.group(1)!.length ~/ 2,
      );
    } else {
      block = null;
    }

    if (block == null) {
      paragraph.add(line);
    } else {
      finishParagraph();
      blocks.add(block);
    }
  }
  finishParagraph();

  if (blocks.isEmpty) blocks.add(const MarkdownBlock(BlockKind.paragraph, ''));
  return blocks;
}

/// Styles one line of Markdown. Emphasis nests because the text inside a
/// marker is parsed again with the added style.
List<InlineSpan> parseInline(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final plain = StringBuffer();
  var i = 0;

  void finishPlain() {
    if (plain.isEmpty) return;
    spans.add(TextSpan(text: plain.toString(), style: base));
    plain.clear();
  }

  while (i < text.length) {
    // Inline code: nothing inside it is parsed.
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      finishPlain();
      spans.add(
        TextSpan(
          text: text.substring(i + 1, end == -1 ? null : end),
          style: base.copyWith(
            fontFamily: 'Menlo',
            fontSize: (base.fontSize ?? 14) - 1,
            backgroundColor: Colors.white10,
          ),
        ),
      );
      i = end == -1 ? text.length : end + 1;
      continue;
    }

    if (text.startsWith('~~', i)) {
      final end = text.indexOf('~~', i + 2);
      if (end != -1) {
        finishPlain();
        spans.addAll(
          parseInline(
            text.substring(i + 2, end),
            base.copyWith(decoration: TextDecoration.lineThrough),
          ),
        );
        i = end + 2;
        continue;
      }
    }

    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      finishPlain();
      // If the closing ** has not streamed in yet, bold the rest.
      spans.addAll(
        parseInline(
          text.substring(i + 2, end == -1 ? null : end),
          base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
      i = end == -1 ? text.length : end + 2;
      continue;
    }

    if (text[i] == '*') {
      final end = text.indexOf('*', i + 1);
      // A lone `*` (a bullet, a multiplication) stays literal.
      if (end > i + 1) {
        finishPlain();
        spans.addAll(
          parseInline(
            text.substring(i + 1, end),
            base.copyWith(fontStyle: FontStyle.italic),
          ),
        );
        i = end + 1;
        continue;
      }
    }

    plain.write(text[i]);
    i++;
  }

  finishPlain();
  return spans;
}
