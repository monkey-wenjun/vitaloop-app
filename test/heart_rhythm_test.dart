import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/heart_rhythm_screen.dart';

void main() {
  testWidgets('心律全部记录默认收起，展开后不截断为最近 10 条', (tester) async {
    final now = DateTime.now();
    final records = [
      for (var i = 0; i < 12; i++)
        ArrhythmiaEntry(
          timestampMs: now.subtract(Duration(hours: i)).millisecondsSinceEpoch,
          resultType: i.isEven ? 1 : 2,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HeartRhythmScreen(records: records),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('共 12 次'), findsOneWidget);
    final expand = find.text('12 条 · 展开');
    await tester.dragUntilVisible(
      expand,
      find.byType(Scrollable),
      const Offset(0, -200),
    );
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    expect(find.textContaining('仅显示最近'), findsNothing);
    expect(find.text('正常窦性'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
