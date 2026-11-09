import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/activity_rings_screen.dart';

DailyRing _ring(int day) => DailyRing(
  dateEpochDay: day,
  dayEndMs: day * Duration.millisecondsPerDay,
  stepGoal: 10000,
  stepUser: 8000,
  stepState: 0,
  calorieGoalMilli: 500000,
  calorieUserMilli: 250000,
  calorieState: 0,
  durationGoalMin: 60,
  durationUserMin: 30,
  durationState: 0,
  activeGoalHours: 3,
  activeUserHours: 4,
  activeState: 1,
);

Widget _app(Widget child) =>
    MaterialApp(theme: buildTheme(Brightness.light), home: child);

void main() {
  testWidgets('活动三环有数据时渲染热量、目标和明细', (tester) async {
    final today = DateTime.now();
    final day = today.difference(DateTime(1970)).inDays;
    await tester.pumpWidget(
      _app(ActivityRingsScreen(initialRings: [_ring(day)])),
    );
    await tester.pumpAndSettle();

    expect(find.text('250'), findsOneWidget);
    expect(find.textContaining('活动热量'), findsWidgets);
    expect(find.textContaining('目标 500'), findsOneWidget);
    expect(find.text('本周'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有活动数据时显示空态而不是空白页', (tester) async {
    await tester.pumpWidget(_app(const ActivityRingsScreen(initialRings: [])));
    await tester.pumpAndSettle();

    expect(find.text('还没有活动三环数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
