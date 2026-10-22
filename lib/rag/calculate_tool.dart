import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart' show Tool;

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
/// ```
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
          'description': 'Give one figure per group, largest first.',
        },
        'per': {
          'type': 'string',
          'enum': groupings,
          'description':
              'Total per group first, then aggregate those totals: '
              '"average revenue per month" is aggregate average, per month. '
              '"Which location sold the most" is aggregate max, per location.',
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

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
