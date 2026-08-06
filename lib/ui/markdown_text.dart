import 'package:flutter/material.dart';

/// A small Markdown renderer sized for LLM chat output.
///
/// Deliberately not a CommonMark implementation. It covers what models
/// actually emit in conversation — bold, italic, inline code, strikethrough,
/// headings, bullet and numbered lists, block quotes and fenced code — and
/// nothing else.
///
/// Two decisions worth knowing about:
///
///  * **Underscores are not emphasis.** `_foo_` renders literally. Real
///    content is full of identifiers like `revenue_ngn` and `all-MiniLM-L6-v2`,
///    and treating `_` as italic mangles them. Models emit `*` for emphasis
///    almost exclusively, so nothing is lost.
///
///  * **Unterminated markers are styled, not shown.** Mid-stream the text is
///    briefly `Hello **Jam`. Rendering that literally makes asterisks flash on
///    screen and vanish a frame later. An unclosed `**` instead styles the
///    remainder, so the word simply arrives already bold.
///
/// Uses [Text.rich] rather than [SelectableText.rich] so that a single
/// [SelectionArea] higher up can select across blocks and across messages.
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

  double _gapBefore(MdBlock b) => switch (b.kind) {
        BlockKind.heading => 14,
        BlockKind.code => 10,
        BlockKind.bullet || BlockKind.numbered => 4,
        _ => 8,
      };

  Widget _buildBlock(BuildContext context, MdBlock b, TextStyle base) {
    final theme = Theme.of(context);

    switch (b.kind) {
      case BlockKind.heading:
        final scale = switch (b.level) { 1 => 1.35, 2 => 1.2, _ => 1.08 };
        return Text.rich(TextSpan(children: parseInline(b.text, base)),
            style: base.copyWith(
              fontSize: base.fontSize! * scale,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ));

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
              b.text,
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
          child: Text.rich(
            TextSpan(children: parseInline(b.text, base)),
            style: base.copyWith(color: theme.hintColor),
          ),
        );

      case BlockKind.bullet:
      case BlockKind.numbered:
        return Padding(
          padding: EdgeInsets.only(left: 4.0 + b.level * 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: b.kind == BlockKind.bullet ? 18 : 26,
                child: Text(
                  b.kind == BlockKind.bullet ? '•' : b.marker!,
                  style: base.copyWith(color: theme.hintColor),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: parseInline(b.text, base)),
                  style: base,
                ),
              ),
            ],
          ),
        );

      case BlockKind.paragraph:
        return Text.rich(
          TextSpan(children: parseInline(b.text, base)),
          style: base,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Block parsing
// ---------------------------------------------------------------------------

enum BlockKind { paragraph, heading, bullet, numbered, code, quote }

class MdBlock {
  const MdBlock(this.kind, this.text, {this.level = 0, this.marker});
  final BlockKind kind;
  final String text;
  final int level;
  final String? marker; // "1." etc, for numbered items
}

final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+[.)])\s+(.*)$');
final _quote = RegExp(r'^>\s?(.*)$');
final _fence = RegExp(r'^\s*```');

List<MdBlock> parseBlocks(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MdBlock>[];
  final para = <String>[];

  void flushParagraph() {
    if (para.isEmpty) return;
    blocks.add(MdBlock(BlockKind.paragraph, para.join('\n').trim()));
    para.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    if (_fence.hasMatch(line)) {
      flushParagraph();
      final body = <String>[];
      i++;
      while (i < lines.length && !_fence.hasMatch(lines[i])) {
        body.add(lines[i]);
        i++;
      }
      // An unclosed fence mid-stream still renders as a code block.
      blocks.add(MdBlock(BlockKind.code, body.join('\n')));
      continue;
    }

    if (line.trim().isEmpty) {
      flushParagraph();
      continue;
    }

    final h = _heading.firstMatch(line);
    if (h != null) {
      flushParagraph();
      blocks.add(MdBlock(BlockKind.heading, h.group(2)!.trim(),
          level: h.group(1)!.length));
      continue;
    }

    final q = _quote.firstMatch(line);
    if (q != null) {
      flushParagraph();
      blocks.add(MdBlock(BlockKind.quote, q.group(1)!.trim()));
      continue;
    }

    final nu = _numbered.firstMatch(line);
    if (nu != null) {
      flushParagraph();
      blocks.add(MdBlock(
        BlockKind.numbered,
        nu.group(3)!.trim(),
        level: nu.group(1)!.length ~/ 2,
        marker: nu.group(2),
      ));
      continue;
    }

    final b = _bullet.firstMatch(line);
    if (b != null) {
      flushParagraph();
      blocks.add(MdBlock(BlockKind.bullet, b.group(2)!.trim(),
          level: b.group(1)!.length ~/ 2));
      continue;
    }

    para.add(line);
  }
  flushParagraph();

  if (blocks.isEmpty) blocks.add(const MdBlock(BlockKind.paragraph, ''));
  return blocks;
}

// ---------------------------------------------------------------------------
// Inline parsing
// ---------------------------------------------------------------------------

/// Converts a single line of Markdown into styled spans.
///
/// Emphasis nests by recursion: the contents of `**...**` are re-parsed with a
/// bolded base style, so `**bold with *italic* inside**` works.
List<InlineSpan> parseInline(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final buf = StringBuffer();
  var i = 0;

  void flush() {
    if (buf.isEmpty) return;
    spans.add(TextSpan(text: buf.toString(), style: base));
    buf.clear();
  }

  void nested(String inner, TextStyle style) {
    spans.addAll(parseInline(inner, style));
  }

  while (i < text.length) {
    // Inline code — no nesting inside.
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      flush();
      final body = end == -1
          ? text.substring(i + 1)
          : text.substring(i + 1, end);
      spans.add(TextSpan(
        text: body,
        style: base.copyWith(
          fontFamily: 'Menlo',
          fontSize: (base.fontSize ?? 14) - 1,
          backgroundColor: Colors.white10,
        ),
      ));
      i = end == -1 ? text.length : end + 1;
      continue;
    }

    if (text.startsWith('~~', i)) {
      final end = text.indexOf('~~', i + 2);
      if (end != -1) {
        flush();
        nested(text.substring(i + 2, end),
            base.copyWith(decoration: TextDecoration.lineThrough));
        i = end + 2;
        continue;
      }
    }

    if (text.startsWith('**', i)) {
      final end = text.indexOf('**', i + 2);
      flush();
      final bold = base.copyWith(fontWeight: FontWeight.w700);
      if (end == -1) {
        // Streaming: closing marker has not arrived yet.
        nested(text.substring(i + 2), bold);
        i = text.length;
      } else {
        nested(text.substring(i + 2, end), bold);
        i = end + 2;
      }
      continue;
    }

    if (text[i] == '*') {
      final end = text.indexOf('*', i + 1);
      // Require non-empty content; a lone `*` is literal (bullets, maths).
      if (end != -1 && end > i + 1) {
        flush();
        nested(text.substring(i + 1, end),
            base.copyWith(fontStyle: FontStyle.italic));
        i = end + 1;
        continue;
      }
    }

    buf.write(text[i]);
    i++;
  }

  flush();
  return spans;
}
