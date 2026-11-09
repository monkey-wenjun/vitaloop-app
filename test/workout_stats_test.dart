import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/workout_stats_screen.dart';

WorkoutSummary _workout(DateTime start, {double km = 5, int minutes = 30}) {
  final startMs = start.millisecondsSinceEpoch;
  return WorkoutSummary(
    id: 'w-$startMs',
    sport: 'running',
    source: 'watch',
    startMs: startMs,
    endMs: startMs + minutes * 60 * 1000,
    durationSec: minutes * 60,
    distanceM: km * 1000,
    calories: 300,
    avgHr: 145,
    maxHr: 168,
    steps: 6000,
    load: 80,
    synced: true,
  );
}

Widget _app(Widget child) =>
    MaterialApp(theme: buildTheme(Brightness.light), home: child);

void main() {
  testWidgets('运动统计同屏显示周/月/年并渲染月历', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.pumpWidget(_app(WorkoutStatsScreen(workouts: [_workout(today.add(const Duration(hours: 7)))])));
    await tester.pumpAndSettle();

    expect(find.text('本周'), findsOneWidget);
    expect(find.text('本月'), findsOneWidget);
    expect(find.text('本年'), findsOneWidget);
    expect(find.text('运动日历'), findsOneWidget);
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点日历里的日期显示当天汇总', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.pumpWidget(_app(WorkoutStatsScreen(workouts: [_workout(today.add(const Duration(hours: 7)), km: 8.4)])));
    await tester.pumpAndSettle();

    final cell = find.byKey(ValueKey('cal-${today.day}'));
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.textContaining('8.4 km'), findsWidgets);
    expect(find.textContaining('${today.month} 月 ${today.day} 日'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统计消耗包含基础代谢', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.pumpWidget(_app(WorkoutStatsScreen(
      workouts: [_workout(today.add(const Duration(hours: 7)))],
      bmrPerDay: 1600,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('11,500', findRichText: true), findsWidgets);
    expect(find.textContaining('含基础代谢'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
