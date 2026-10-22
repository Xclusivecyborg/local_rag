import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/rag/calculate_tool.dart';
import 'package:local_rag/tables/csv_table.dart';

late CalculateTool calculator;

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
}
