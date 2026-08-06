import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';

void main() {
  group('chunker', () {
    test('keeps short documents as a single chunk', () {
      final chunks = chunkDocument('One short paragraph.', source: 'a.md');
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'One short paragraph.');
      expect(chunks.single.source, 'a.md');
    });

    test('splits long documents into multiple chunks', () {
      final paragraph = '${'word ' * 60}\n\n';
      final chunks = chunkDocument(
        paragraph * 10,
        source: 'long.md',
        targetChars: 500,
        overlapChars: 100,
      );
      expect(chunks.length, greaterThan(1));
    });

    test('overlaps consecutive chunks so boundary facts survive', () {
      final blocks =
          List.generate(30, (i) => 'Fact number $i about the business.')
              .join('\n\n');
      final chunks = chunkDocument(
        blocks,
        source: 'facts.md',
        targetChars: 300,
        overlapChars: 80,
      );
      expect(chunks.length, greaterThan(1));
      for (var i = 1; i < chunks.length; i++) {
        final firstWord = chunks[i].text.split(RegExp(r'\s+')).first;
        expect(chunks[i - 1].text, contains(firstWord),
            reason: 'chunk $i should begin with text carried from chunk ${i - 1}');
      }
    });

    test('indexes chunks sequentially from zero', () {
      final chunks = chunkDocument(
        List.generate(20, (i) => 'Paragraph $i. ${'x' * 200}').join('\n\n'),
        source: 'doc.txt',
        targetChars: 400,
      );
      expect(
        chunks.map((c) => c.index).toList(),
        List.generate(chunks.length, (i) => i),
      );
    });

    test('never emits empty or whitespace-only chunks', () {
      final chunks = chunkDocument(
        '\n\n\n   \n\nReal content here.\n\n\n   \n',
        source: 'messy.txt',
      );
      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.text.trim().isNotEmpty), isTrue);
    });

    test('returns nothing for empty input', () {
      expect(chunkDocument('   \n\n  ', source: 'blank.txt'), isEmpty);
    });
  });
}
