/// A slice of a source document, ready to be embedded.
class Chunk {
  const Chunk({
    required this.text,
    required this.source,
    required this.index,
  });

  final String text;
  final String source; // file name it came from
  final int index; // ordinal within that file
}

/// Splits text into overlapping chunks, preferring natural boundaries.
///
/// Chunking is where retrieval quality is actually won or lost. Two rules do
/// most of the work:
///
///  1. Never split mid-thought. Break on paragraphs first, sentences second,
///     and only fall back to a hard character cut for pathological input.
///  2. Overlap consecutive chunks, so a fact that straddles a boundary still
///     appears whole in at least one chunk.
///
/// Sizes are in characters rather than tokens to keep this dependency-free.
/// A rough rule of thumb for English is ~4 characters per token, so 600 lands
/// around 150 tokens.

/// Default chunk size, named so callers that pass it through cannot drift.
///
/// **This was 1200, and 1200 was quietly breaking retrieval.** A 1200-character
/// chunk of the sample corpus covers the company's founding, its registration,
/// its head count and its store locations all at once, and a chunk's vector is
/// an average of everything in it. A short question — "Who is Tunde?" — cannot
/// match a four-topic average strongly, so it scored 0.238 against a gate of
/// 0.29 and retrieved nothing, while the correct chunk sat at rank 1.
///
/// Measured on sample_kb with tool/retrieval_quality/gate_shape.dart, using
/// 12 short questions the documents genuinely answer:
///
/// | chars | short questions retrieving | canonical hit@1 |
/// |-------|----------------------------|-----------------|
/// | 1200  | 6/12                       | 11/12           |
/// | 600   | 10/12                      | 11/12           |
/// | 350   | 10/12                      | 12/12           |
///
/// 600 captures the whole gain. 350 doubles the chunk count — and so the
/// embedding cost — to buy one place on the canonical set.
const int kDefaultTargetChars = 600;

/// Default carry-over between consecutive chunks.
///
/// Left at 200 when the target halved, so the overlap is now a third of a
/// chunk rather than a sixth. That is deliberate: 200 is what every number
/// above was measured with, and tightening it to keep the old ratio tidy would
/// invalidate the measurement to fix nothing anyone observed.
const int kDefaultOverlapChars = 200;

List<Chunk> chunkDocument(
  String raw, {
  required String source,
  int targetChars = kDefaultTargetChars,
  int overlapChars = kDefaultOverlapChars,
}) {
  final text = raw.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) return const [];

  final blocks = _splitIntoBlocks(text, targetChars);

  final chunks = <Chunk>[];
  final buffer = StringBuffer();
  var index = 0;

  void flush() {
    final body = buffer.toString().trim();
    if (body.isEmpty) return;
    chunks.add(Chunk(text: body, source: source, index: index++));
    buffer.clear();
    if (overlapChars > 0 && body.length > overlapChars) {
      // Carry the tail forward so cross-boundary facts survive.
      buffer.write(_tail(body, overlapChars));
      buffer.write('\n\n');
    }
  }

  for (final block in blocks) {
    if (buffer.length + block.length > targetChars && buffer.isNotEmpty) {
      flush();
    }
    buffer.write(block);
    buffer.write('\n\n');
  }
  flush();

  return chunks;
}

/// Breaks text into paragraph-sized blocks, further splitting any paragraph
/// that is on its own larger than [maxBlock].
List<String> _splitIntoBlocks(String text, int maxBlock) {
  final paragraphs = text
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty);

  final blocks = <String>[];
  for (final p in paragraphs) {
    if (p.length <= maxBlock) {
      blocks.add(p);
      continue;
    }
    blocks.addAll(_splitSentences(p, maxBlock));
  }
  return blocks;
}

List<String> _splitSentences(String paragraph, int maxBlock) {
  // Split after . ! ? followed by whitespace, and after single newlines
  // (which matter for line-oriented content like CSV-derived text).
  final parts = paragraph
      .split(RegExp(r'(?<=[.!?])\s+|\n'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  final out = <String>[];
  final buf = StringBuffer();
  for (final part in parts) {
    if (part.length > maxBlock) {
      if (buf.isNotEmpty) {
        out.add(buf.toString().trim());
        buf.clear();
      }
      // Last resort: hard cut an unbroken run of characters.
      for (var i = 0; i < part.length; i += maxBlock) {
        out.add(part.substring(i, (i + maxBlock).clamp(0, part.length)));
      }
      continue;
    }
    if (buf.length + part.length > maxBlock && buf.isNotEmpty) {
      out.add(buf.toString().trim());
      buf.clear();
    }
    buf.write(part);
    buf.write(' ');
  }
  if (buf.isNotEmpty) out.add(buf.toString().trim());
  return out;
}

/// Returns roughly the last [n] characters, snapped forward to a word break.
String _tail(String s, int n) {
  final start = s.length - n;
  final slice = s.substring(start);
  final space = slice.indexOf(' ');
  return space == -1 ? slice : slice.substring(space + 1);
}
