import 'dart:convert';

import 'package:rag_blocks/rag_blocks.dart' show parseCsvGrid;

/// A CSV file kept as a table, so totals and averages can be computed exactly.
///
/// Retrieval only returns the few most similar chunks, but a total needs every
/// matching row. So CSV files are also indexed as prose (for lookups) and kept
/// here as tables (for arithmetic).
class CsvTable {
  CsvTable({required this.source, required this.columns, required this.rows});

  final String source;
  final List<CsvColumn> columns;
  final List<List<String>> rows; // raw cell text

  int get rowCount => rows.length;

  CsvColumn? column(String name) => columns
      .where((c) => c.name.toLowerCase() == name.toLowerCase())
      .firstOrNull;

  List<CsvColumn> get numericColumns =>
      columns.where((c) => c.kind == ColumnKind.number).toList();
  List<CsvColumn> get textColumns =>
      columns.where((c) => c.kind == ColumnKind.text).toList();
  CsvColumn? get dateColumn =>
      columns.where((c) => c.kind == ColumnKind.date).firstOrNull;

  String cell(int row, CsvColumn col) =>
      col.index < rows[row].length ? rows[row][col.index].trim() : '';

  num? number(int row, CsvColumn col) => num.tryParse(cell(row, col));

  DateTime? date(int row, CsvColumn col) => _parseDate(cell(row, col));

  /// Distinct non-empty values of a column, in their original casing.
  Set<String> distinctValues(CsvColumn col) => {
    for (var r = 0; r < rows.length; r++)
      if (cell(r, col).isNotEmpty) cell(r, col),
  };

  /// Parses [raw] and works out each column's kind.
  ///
  /// A column is numeric only if every non-empty cell is a number. One stray
  /// value makes it text, which is safer than averaging the cells that parsed.
  factory CsvTable.parse(String raw, {required String source}) {
    final grid = parseCsvGrid(raw);
    if (grid.isEmpty) {
      return CsvTable(source: source, columns: const [], rows: const []);
    }

    final header = grid.first;
    final body = [
      for (final row in grid.skip(1))
        if (!row.every((c) => c.trim().isEmpty)) row,
    ];

    final columns = <CsvColumn>[];
    for (var c = 0; c < header.length; c++) {
      var sawValue = false;
      var allNumbers = true;
      var allDates = true;
      for (final row in body) {
        final value = c < row.length ? row[c].trim() : '';
        if (value.isEmpty) continue;
        sawValue = true;
        if (num.tryParse(value) == null) allNumbers = false;
        if (_parseDate(value) == null) allDates = false;
        if (!allNumbers && !allDates) break;
      }
      final kind = !sawValue
          ? ColumnKind.text
          : allNumbers
          ? ColumnKind.number
          : allDates
          ? ColumnKind.date
          : ColumnKind.text;
      columns.add(CsvColumn(header[c].trim(), c, kind));
    }

    return CsvTable(source: source, columns: columns, rows: body);
  }

  /// Runs [query] over every row. Null if the query names an unknown column,
  /// a condition on a column that is not numeric, or both
  /// [TableQuery.groupBy] and [TableQuery.per].
  QueryResult? aggregate(TableQuery query) {
    final isCount = query.aggregate == Aggregate.count;
    final metric = query.metric == null ? null : column(query.metric!);
    if (query.metric != null && metric == null) return null;
    // Per a group, a missing metric means counting rows in each group.
    if (!isCount && metric == null && query.per == null) return null;
    if (query.per != null && query.groupBy != null) return null;
    final grouping = query.per ?? query.groupBy;
    if (grouping != null && !_canGroupBy(grouping)) return null;
    if (query.filters.any((f) => column(f.column) == null)) return null;
    final numeric = query.conditions.every(
      (c) => column(c.column)?.kind == ColumnKind.number,
    );
    if (!numeric) return null;

    final matched = [
      for (var r = 0; r < rows.length; r++)
        if (_matches(r, query)) r,
    ];
    if (query.per != null) return _aggregatePer(query, metric, matched);

    final values = <num>[];
    final groupValues = <String, List<num>>{};
    int? extremeRow;
    num? extreme;
    for (final r in matched) {
      final n = isCount ? 1 : number(r, metric!);
      if (n == null) continue;
      if (extreme == null ||
          (query.aggregate == Aggregate.min && n < extreme) ||
          (query.aggregate == Aggregate.max && n > extreme)) {
        extremeRow = r;
        extreme = n;
      }
      values.add(n);
      final key = grouping == null ? null : _groupKey(r, grouping);
      if (key != null) (groupValues[key] ??= []).add(n);
    }

    final isExtreme =
        query.aggregate == Aggregate.min || query.aggregate == Aggregate.max;
    return QueryResult(
      query: query,
      source: source,
      value: _reduce(query.aggregate, values),
      matchedRows: matched.length,
      totalRows: rows.length,
      // Each group gets the same aggregate as the headline figure, so an
      // average broken down by location lists each location's average.
      groups: grouping == null
          ? null
          : {
              for (final MapEntry(:key, :value) in groupValues.entries)
                key: _reduce(query.aggregate, value),
            },
      extremeRow: isExtreme && extremeRow != null
          ? {
              for (final c in columns)
                if (cell(extremeRow, c).isNotEmpty) c.name: cell(extremeRow, c),
            }
          : null,
    );
  }

  /// [TableQuery.per]: a total for each group first (a row count when there
  /// is no metric), then the aggregate across those totals. "Average revenue
  /// per month" is the average of three monthly totals, not of every row.
  QueryResult _aggregatePer(
    TableQuery query,
    CsvColumn? metric,
    List<int> matched,
  ) {
    final per = query.per!;
    final totals = <String, num>{};
    for (final r in matched) {
      final n = metric == null ? 1 : number(r, metric);
      final key = _groupKey(r, per);
      if (n == null || key == null) continue;
      totals[key] = (totals[key] ?? 0) + n;
    }
    final value = query.aggregate == Aggregate.count
        ? totals.length
        : _reduce(query.aggregate, totals.values.toList());
    final isExtreme =
        query.aggregate == Aggregate.min || query.aggregate == Aggregate.max;
    final top = isExtreme && totals.isNotEmpty
        ? totals.entries.firstWhere((e) => e.value == value).key
        : null;
    return QueryResult(
      query: query,
      source: source,
      value: value,
      matchedRows: matched.length,
      totalRows: rows.length,
      groups: totals,
      extremeRow: top == null ? null : {TableQuery.labelFor(per): top},
    );
  }

  bool _canGroupBy(String grouping) => grouping == TableQuery.month
      ? dateColumn != null
      : column(grouping) != null;

  /// The group row [row] falls in, or null when it has no date to group by.
  String? _groupKey(int row, String grouping) {
    if (grouping != TableQuery.month) return cell(row, column(grouping)!);
    final d = dateColumn == null ? null : date(row, dateColumn!);
    if (d == null) return null;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  static num _reduce(Aggregate aggregate, List<num> values) {
    if (values.isEmpty) return 0;
    return switch (aggregate) {
      Aggregate.sum => values.reduce((a, b) => a + b),
      Aggregate.average => values.reduce((a, b) => a + b) / values.length,
      Aggregate.min => values.reduce((a, b) => a < b ? a : b),
      Aggregate.max => values.reduce((a, b) => a > b ? a : b),
      Aggregate.count => values.length,
    };
  }

  bool _matches(int row, TableQuery query) {
    for (final filter in query.filters) {
      final col = column(filter.column);
      if (col == null) return false;
      final value = cell(row, col).toLowerCase();
      final listed = filter.values.any((v) => v.toLowerCase() == value);
      if (listed == filter.exclude) return false;
    }
    for (final condition in query.conditions) {
      final col = column(condition.column);
      final n = col == null ? null : number(row, col);
      if (n == null || !condition.holds(n)) return false;
    }
    final range = query.range;
    if (range != null) {
      final col = dateColumn;
      final d = col == null ? null : date(row, col);
      if (d == null || d.isBefore(range.start) || !d.isBefore(range.end)) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'columns': [
      for (final c in columns)
        {'name': c.name, 'index': c.index, 'kind': c.kind.name},
    ],
    'rows': rows,
  };

  factory CsvTable.fromJson(Map<String, dynamic> json) => CsvTable(
    source: json['source'] as String,
    columns: [
      for (final c in (json['columns'] as List).cast<Map<String, dynamic>>())
        CsvColumn(
          c['name'] as String,
          c['index'] as int,
          ColumnKind.values.byName(c['kind'] as String),
        ),
    ],
    rows: [for (final r in (json['rows'] as List)) (r as List).cast<String>()],
  );

  static String encodeAll(List<CsvTable> tables) => jsonEncode({
    'version': 1,
    'tables': [for (final t in tables) t.toJson()],
  });

  /// Empty if [raw] is corrupt or from an older format; the user re-indexes.
  static List<CsvTable> decodeAll(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return [
        for (final t in (json['tables'] as List).cast<Map<String, dynamic>>())
          CsvTable.fromJson(t),
      ];
    } on Object {
      return const [];
    }
  }
}

/// A date in a cell, or null. Only `YYYY-MM-DD` (optionally followed by a
/// time) counts: [DateTime.tryParse] alone also accepts `71882000` as the
/// year 7188, which would turn a column of large amounts into dates.
DateTime? _parseDate(String value) =>
    _isoDate.hasMatch(value) ? DateTime.tryParse(value) : null;

final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}');

enum ColumnKind { text, number, date }

class CsvColumn {
  const CsvColumn(this.name, this.index, this.kind);
  final String name;
  final int index;
  final ColumnKind kind;

  /// The words in the column name: `revenue_ngn` gives {revenue, ngn}. Used to
  /// match columns against the words in a question.
  Set<String> get nameWords => name
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();

  @override
  String toString() => '$name (${kind.name})';
}

enum Aggregate { sum, average, count, min, max }

/// Keeps rows whose [column] is one of [values], or, with [exclude], rows
/// whose [column] is none of them. Compared without regard to case.
class ColumnFilter {
  ColumnFilter(this.column, String value) : values = [value], exclude = false;

  const ColumnFilter.anyOf(this.column, this.values, {this.exclude = false});

  final String column;
  final List<String> values;
  final bool exclude;

  /// The first value, for a filter on a single value.
  String get value => values.first;

  String describe() => '$column ${exclude ? 'not ' : ''}${values.join(' or ')}';
}

/// How a [NumberCondition] compares.
enum Comparison {
  greaterThan('>'),
  atLeast('>='),
  lessThan('<'),
  atMost('<=');

  const Comparison(this.symbol);
  final String symbol;

  static Comparison? fromSymbol(String symbol) =>
      values.where((c) => c.symbol == symbol).firstOrNull;
}

/// Keeps rows whose numeric [column] compares to [value], as in "weeks with
/// at least 40 units sold".
class NumberCondition {
  const NumberCondition(this.column, this.comparison, this.value);

  final String column;
  final Comparison comparison;
  final num value;

  bool holds(num n) => switch (comparison) {
    Comparison.greaterThan => n > value,
    Comparison.atLeast => n >= value,
    Comparison.lessThan => n < value,
    Comparison.atMost => n <= value,
  };

  String describe() => '$column ${comparison.symbol} $value';
}

class DateRange {
  const DateRange(this.start, this.end, this.label);
  final DateTime start; // inclusive
  final DateTime end; // exclusive
  final String label;
}

class TableQuery {
  const TableQuery({
    required this.aggregate,
    this.metric,
    this.filters = const [],
    this.conditions = const [],
    this.range,
    this.groupBy,
    this.per,
  });

  /// Pass as [groupBy] or [per] to group by the month of the date column.
  static const String month = '@month';

  final Aggregate aggregate;
  final String? metric; // the column being summed, averaged, etc.
  final List<ColumnFilter> filters;
  final List<NumberCondition> conditions;
  final DateRange? range;

  /// A column (or [month]) to break the result down by, one figure each.
  final String? groupBy;

  /// A column (or [month]) to total by first, so [aggregate] runs over the
  /// totals: "average revenue per month", "location with the most revenue".
  final String? per;

  /// How [groupBy] and [per] read in a description: `month` for [month].
  static String labelFor(String grouping) =>
      grouping == month ? 'month' : grouping;

  /// The query in plain words, so the answer can say what was computed.
  String describe() {
    final verb = switch (aggregate) {
      Aggregate.sum => 'Total',
      Aggregate.average => 'Average',
      Aggregate.count => 'Number of records',
      Aggregate.min => 'Minimum',
      Aggregate.max => 'Maximum',
    };
    final what = metric == null ? '' : ' $metric';
    final where = filters.isEmpty
        ? ''
        : ' for ${filters.map((f) => f.exclude || f.values.length > 1 ? f.describe() : '${f.column}=${f.value}').join(', ')}';
    final conditional = conditions.isEmpty
        ? ''
        : ' where ${conditions.map((c) => c.describe()).join(' and ')}';
    final when = range == null ? '' : ' in ${range!.label}';
    final by = groupBy == null ? '' : ', by ${labelFor(groupBy!)}';
    final rest = '$where$conditional$when$by';
    if (per != null) {
      final unit = labelFor(per!);
      if (aggregate == Aggregate.count) return 'Number of ${unit}s$rest';
      final each = metric == null ? 'record count' : 'total$what';
      return '$verb of each $unit\'s $each$rest';
    }
    return '$verb$what$rest';
  }
}

class QueryResult {
  const QueryResult({
    required this.query,
    required this.source,
    required this.value,
    required this.matchedRows,
    required this.totalRows,
    this.groups,
    this.extremeRow,
  });

  final TableQuery query;
  final String source;
  final num value;
  final int matchedRows;
  final int totalRows;

  /// The aggregate per value of [TableQuery.groupBy], when it is set.
  final Map<String, num>? groups;

  /// For [Aggregate.min] and [Aggregate.max], the row that holds the value,
  /// as column name to cell. It answers "which location had the highest
  /// revenue?". The first such row wins a tie.
  final Map<String, String>? extremeRow;

  bool get isEmpty => matchedRows == 0;

  /// Formats with thousands separators, e.g. 71882000 as 71,882,000.
  static String formatNumber(num n) {
    final rounded = n is int || n == n.roundToDouble()
        ? n.round().toString()
        : n.toStringAsFixed(2);
    final parts = rounded.split('.');
    final digits = parts.first.replaceFirst('-', '');
    final buffer = StringBuffer(rounded.startsWith('-') ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    if (parts.length > 1) buffer.write('.${parts[1]}');
    return buffer.toString();
  }

  /// The figure and what it covers, as given to the chat model.
  String toPromptBlock() {
    final buffer = StringBuffer()
      ..writeln('${query.describe()}: ${formatNumber(value)}')
      ..writeln(
        'Computed over $matchedRows matching row(s) '
        'out of $totalRows in $source.',
      );
    final row = extremeRow;
    if (row != null) {
      final pairs = row.entries.map((e) => '${e.key}=${e.value}').join(', ');
      buffer.writeln(
        query.per == null ? 'Found in the row: $pairs' : 'Belongs to: $pairs',
      );
    }
    final g = groups;
    if (g != null && g.isNotEmpty) {
      buffer.writeln(query.per == null ? 'Breakdown:' : 'Totals:');
      // Months in order; anything else largest first, to answer "which most".
      final byMonth = (query.per ?? query.groupBy) == TableQuery.month;
      final keys = g.keys.toList()
        ..sort(byMonth ? null : (a, b) => g[b]!.compareTo(g[a]!));
      for (final key in keys) {
        buffer.writeln('  $key: ${formatNumber(g[key]!)}');
      }
    }
    return buffer.toString();
  }
}
