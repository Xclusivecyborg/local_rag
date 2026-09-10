import 'dart:convert';

/// A CSV kept as a *table* rather than flattened into prose.
///
/// The rest of the pipeline turns every file into text and embeds it, which is
/// right for prose and wrong for numbers. Retrieval returns the top _k_ most
/// similar chunks; an aggregation needs *every* matching row. No value of _k_
/// bridges that, and no prompt makes a model add up rows it was never shown.
///
/// So structured files get parsed twice: once into prose for semantic lookup,
/// and once into this, for arithmetic that is actually correct.
class CsvTable {
  CsvTable({required this.source, required this.columns, required this.rows});

  final String source;
  final List<CsvColumn> columns;

  /// Raw cell text, one list per row. Typed access goes through [columns].
  final List<List<String>> rows;

  int get rowCount => rows.length;

  CsvColumn? column(String name) {
    for (final c in columns) {
      if (c.name.toLowerCase() == name.toLowerCase()) return c;
    }
    return null;
  }

  List<CsvColumn> get numericColumns =>
      columns.where((c) => c.kind == ColumnKind.number).toList();
  List<CsvColumn> get textColumns =>
      columns.where((c) => c.kind == ColumnKind.text).toList();
  CsvColumn? get dateColumn {
    for (final c in columns) {
      if (c.kind == ColumnKind.date) return c;
    }
    return null;
  }

  String cell(int row, CsvColumn col) =>
      col.index < rows[row].length ? rows[row][col.index].trim() : '';

  num? number(int row, CsvColumn col) => num.tryParse(cell(row, col));

  DateTime? date(int row, CsvColumn col) => DateTime.tryParse(cell(row, col));

  /// Distinct non-empty values of a text column, preserving original casing.
  Set<String> distinctValues(CsvColumn col) => <String>{
    for (var r = 0; r < rows.length; r++)
      if (cell(r, col).isNotEmpty) cell(r, col),
  };

  /// Parses [raw] and infers a kind per column.
  ///
  /// A column is a number only if *every* non-empty cell parses as one — a
  /// single stray value means the column is text, which is safer than
  /// silently averaging over the rows that happened to parse.
  factory CsvTable.parse(String raw, {required String source}) {
    final grid = parseCsvGrid(raw);
    if (grid.isEmpty) {
      return CsvTable(source: source, columns: const [], rows: const []);
    }

    final header = grid.first;
    final body = <List<String>>[
      for (var r = 1; r < grid.length; r++)
        if (!grid[r].every((c) => c.trim().isEmpty)) grid[r],
    ];

    final columns = <CsvColumn>[];
    for (var c = 0; c < header.length; c++) {
      var sawValue = false;
      var allNumeric = true;
      var allDates = true;
      for (final row in body) {
        final value = c < row.length ? row[c].trim() : '';
        if (value.isEmpty) continue;
        sawValue = true;
        if (num.tryParse(value) == null) allNumeric = false;
        if (DateTime.tryParse(value) == null) allDates = false;
        if (!allNumeric && !allDates) break;
      }
      // Dates first: "2026-01-05" is not a number, but check order matters if
      // a format ever parses as both.
      final kind = !sawValue
          ? ColumnKind.text
          : allDates
          ? ColumnKind.date
          : allNumeric
          ? ColumnKind.number
          : ColumnKind.text;
      columns.add(CsvColumn(header[c].trim(), c, kind));
    }

    return CsvTable(source: source, columns: columns, rows: body);
  }

  /// Runs [query] over **every** row. This is the whole point.
  QueryResult? aggregate(TableQuery query) {
    final metric = query.metric == null ? null : column(query.metric!);
    if (query.aggregate != Aggregate.count && metric == null) return null;

    final matched = <int>[];
    for (var r = 0; r < rows.length; r++) {
      if (!_matches(r, query)) continue;
      matched.add(r);
    }

    num value;
    final groups = <String, num>{};
    final groupCol = query.groupBy == null ? null : column(query.groupBy!);

    if (query.aggregate == Aggregate.count) {
      value = matched.length;
      if (groupCol != null) {
        for (final r in matched) {
          final key = cell(r, groupCol);
          groups[key] = (groups[key] ?? 0) + 1;
        }
      }
    } else {
      final values = <num>[];
      for (final r in matched) {
        final n = number(r, metric!);
        if (n == null) continue;
        values.add(n);
        if (groupCol != null) {
          final key = cell(r, groupCol);
          groups[key] = (groups[key] ?? 0) + n;
        }
      }
      if (values.isEmpty) {
        value = 0;
      } else {
        value = switch (query.aggregate) {
          Aggregate.sum => values.reduce((a, b) => a + b),
          Aggregate.average => values.reduce((a, b) => a + b) / values.length,
          Aggregate.min => values.reduce((a, b) => a < b ? a : b),
          Aggregate.max => values.reduce((a, b) => a > b ? a : b),
          Aggregate.count => values.length,
        };
      }
    }

    return QueryResult(
      query: query,
      source: source,
      value: value,
      matchedRows: matched.length,
      totalRows: rows.length,
      groups: groupCol == null ? null : groups,
    );
  }

  bool _matches(int row, TableQuery query) {
    for (final filter in query.filters) {
      final col = column(filter.column);
      if (col == null) return false;
      if (cell(row, col).toLowerCase() != filter.value.toLowerCase()) {
        return false;
      }
    }
    final range = query.range;
    if (range != null) {
      final col = dateColumn;
      if (col == null) return false;
      final d = date(row, col);
      if (d == null) return false;
      if (d.isBefore(range.start)) return false;
      if (!d.isBefore(range.end)) return false;
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
    rows: [
      for (final r in (json['rows'] as List))
        (r as List).map((e) => e as String).toList(),
    ],
  );

  static String encodeAll(List<CsvTable> tables) => jsonEncode({
    'version': 1,
    'tables': [for (final t in tables) t.toJson()],
  });

  static List<CsvTable> decodeAll(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return [
        for (final t in (json['tables'] as List).cast<Map<String, dynamic>>())
          CsvTable.fromJson(t),
      ];
    } on Object {
      return const []; // corrupt or older schema; caller re-indexes
    }
  }
}

enum ColumnKind { text, number, date }

class CsvColumn {
  const CsvColumn(this.name, this.index, this.kind);
  final String name;
  final int index;
  final ColumnKind kind;

  /// `revenue_ngn` -> {revenue, ngn}. Used to match a column against the words
  /// in a question without hardcoding this particular schema.
  Set<String> get tokens => name
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();

  @override
  String toString() => '$name (${kind.name})';
}

enum Aggregate { sum, average, count, min, max }

class ColumnFilter {
  const ColumnFilter(this.column, this.value);
  final String column;
  final String value;
}

class DateRange {
  const DateRange(this.start, this.end, this.label);

  /// Inclusive.
  final DateTime start;

  /// Exclusive.
  final DateTime end;
  final String label;
}

class TableQuery {
  const TableQuery({
    required this.aggregate,
    this.metric,
    this.filters = const [],
    this.range,
    this.groupBy,
  });

  final Aggregate aggregate;
  final String? metric;
  final List<ColumnFilter> filters;
  final DateRange? range;
  final String? groupBy;

  /// Human-readable restatement, so the UI and the prompt can both show what
  /// was actually computed rather than asking the user to trust a number.
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
        : ' for ${filters.map((f) => '${f.column}=${f.value}').join(', ')}';
    final when = range == null ? '' : ' in ${range!.label}';
    return '$verb$what$where$when';
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
  });

  final TableQuery query;
  final String source;
  final num value;
  final int matchedRows;
  final int totalRows;
  final Map<String, num>? groups;

  bool get isEmpty => matchedRows == 0;

  /// Grouped in thousands, which is how currency and unit counts are read.
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

  String get formattedValue => formatNumber(value);

  /// What gets handed to the model: the figure, and exactly what it covers.
  String toPromptBlock() {
    final buffer = StringBuffer()
      ..writeln('${query.describe()}: $formattedValue')
      ..writeln(
        'Computed over $matchedRows matching row(s) '
        'out of $totalRows in $source.',
      );
    final g = groups;
    if (g != null && g.isNotEmpty) {
      buffer.writeln('Breakdown:');
      final keys = g.keys.toList()..sort();
      for (final k in keys) {
        buffer.writeln('  $k: ${formatNumber(g[k]!)}');
      }
    }
    return buffer.toString();
  }
}

/// Minimal RFC 4180 parser: handles quoted fields, embedded commas,
/// embedded newlines, and "" escapes.
List<List<String>> parseCsvGrid(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
      case ',':
        row.add(field.toString());
        field.clear();
      case '\r':
        break;
      case '\n':
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      default:
        field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
