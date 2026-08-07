/// A slice of a source document, ready to be embedded.
class Chunk {
  const Chunk({
    required this.text,
    required this.source,
    required this.index,
    this.start = 0,
    this.end = 0,
  });

  final String text;
  final String source; // file name it came from
  final int index; // ordinal within that file

  /// Where this chunk's own content begins in the file **as it is on disk** —
  /// a character offset into the bytes the user could open in an editor, not
  /// into some cleaned-up copy that only exists in memory. LangChain's
  /// `add_start_index` records the same thing.
  ///
  /// Enough to highlight the passage an answer came from, rather than only
  /// being able to name the file.
  final int start;

  /// One past the last character of this chunk's own content.
  ///
  /// `[start, end)` is exact, but [text] is not byte-identical to that span:
  /// paragraphs inside it are rejoined with a blank line and sentences with a
  /// single space, so whitespace can differ. And [text] may open with an
  /// overlap prefix carried from the previous chunk, which lies *before*
  /// [start] — it is repeated context, already covered by that chunk's span.
  final int end;
}

/// Splits text into overlapping chunks, preferring natural boundaries.
///
/// Chunking is where retrieval quality is actually won or lost. Three rules do
/// most of the work:
///
///  1. Never split mid-thought. Break on paragraphs first, sentences second,
///     and only fall back to a hard character cut for pathological input.
///  2. Overlap consecutive chunks, so a fact that straddles a boundary still
///     appears whole in at least one chunk.
///  3. Never exceed [targetChars]. See [kDefaultTargetChars] for why that
///     third rule had to be written down rather than assumed.
///
/// This is the same shape as LangChain's `RecursiveCharacterTextSplitter`, and
/// deliberately not its `CharacterTextSplitter`, which only ever cuts on one
/// separator: hand that a 1,524-character paragraph containing no blank line
/// and it returns a single 1,524-character chunk with a logged warning.
///
/// Where the two differ is overlap. LangChain builds overlap by keeping whole
/// trailing splits while their combined length stays under the overlap budget,
/// so `chunk_overlap` is a ceiling rather than a target — if the last paragraph
/// of a chunk is bigger than the budget it is dropped whole and that boundary
/// gets **no overlap at all**. Measured on `company_overview.md` at 600/200,
/// LangChain carried 29, 191, 58, 0 and 16 characters across its five
/// boundaries; this carried 192, 192, 198, 195, 197 and 198. Rule 2 is the
/// point of overlap, and a boundary that silently gets zero does not honour it.
///
/// Sizes are in characters rather than tokens to keep this dependency-free.
/// A rough rule of thumb for English is ~4 characters per token, so 600 lands
/// around 150 tokens. Counting real tokens would need a tokenizer, and Ollama
/// does not expose one over HTTP.

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
///
/// This is a hard ceiling, which it did not used to be. The overlap tail was
/// written into the buffer the moment a chunk was emitted, and the next block
/// then went in without a size check, so a chunk could reach
/// `targetChars + overlapChars`. Measured: 667 characters against a 600 target
/// on `company_overview.md`, and 802 on input with nothing to break on. The
/// tail is now held back until the following block is known, and trimmed to
/// whatever still fits.
const int kDefaultTargetChars = 600;

/// Default carry-over between consecutive chunks.
///
/// Left at 200 when the target halved, so the overlap is now a third of a
/// chunk rather than a sixth. That is deliberate: 200 is what every number
/// above was measured with, and tightening it to keep the old ratio tidy would
/// invalidate the measurement to fix nothing anyone observed.
///
/// A target rather than a guarantee, for one reason only: a block that is
/// itself close to [kDefaultTargetChars] leaves no room. The overlap then
/// shrinks to what fits instead of pushing the chunk over the ceiling.
const int kDefaultOverlapChars = 200;

final RegExp _paragraphBreak = RegExp(r'\n\s*\n');

// Split after . ! ? followed by whitespace, and after single newlines (which
// matter for line-oriented content like CSV-derived text).
final RegExp _sentenceBreak = RegExp(r'(?<=[.!?])\s+|\n');

List<Chunk> chunkDocument(
  String raw, {
  required String source,
  int targetChars = kDefaultTargetChars,
  int overlapChars = kDefaultOverlapChars,
}) {
  final unified = raw.replaceAll('\r\n', '\n');
  final text = unified.trim();
  if (text.isEmpty) return const [];

  final leading = unified.length - unified.trimLeft().length;
  final dropped = _droppedCarriageReturns(raw);
  int toRaw(int i) => _toRawIndex(i, leading, dropped);

  final blocks = _splitIntoBlocks(text, targetChars);

  final chunks = <Chunk>[];
  final buffer = StringBuffer();
  var index = 0;

  // Span of the blocks currently in [buffer]. `open` is false while the buffer
  // holds nothing but an overlap tail, which belongs to the previous chunk and
  // must not move this one's start backwards.
  var start = 0, end = 0;
  var open = false;

  /// Tail of the chunk just emitted, held rather than written, because how
  /// much of it fits depends on the block that comes next.
  var carry = '';

  void emit() {
    final body = buffer.toString().trim();
    buffer.clear();
    open = false;
    if (body.isEmpty) {
      carry = '';
      return;
    }
    chunks.add(Chunk(
      text: body,
      source: source,
      index: index++,
      start: toRaw(start),
      end: toRaw(end),
    ));
    carry = overlapChars > 0 && body.length > overlapChars
        ? _tail(body, overlapChars)
        : '';
  }

  for (final block in blocks) {
    if (open && buffer.length + block.text.length > targetChars) emit();

    if (!open && carry.isNotEmpty) {
      // Carry as much of the previous chunk's tail as leaves room for this
      // block, rather than all of it or none of it. All of it is what used to
      // breach the ceiling; none of it is what LangChain does, and it is why
      // one of its boundaries above carried nothing.
      final room = targetChars - block.text.length - 2; // the '\n\n' join
      if (room > 0) {
        buffer.write(carry.length <= room ? carry : _tail(carry, room));
        buffer.write('\n\n');
      }
      carry = '';
    }

    if (!open) start = block.start;
    end = block.end;
    open = true;
    buffer.write(block.text);
    buffer.write('\n\n');
  }
  emit();

  return chunks;
}

/// A piece of the source, and where it came from.
class _Block {
  const _Block(this.text, this.start, this.end);
  final String text;

  /// Offsets into the *normalised* text. Converted to file offsets once, at
  /// the point a chunk is built.
  final int start;
  final int end;
}

/// Breaks text into paragraph-sized blocks, further splitting any paragraph
/// that is on its own larger than [maxBlock].
List<_Block> _splitIntoBlocks(String text, int maxBlock) {
  final blocks = <_Block>[];
  for (final paragraph in _sliceOn(text, _paragraphBreak, 0)) {
    if (paragraph.text.length <= maxBlock) {
      blocks.add(paragraph);
      continue;
    }
    blocks.addAll(_splitSentences(paragraph, maxBlock));
  }
  return blocks;
}

List<_Block> _splitSentences(_Block paragraph, int maxBlock) {
  final parts = _sliceOn(paragraph.text, _sentenceBreak, paragraph.start);

  final out = <_Block>[];
  final buf = StringBuffer();
  var start = 0, end = 0;
  var open = false;

  void flush() {
    if (!open) return;
    final body = buf.toString().trim();
    buf.clear();
    open = false;
    if (body.isNotEmpty) out.add(_Block(body, start, end));
  }

  for (final part in parts) {
    if (part.text.length > maxBlock) {
      flush();
      // Last resort: hard cut an unbroken run of characters.
      for (var i = 0; i < part.text.length; i += maxBlock) {
        final stop = (i + maxBlock).clamp(0, part.text.length);
        out.add(_Block(
          part.text.substring(i, stop),
          part.start + i,
          part.start + stop,
        ));
      }
      continue;
    }
    if (open && buf.length + part.text.length > maxBlock) flush();
    if (!open) start = part.start;
    end = part.end;
    open = true;
    buf.write(part.text);
    buf.write(' ');
  }
  flush();
  return out;
}

/// Splits [text] on [pattern], keeping track of where each piece started.
///
/// [base] is added to every offset, so a paragraph can be re-split into
/// sentences and still report positions relative to the whole document. The
/// offset points at the first non-whitespace character, not at the separator
/// that preceded it.
List<_Block> _sliceOn(String text, RegExp pattern, int base) {
  final out = <_Block>[];

  void take(int from, int to) {
    final slice = text.substring(from, to);
    final lead = slice.length - slice.trimLeft().length;
    final body = slice.trim();
    if (body.isEmpty) return;
    final at = base + from + lead;
    out.add(_Block(body, at, at + body.length));
  }

  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    take(cursor, match.start);
    cursor = match.end;
  }
  take(cursor, text.length);
  return out;
}

/// Returns roughly the last [n] characters, snapped forward to a word break.
String _tail(String s, int n) {
  final start = s.length - n;
  final slice = s.substring(start);
  final space = slice.indexOf(' ');
  return space == -1 ? slice : slice.substring(space + 1);
}

/// Positions, in the newline-normalised text, where a `\r` was removed.
///
/// Normalising `\r\n` to `\n` shifts every later character left by one, so a
/// Windows-authored file would otherwise report offsets that drift further
/// from the truth the deeper into the document you read. Empty for the common
/// case, which costs one scan to establish.
List<int> _droppedCarriageReturns(String raw) {
  if (!raw.contains('\r')) return const <int>[];
  final out = <int>[];
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw.codeUnitAt(i) == 0x0D && raw.codeUnitAt(i + 1) == 0x0A) {
      out.add(i - out.length);
    }
  }
  return out;
}

/// Converts a position in the normalised text back to one in the original.
///
/// Reads as a prefix length, not as "the same character": the first
/// [normalised] characters correspond to this many characters of the original,
/// so every `\r` that was dropped *strictly before* the position counts. The
/// distinction only shows up on an exclusive end offset that lands exactly on
/// a collapsed line break, where counting that break would overshoot by one
/// and pull a stray `\r` into the span.
int _toRawIndex(int normalised, int leading, List<int> dropped) {
  final unified = normalised + leading;
  if (dropped.isEmpty) return unified;
  var lo = 0, hi = dropped.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (dropped[mid] < unified) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return unified + lo;
}
