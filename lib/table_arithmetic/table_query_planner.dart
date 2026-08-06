import 'csv_table.dart';

/// Turns a natural-language question into a [TableQuery], or refuses.
///
/// Refusing is the important half. A planner that always produces *something*
/// will confidently answer "how much annual leave do staff get?" with a sum of
/// a sales column. Every rule here is high-precision by design: when the
/// question does not clearly name an aggregation and a column that exists in
/// the data, [planFor] returns null and the caller falls back to ordinary
/// retrieval.
///
/// This is deliberately rule-based rather than a second model call. The rules
/// are deterministic, unit-testable, and add no latency; the production upgrade
/// is to have the LLM emit these same fields as JSON against a schema, then
/// validate them against the real columns exactly as [_resolveMetric] and
/// [_findFilters] do here.
class TableQueryPlanner {
  const TableQueryPlanner._();

  /// Words that mean "combine many rows into one number".
  static final RegExp _sumIntent = RegExp(
      r'\b(total|totals|sum|combined|altogether|overall|how much|revenue for|'
      r'how many)\b',
      caseSensitive: false);

  static final RegExp _averageIntent =
      RegExp(r'\b(average|avg|mean|typical|per week|per month)\b',
          caseSensitive: false);

  static final RegExp _maxIntent =
      RegExp(r'\b(highest|most|maximum|max|best|top|largest)\b',
          caseSensitive: false);

  static final RegExp _minIntent =
      RegExp(r'\b(lowest|least|minimum|min|worst|smallest|fewest)\b',
          caseSensitive: false);

  static final RegExp _countIntent = RegExp(
      r'\b(how many (records|rows|entries|transactions|weeks)|number of '
      r'(records|rows|entries|transactions))\b',
      caseSensitive: false);

  static final RegExp _breakdownIntent = RegExp(
      r'\b(by|per|each|breakdown|broken down)\b',
      caseSensitive: false);

  static const Map<String, int> _months = {
    'january': 1,
    'february': 2,
    'march': 3,
    'april': 4,
    'may': 5,
    'june': 6,
    'july': 7,
    'august': 8,
    'september': 9,
    'october': 10,
    'november': 11,
    'december': 12,
  };

  /// Synonyms mapped onto column-name tokens, so a question can say "sales" and
  /// reach a `revenue_ngn` column. Kept small on purpose — a broad synonym list
  /// is how a planner starts answering questions it should have declined.
  static const Map<String, List<String>> _synonyms = {
    'sales': ['revenue'],
    'earned': ['revenue'],
    'income': ['revenue'],
    'turnover': ['revenue'],
    'naira': ['ngn'],
    'sold': ['units', 'sold'],
    'returns': ['returned'],
    'refunds': ['returned'],
    'price': ['price'],
  };

  static TableQuery? planFor(CsvTable table, String question) {
    if (table.rowCount == 0) return null;
    final q = question.toLowerCase();

    final aggregate = _resolveAggregate(q);
    if (aggregate == null) return null;

    final metric = aggregate == Aggregate.count
        ? null
        : _resolveMetric(table, q);
    // An aggregation verb with no column we recognise is not our question.
    // "How much annual leave do staff get?" lands here, and should.
    if (aggregate != Aggregate.count && metric == null) return null;

    final filters = _findFilters(table, question);
    final range = table.dateColumn == null ? null : _findRange(q);
    final groupBy = _findGroupBy(table, q, filters);

    return TableQuery(
      aggregate: aggregate,
      metric: metric?.name,
      filters: filters,
      range: range,
      groupBy: groupBy,
    );
  }

  static Aggregate? _resolveAggregate(String q) {
    // Order matters: "lowest total" is a min, not a sum.
    if (_countIntent.hasMatch(q)) return Aggregate.count;
    if (_minIntent.hasMatch(q)) return Aggregate.min;
    if (_maxIntent.hasMatch(q)) return Aggregate.max;
    if (_averageIntent.hasMatch(q)) return Aggregate.average;
    if (_sumIntent.hasMatch(q)) return Aggregate.sum;
    return null;
  }

  /// Picks the numeric column whose name tokens best match the question.
  ///
  /// Returns null on a tie, because guessing between `revenue_ngn` and
  /// `unit_price_ngn` produces a plausible number that is wrong, which is the
  /// exact failure this whole feature exists to remove.
  static CsvColumn? _resolveMetric(CsvTable table, String q) {
    final words = q.split(RegExp(r'[^a-z0-9]+')).toSet();
    final expanded = <String>{...words};
    for (final w in words) {
      final syn = _synonyms[w];
      if (syn != null) expanded.addAll(syn);
    }

    CsvColumn? best;
    var bestScore = 0;
    var tied = false;
    for (final col in table.numericColumns) {
      final score = col.tokens.where(expanded.contains).length;
      if (score == 0) continue;
      if (score > bestScore) {
        best = col;
        bestScore = score;
        tied = false;
      } else if (score == bestScore) {
        tied = true;
      }
    }
    return tied ? null : best;
  }

  /// Any distinct value of a text column that appears verbatim in the question.
  static List<ColumnFilter> _findFilters(CsvTable table, String question) {
    final filters = <ColumnFilter>[];
    for (final col in table.textColumns) {
      for (final value in table.distinctValues(col)) {
        if (value.length < 3) continue; // avoid matching stray short tokens
        final pattern = RegExp(
          r'\b' + RegExp.escape(value) + r'\b',
          caseSensitive: false,
        );
        if (pattern.hasMatch(question)) {
          filters.add(ColumnFilter(col.name, value));
          break; // one value per column
        }
      }
    }
    return filters;
  }

  /// "january 2026", "q1 2026", "2026". Anchored to a year so a bare month
  /// never silently spans every year in the data.
  static DateRange? _findRange(String q) {
    final year = RegExp(r'\b(20\d{2})\b').firstMatch(q);
    if (year == null) return null;
    final y = int.parse(year.group(1)!);

    for (final entry in _months.entries) {
      if (!RegExp('\\b${entry.key}\\b').hasMatch(q)) continue;
      final m = entry.value;
      return DateRange(
        DateTime(y, m),
        m == 12 ? DateTime(y + 1, 1) : DateTime(y, m + 1),
        '${entry.key[0].toUpperCase()}${entry.key.substring(1)} $y',
      );
    }

    final quarter = RegExp(r'\bq([1-4])\b').firstMatch(q);
    if (quarter != null) {
      final n = int.parse(quarter.group(1)!);
      final startMonth = (n - 1) * 3 + 1;
      return DateRange(
        DateTime(y, startMonth),
        startMonth + 3 > 12 ? DateTime(y + 1, 1) : DateTime(y, startMonth + 3),
        'Q$n $y',
      );
    }

    return DateRange(DateTime(y), DateTime(y + 1), '$y');
  }

  /// Only group when the question asks for a breakdown *and* names a column
  /// that is not already pinned by a filter.
  static String? _findGroupBy(
      CsvTable table, String q, List<ColumnFilter> filters) {
    if (!_breakdownIntent.hasMatch(q)) return null;
    final pinned = filters.map((f) => f.column.toLowerCase()).toSet();
    for (final col in table.textColumns) {
      if (pinned.contains(col.name.toLowerCase())) continue;
      if (col.tokens.any((t) => RegExp('\\b$t\\b').hasMatch(q))) {
        return col.name;
      }
    }
    return null;
  }
}
