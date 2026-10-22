/// A heading in a markdown file: one to six `#` at the start of a line.
final RegExp _heading = RegExp(r'^#{1,6} ', multiLine: true);

/// Splits a markdown file before each heading, with each section's offset in
/// the file.
///
/// Chunking each section on its own means no chunk mixes two topics. Cut
/// across sections, the staff handbook's "40% discount" sentence ended a
/// chunk that was mostly about leave, and no question about discounts found
/// it. Text before the first heading is a section too.
List<({String text, int start})> markdownSections(String text) {
  final starts = [
    0,
    for (final m in _heading.allMatches(text))
      if (m.start > 0) m.start,
  ];
  return [
    for (var i = 0; i < starts.length; i++)
      (
        text: text.substring(
          starts[i],
          i + 1 < starts.length ? starts[i + 1] : text.length,
        ),
        start: starts[i],
      ),
  ];
}
