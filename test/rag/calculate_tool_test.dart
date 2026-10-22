import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/rag/calculate_tool.dart';
import 'package:local_rag/tables/csv_table.dart';
import 'package:rag_blocks/rag_blocks.dart' show ToolCall;

/// Ground truth computed with awk from sample_kb/sales_q1_2026.csv.
const int kQ1Revenue = 204740500;
const int kJanuaryRevenue = 71882000;

late CalculateTool calculator;

CalculateOutcome calculate(Map<String, dynamic> arguments) =>
    calculator.run(ToolCall('calculate', arguments));

void main() {
  setUpAll(() {
    calculator = CalculateTool([
      CsvTable.parse(
        File('sample_kb/sales_q1_2026.csv').readAsStringSync(),
        source: 'sales_q1_2026.csv',
      ),
    ]);
  });

  group('the definition', () {
    test('lists the tables and columns the model may use', () {
      final json = calculator.definition.toJson();
      final function = json['function'] as Map;
      final properties = (function['parameters'] as Map)['properties'] as Map;

      expect(function['name'], 'calculate');
      expect((properties['table'] as Map)['enum'], ['sales_q1_2026.csv']);
      expect(
        (properties['measure'] as Map)['enum'],
        containsAll(['revenue_ngn', 'units_sold']),
      );
      expect((properties['group_by'] as Map)['enum'], [
        'location',
        'product_line',
        'month',
      ]);
    });

    test('the table description gives values and dates', () {
      final description = calculator.describeTables();
      expect(description, contains('sales_q1_2026.csv: 240 rows'));
      expect(description, contains('date, 2026-01-05 to 2026-03-23'));
      expect(
        description,
        contains(
          'Ikeja City Mall, Online, Port Harcourt, Victoria Island, '
          'Wuse 2 Abuja',
        ),
      );
    });

    test('a column with many values is described by a sample', () {
      final names = [for (var i = 0; i < 40; i++) 'customer $i'];
      final big = CalculateTool([
        CsvTable.parse(
          'name,spend\n${names.map((n) => '$n,1').join('\n')}\n',
          source: 'customers.csv',
        ),
      ]);
      expect(big.describeTables(), contains('40 different values, e.g.'));
    });
  });

  group('calls that run', () {
    test('a quarter is labelled as one', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'sum',
        'measure': 'revenue_ngn',
        'from': '2026-01-01',
        'to': '2026-03-31',
      });
      expect(outcome.result!.value, kQ1Revenue);
      expect(outcome.text, contains('in Q1 2026'));
    });

    test('a month is labelled as one', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'sum',
        'measure': 'revenue_ngn',
        'from': '2026-01-01',
        'to': '2026-01-31',
      });
      expect(outcome.result!.value, kJanuaryRevenue);
      expect(outcome.text, contains('in January 2026'));
    });

    test('excluding a value, spelled in any case', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'sum',
        'measure': 'revenue_ngn',
        'filters': [
          {
            'column': 'product_line',
            'op': 'is_not',
            'values': ['heritage'],
          },
        ],
      });
      expect(outcome.result!.value, 179567000);
      expect(outcome.text, contains('product_line not Heritage'));
    });

    test('which location had the most revenue', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'max',
        'measure': 'revenue_ngn',
        'per': 'location',
      });
      expect(outcome.result!.value, 67647000);
      expect(outcome.text, contains('Belongs to: location=Victoria Island'));
    });

    test('average per month', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'average',
        'measure': 'revenue_ngn',
        'per': 'month',
      });
      expect(outcome.result!.value, closeTo(kQ1Revenue / 3, 0.01));
    });

    test('a number condition', () {
      final outcome = calculate({
        'table': 'sales_q1_2026.csv',
        'aggregate': 'sum',
        'measure': 'revenue_ngn',
        'conditions': [
          {'column': 'units_sold', 'op': '>=', 'value': 40},
        ],
      });
      expect(outcome.result!.value, 49616500);
    });
  });

  group('calls that cannot run say why', () {
    String errorFor(Map<String, dynamic> arguments) =>
        calculate({'table': 'sales_q1_2026.csv', ...arguments}).error!;

    test('part of a name suggests the whole one', () {
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'filters': [
            {
              'column': 'location',
              'op': 'is',
              'values': ['Ikeja'],
            },
          ],
        }),
        contains('Did you mean Ikeja City Mall?'),
      );
    });

    test('a name it does not have lists the ones it does', () {
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'filters': [
            {
              'column': 'location',
              'op': 'is',
              'values': ['Lekki'],
            },
          ],
        }),
        contains('Values: Ikeja City Mall, Online'),
      );
    });

    test('dates with no rows say what the table covers', () {
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'from': '2026-04-01',
          'to': '2026-04-30',
        }),
        allOf(
          contains('No rows match'),
          contains('covers 2026-01-05 to 2026-03-23'),
        ),
      );
    });

    test('missing or wrong arguments', () {
      expect(errorFor({'aggregate': 'sum'}), contains('Say which "measure"'));
      expect(
        errorFor({'aggregate': 'sum', 'measure': 'location'}),
        contains('not a number column'),
      );
      expect(
        errorFor({'aggregate': 'total', 'measure': 'revenue_ngn'}),
        contains('"aggregate" must be one of'),
      );
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'from': 'January',
        }),
        contains('YYYY-MM-DD'),
      );
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'per': 'month',
          'group_by': 'location',
        }),
        contains('not both'),
      );
      expect(
        calculate({'table': 'other.csv', 'aggregate': 'count'}).error,
        contains('Tables: sales_q1_2026.csv'),
      );
    });

    test('the mistakes a model makes say how to fix them', () {
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'group_by': 'total',
        }),
        contains('leave out "group_by" and "per" for one overall figure'),
      );
      expect(
        errorFor({
          'aggregate': 'sum',
          'measure': 'revenue_ngn',
          'filters': [
            {
              'column': 'week_starting',
              'op': 'is',
              'values': ['2026-01'],
            },
          ],
        }),
        contains('Limit dates with "from" and "to"'),
      );
    });

    test('an unknown tool is refused', () {
      final outcome = calculator.run(const ToolCall('search', {}));
      expect(outcome.succeeded, isFalse);
    });
  });
}
