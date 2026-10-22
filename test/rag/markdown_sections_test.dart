import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/rag/markdown_sections.dart';

void main() {
  const handbook =
      '# Staff Handbook\n\nVersion 4.1.\n\n'
      '## Leave\n\nTwenty days a year.\n\n'
      '## Staff discount\n\nAll employees receive a 40% discount.\n';

  test('splits before every heading', () {
    final sections = markdownSections(handbook);
    expect(
      [for (final s in sections) s.text.split('\n').first],
      ['# Staff Handbook', '## Leave', '## Staff discount'],
    );
    expect(sections.last.text, contains('40% discount'));
  });

  test('each start is where the section sits in the file', () {
    for (final s in markdownSections(handbook)) {
      expect(handbook.substring(s.start, s.start + s.text.length), s.text);
    }
  });

  test('the sections put back together are the file', () {
    expect(markdownSections(handbook).map((s) => s.text).join(), handbook);
  });

  test('text before the first heading is a section of its own', () {
    final sections = markdownSections('Intro.\n\n## Leave\n\nTwenty days.');
    expect(sections.first.text, 'Intro.\n\n');
    expect(sections, hasLength(2));
  });

  test('a file with no headings is one section', () {
    expect(markdownSections('Just text.\nMore text.'), [
      (text: 'Just text.\nMore text.', start: 0),
    ]);
  });

  test('a # inside a line is not a heading', () {
    expect(
      markdownSections('Order #12 shipped.\n\nIssue # 4 too.'),
      hasLength(1),
    );
  });
}
