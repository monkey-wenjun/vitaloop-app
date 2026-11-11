import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/components.dart';
import 'package:vitaloop/util/range_buckets.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

void main() {
  testWidgets('trend charts render regular, sparse and duplicate samples', (
    tester,
  ) async {
    final buckets = [
      RangeBucket(start: DateTime(2026, 11, 1), value: 62, label: '11/1'),
      RangeBucket(start: DateTime(2026, 11, 2), value: 0, label: '11/2'),
      RangeBucket(start: DateTime(2026, 11, 3), value: 88, label: '11/3'),
      RangeBucket(start: DateTime(2026, 11, 4), value: 70, label: '11/4'),
    ];
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            VRangeLine(
              buckets: buckets,
              color: const Color(0xFFE05555),
              height: 90,
            ),
            HeartRateCurve(
              points: const [
                Offset(1, 60),
                Offset(2, 61),
                Offset(2, 62),
                Offset(3, 90),
              ],
              height: 90,
            ),
            const HeartRateCurve(points: [Offset(5, 72)], height: 90),
            MultiLineChart(
              series: const [
                MultiLineSeries(
                  points: [Offset(1, 120), Offset(2, 118)],
                  color: Color(0xFFE05555),
                ),
                MultiLineSeries(
                  points: [Offset(1, 80), Offset(2, 78)],
                  color: Color(0xFF4477DD),
                ),
              ],
              height: 90,
            ),
            const HeartRateCurve(points: [], height: 90),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
