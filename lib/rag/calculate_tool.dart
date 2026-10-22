import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart' show Tool, ToolCall;

/// Lets a chat model ask for exact figures from CSV tables by tool calling.
///
/// The model decides when a question needs a calculation and fills in a
/// request; this checks the request against the tables and runs it with
/// [CsvTable.aggregate], so the arithmetic is done by code, over every row.
///
/// ```dart
/// final calculator = CalculateTool(tables);
/// final reply = await ollama.chat(
///   model: 'gpt-oss',
///   messages: [
///     ChatMessage('system', '...\n\n${calculator.describeTables()}'),
///     ChatMessage('user', 'What was our total revenue in Q1 2026?'),
///   ],
///   tools: [calculator.definition],
/// );
/// for (final call in reply.toolCalls) {
///   final result = calculator.run(call); // send back as a tool result
/// }
/// ```
///
/// A request that cannot run comes back as a [CalculateOutcome] whose text
/// says why, such as "no location called Ikeja; did you mean Ikeja City
/// Mall?", so the model can correct itself or ask the user.
class CalculateTool {
  CalculateTool(this.tables, {this.maxListedValues = 30});

  /// The tables the model may calculate over. Each is named by its source.
  final List<CsvTable> tables;

  /// Text columns with more distinct values than this are described by a
  /// sample rather than listed in full.
  final int maxListedValues;

  static const String name = 'calculate';

  /// The word for grouping by month in `group_by` and `per`.
  static const String monthWord = 'month';

  /// Tells the model when to call the tool. It decides from this alone.
  static const String toolDescription =
      'Calculate an exact figure over every row of a table: a total, count, '
      'average, minimum or maximum, optionally per group. Use it for any '
      'question that needs numbers from more than one row. Never add numbers '
      'up yourself. If the question leaves out something you need, such as '
      'the year, the measure, or which store, ask the user instead of calling '
      'this.';

  /// The tool to offer the model.
  Tool get definition =>
      Tool(name: name, description: toolDescription, parameters: _schema());

  Map<String, dynamic> _schema() {
    final numberColumns = {
      for (final t in tables)
        for (final c in t.numericColumns) c.name,
    }.toList();
    final textColumns = {
      for (final t in tables)
        for (final c in t.textColumns) c.name,
    }.toList();
    final groupings = [...textColumns, monthWord];
    return {
      'type': 'object',
      'required': ['table', 'aggregate'],
      'properties': {
        'table': {
          'type': 'string',
          'enum': [for (final t in tables) t.source],
        },
        'aggregate': {
          'type': 'string',
          'enum': [for (final a in Aggregate.values) a.name],
        },
        'measure': {
          'type': 'string',
          'enum': numberColumns,
          'description':
              'The number column to aggregate. Leave out to count rows.',
        },
        'filters': {
          'type': 'array',
          'description': 'Keep only rows that match all of these.',
          'items': {
            'type': 'object',
            'required': ['column', 'op', 'values'],
            'properties': {
              'column': {'type': 'string', 'enum': textColumns},
              'op': {
                'type': 'string',
                'enum': ['is', 'is_not'],
              },
              'values': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        },
        'conditions': {
          'type': 'array',
          'description': 'Conditions on number columns, e.g. units_sold >= 40.',
          'items': {
            'type': 'object',
            'required': ['column', 'op', 'value'],
            'properties': {
              'column': {'type': 'string', 'enum': numberColumns},
              'op': {
                'type': 'string',
                'enum': [for (final c in Comparison.values) c.symbol],
              },
              'value': {'type': 'number'},
            },
          },
        },
        'from': {
          'type': 'string',
          'description': 'First day to include, YYYY-MM-DD.',
        },
        'to': {
          'type': 'string',
          'description': 'Last day to include, YYYY-MM-DD.',
        },
        'group_by': {
          'type': 'string',
          'enum': groupings,
          'description':
              'Give one figure per group, largest first. Leave out for one '
              'overall figure.',
        },
        'per': {
          'type': 'string',
          'enum': groupings,
          'description':
              'Total per group first, then aggregate those totals: '
              '"average revenue per month" is aggregate average, per month. '
              '"Which location sold the most" is aggregate max, per location. '
              'Leave out for one overall figure.',
        },
      },
    };
  }

  /// What the model needs to know to ask good questions and fill in calls:
  /// each table's columns, its values, and the dates it covers.
  String describeTables() {
    final buffer = StringBuffer(
      'TABLES YOU CAN CALCULATE OVER (with the $name tool)\n',
    );
    for (final table in tables) {
      buffer.writeln('\n${table.source}: ${table.rowCount} rows');
      final width = table.columns.fold<int>(
        0,
        (w, c) => c.name.length > w ? c.name.length : w,
      );
      for (final column in table.columns) {
        buffer.writeln(
          '  ${column.name.padRight(width)}  ${_describeColumn(table, column)}',
        );
      }
    }
    return buffer.toString().trimRight();
  }

  String _describeColumn(CsvTable table, CsvColumn column) {
    switch (column.kind) {
      case ColumnKind.date:
        final dates = [
          for (var r = 0; r < table.rowCount; r++) ?table.date(r, column),
        ]..sort();
        if (dates.isEmpty) return 'date';
        return 'date, ${_day(dates.first)} to ${_day(dates.last)}';
      case ColumnKind.number:
        final numbers = [
          for (var r = 0; r < table.rowCount; r++) ?table.number(r, column),
        ];
        if (numbers.isEmpty) return 'number';
        final low = numbers.reduce((a, b) => a < b ? a : b);
        final high = numbers.reduce((a, b) => a > b ? a : b);
        return 'number, ${QueryResult.formatNumber(low)} to '
            '${QueryResult.formatNumber(high)}';
      case ColumnKind.text:
        final values = table.distinctValues(column).toList()..sort();
        if (values.length <= maxListedValues) return values.join(', ');
        return '${values.length} different values, e.g. '
            '${values.take(5).join(', ')}';
    }
  }

  /// Checks [call] and runs it. Never throws: a request that cannot run
  /// gets an outcome explaining why, worded for the model to act on.
  CalculateOutcome run(ToolCall call) {
    if (call.name != name) {
      return CalculateOutcome.error(
        call,
        'There is no tool called "${call.name}".',
      );
    }
    final parsed = parse(call.arguments);
    if (parsed.error != null) {
      return CalculateOutcome.error(call, parsed.error!);
    }
    final (table, query) = parsed.request!;
    final result = table.aggregate(query);
    if (result == null) {
      return CalculateOutcome.error(call, 'That calculation could not be run.');
    }
    if (result.isEmpty) {
      return CalculateOutcome.error(
        call,
        'No rows match: ${query.describe()}. ${_coverage(table)}',
      );
    }
    return CalculateOutcome.success(call, result);
  }

  /// The table and query [arguments] ask for, or an error saying what is
  /// wrong with them.
  ({(CsvTable, TableQuery)? request, String? error}) parse(
    Map<String, dynamic> arguments,
  ) {
    ({(CsvTable, TableQuery)? request, String? error}) fail(String why) =>
        (request: null, error: why);

    final tableName = arguments['table'];
    final table = tables.where((t) => t.source == tableName).firstOrNull;
    if (table == null) {
      return fail(
        'There is no table called "$tableName". Tables: '
        '${tables.map((t) => t.source).join(', ')}.',
      );
    }

    final aggregateName = arguments['aggregate'];
    final aggregate = Aggregate.values
        .where((a) => a.name == aggregateName)
        .firstOrNull;
    if (aggregate == null) {
      return fail(
        '"aggregate" must be one of '
        '${Aggregate.values.map((a) => a.name).join(', ')}.',
      );
    }

    final measure = arguments['measure'] as String?;
    if (measure != null && !_isNumber(table, measure)) {
      return fail(
        '"$measure" is not a number column in ${table.source}. Number '
        'columns: ${table.numericColumns.map((c) => c.name).join(', ')}.',
      );
    }
    final per = _grouping(arguments['per']);
    final groupBy = _grouping(arguments['group_by']);
    if (measure == null && aggregate != Aggregate.count && per == null) {
      return fail('Say which "measure" to ${aggregate.name}.');
    }
    if (per != null && groupBy != null) {
      return fail('Use "per" or "group_by", not both.');
    }
    for (final grouping in [?per, ?groupBy]) {
      final error = _checkGrouping(table, grouping);
      if (error != null) return fail(error);
    }

    final filters = <ColumnFilter>[];
    final rawFilters = _items(arguments['filters'], _filterFromText);
    if (rawFilters == null) return fail(_filterShape);
    for (final raw in rawFilters) {
      final column = table.column('${raw['column']}');
      if (column != null && column.kind == ColumnKind.date) {
        return fail(
          '"${column.name}" is a date column. Limit dates with "from" and '
          '"to" (YYYY-MM-DD), not a filter.',
        );
      }
      if (column == null || column.kind != ColumnKind.text) {
        return fail(
          '"${raw['column']}" is not a text column in ${table.source}. Text '
          'columns: ${table.textColumns.map((c) => c.name).join(', ')}.',
        );
      }
      final op = switch (raw['op'] ?? 'is') {
        'is' || '=' || '==' => 'is',
        'is_not' || '!=' || 'not' => 'is_not',
        _ => null,
      };
      if (op == null) return fail(_filterShape);
      final values = <String>[];
      final listed = raw['values'] ?? raw['value'];
      for (final value in listed is List ? listed : [?listed]) {
        final known = _matchValue(table, column, '$value');
        if (known == null) {
          return fail(_unknownValue(table, column, '$value'));
        }
        values.add(known);
      }
      if (values.isEmpty) return fail('A filter needs at least one value.');
      filters.add(
        ColumnFilter.anyOf(column.name, values, exclude: op == 'is_not'),
      );
    }

    final conditions = <NumberCondition>[];
    final rawConditions = _items(arguments['conditions'], _conditionFromText);
    if (rawConditions == null) return fail(_conditionShape);
    for (final raw in rawConditions) {
      final column = '${raw['column']}';
      if (table.column(column)?.kind == ColumnKind.date) {
        return fail(
          '"$column" is a date column. Limit dates with "from" and "to" '
          '(YYYY-MM-DD), not a condition.',
        );
      }
      if (!_isNumber(table, column)) {
        return fail('"$column" is not a number column in ${table.source}.');
      }
      final comparison = Comparison.fromSymbol('${raw['op']}');
      if (comparison == null) {
        return fail(
          'A condition "op" must be one of '
          '${Comparison.values.map((c) => c.symbol).join(', ')}.',
        );
      }
      final value = raw['value'];
      final number = value is num ? value : num.tryParse('$value');
      if (number == null) return fail('A condition "value" must be a number.');
      conditions.add(NumberCondition(column, comparison, number));
    }

    final from = _date(arguments['from']);
    final to = _date(arguments['to']);
    if (_given(arguments['from']) && from == null ||
        _given(arguments['to']) && to == null) {
      return fail('"from" and "to" must be dates written YYYY-MM-DD.');
    }
    DateRange? range;
    if (from != null || to != null) {
      if (table.dateColumn == null) {
        return fail('${table.source} has no date column to limit by.');
      }
      final start = from ?? DateTime(0);
      final end = (to ?? DateTime(9999)).add(const Duration(days: 1));
      if (!start.isBefore(end)) return fail('"from" must not be after "to".');
      range = DateRange(start, end, _label(from, to));
    }

    return (
      request: (
        table,
        TableQuery(
          aggregate: aggregate,
          metric: measure,
          filters: filters,
          conditions: conditions,
          range: range,
          groupBy: groupBy,
          per: per,
        ),
      ),
      error: null,
    );
  }

  static const String _filterShape =
      'Each filter must look like {"column": "location", "op": "is", '
      '"values": ["Online"]}, with "op" "is" or "is_not".';

  static const String _conditionShape =
      'Each condition must look like {"column": "units_sold", "op": ">=", '
      '"value": 40}.';

  /// Whether the model filled in [raw], counting "" as left out.
  static bool _given(Object? raw) =>
      raw != null && !(raw is String && raw.trim().isEmpty);

  /// The items of a `filters` or `conditions` list in one spelling, or null
  /// if any item cannot be read, so nothing the model asked for is silently
  /// dropped. Models often write `field`, `operator` and `value`, or a
  /// string such as "location=Online"; both mean the same thing.
  static List<Map<String, dynamic>>? _items(
    Object? raw,
    Map<String, dynamic>? Function(String) fromText,
  ) {
    if (!_given(raw)) return const [];
    if (raw is! List) return null;
    final items = <Map<String, dynamic>>[];
    for (final item in raw) {
      final read = switch (item) {
        Map<String, dynamic>() => {
          'column': item['column'] ?? item['field'],
          'op': item['op'] ?? item['operator'],
          'values': item['values'],
          'value': item['value'],
        },
        String() => fromText(item),
        _ => null,
      };
      if (read == null || read['column'] == null) return null;
      items.add(read);
    }
    return items;
  }

  static final RegExp _filterText = RegExp(
    r'^\s*([\w ]+?)\s*(!=|==|=)\s*(.+)$',
  );

  /// "location=Online" or "product_line != Heritage".
  static Map<String, dynamic>? _filterFromText(String text) {
    final m = _filterText.firstMatch(text);
    if (m == null) return null;
    return {'column': m[1], 'op': m[2], 'values': m[3]!.trim()};
  }

  static final RegExp _conditionText = RegExp(
    r'^\s*(\w+)\s*(>=|<=|>|<)\s*(-?[\d.]+)\s*$',
  );

  /// "units_sold >= 40".
  static Map<String, dynamic>? _conditionFromText(String text) {
    final m = _conditionText.firstMatch(text);
    if (m == null) return null;
    return {'column': m[1], 'op': m[2], 'value': m[3]};
  }

  static bool _isNumber(CsvTable table, String name) =>
      table.column(name)?.kind == ColumnKind.number;

  /// `month` becomes [TableQuery.month]; anything else is a column name.
  static String? _grouping(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return raw == monthWord ? TableQuery.month : raw;
  }

  static String? _checkGrouping(CsvTable table, String grouping) {
    if (grouping == TableQuery.month) {
      return table.dateColumn == null
          ? '${table.source} has no date column to group by month.'
          : null;
    }
    return table.column(grouping)?.kind == ColumnKind.text
        ? null
        : '"$grouping" is not a text column in ${table.source}. Group by '
              '${[...table.textColumns.map((c) => c.name), monthWord].join(', ')}, '
              'or leave out "group_by" and "per" for one overall figure.';
  }

  /// The value as the table spells it, ignoring case, or null.
  static String? _matchValue(CsvTable table, CsvColumn column, String value) =>
      table
          .distinctValues(column)
          .where((v) => v.toLowerCase() == value.trim().toLowerCase())
          .firstOrNull;

  String _unknownValue(CsvTable table, CsvColumn column, String value) {
    final asked = value.trim().toLowerCase();
    final close = [
      for (final v in table.distinctValues(column))
        if (v.toLowerCase().contains(asked) || asked.contains(v.toLowerCase()))
          v,
    ];
    if (close.isNotEmpty) {
      return 'There is no ${column.name} called "$value". Did you mean '
          '${close.join(' or ')}? Ask the user if it is not clear.';
    }
    final all = table.distinctValues(column).toList()..sort();
    final listed = all.length <= maxListedValues
        ? all.join(', ')
        : '${all.take(5).join(', ')} and ${all.length - 5} more';
    return 'There is no ${column.name} called "$value". Values: $listed.';
  }

  String _coverage(CsvTable table) {
    final column = table.dateColumn;
    if (column == null) return '';
    final dates = [
      for (var r = 0; r < table.rowCount; r++) ?table.date(r, column),
    ]..sort();
    if (dates.isEmpty) return '';
    return '${table.source} covers ${_day(dates.first)} to '
        '${_day(dates.last)}.';
  }

  static final RegExp _isoDay = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static DateTime? _date(Object? raw) {
    if (raw is! String || !_isoDay.hasMatch(raw.trim())) return null;
    final d = DateTime.tryParse(raw.trim());
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static const List<String> _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];

  /// "January 2026", "Q1 2026" or "2026" when the dates are exactly that
  /// period, so the answer reads naturally; otherwise the dates themselves.
  static String _label(DateTime? from, DateTime? to) {
    if (from == null) return 'up to ${_day(to!)}';
    if (to == null) return 'from ${_day(from)}';
    final lastDay = to.add(const Duration(days: 1));
    if (from.day == 1 && lastDay.day == 1) {
      final months =
          (lastDay.year - from.year) * 12 + lastDay.month - from.month;
      if (months == 1) return '${_monthNames[from.month - 1]} ${from.year}';
      if (months == 3 && (from.month - 1) % 3 == 0) {
        return 'Q${(from.month - 1) ~/ 3 + 1} ${from.year}';
      }
      if (months == 12 && from.month == 1) return '${from.year}';
    }
    return '${_day(from)} to ${_day(to)}';
  }
}

/// What running a [CalculateTool] request produced: a result, or an error
/// the model can act on. [text] is what to send back as the tool result.
class CalculateOutcome {
  CalculateOutcome.success(this.call, QueryResult this.result)
    : text = result.toPromptBlock(),
      error = null;

  CalculateOutcome.error(this.call, String this.error)
    : text = error,
      result = null;

  /// What the model asked for.
  final ToolCall call;

  final QueryResult? result;
  final String? error;
  final String text;

  bool get succeeded => result != null;
}
