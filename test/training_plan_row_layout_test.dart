import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/training_plan_screen.dart';

WorkoutSummary _workout() => WorkoutSummary(
  id: 'w-plan-row',
  sport: 'outdoor_run',
  source: 'watch',
  startMs: 0,
  endMs: 1930 * 1000,
  durationSec: 1930,
  distanceM: 5020,
  calories: 320,
  avgHr: 152,
  maxHr: 171,
  steps: 4200,
  load: 80,
  synced: true,
);

void main() {
  testWidgets('完成行的取消和未完成行的打卡贴在同一右边缘', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day - 1);
    const session = TrainingSession(SessionKind.tempo, km: 5);
    final plan = TrainingPlan(
      planId: 'plan_row_layout',
      name: '测试计划',
      goal: RaceGoal.tenK,
      raceDate: day.add(const Duration(days: 30)),
      startDate: day,
      basePaceSec: 330,
      longRunKm: 8,
      createdMs: 1234000,
      weeks: [
        TrainingWeek(1, day, [
          TrainingDay(day, const [session]),
        ]),
      ],
    );

    Widget line(CourseCompletion? completion) => PlanCourseLine(
      plan: plan,
      day: TrainingDay(day, const [session]),
      index: 0,
      completion: completion,
      canCheck: true,
      onToggle: (_, _, _) async {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  line(
                    CourseCompletion(
                      CourseCompletionStatus.auto,
                      workout: _workout(),
                    ),
                  ),
                  line(const CourseCompletion(CourseCompletionStatus.cancelled)),
                  line(null),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final cancel = tester.getRect(find.widgetWithText(TextButton, '取消'));
    final fill = tester.getRect(find.widgetWithText(TextButton, '打卡'));
    final makeUp = tester.getRect(find.widgetWithText(TextButton, '补卡'));

    expect(cancel.right, moreOrLessEquals(fill.right));
    expect(makeUp.right, moreOrLessEquals(fill.right));

    final description = tester.getSize(
      find.text(session.describe(plan.basePaceSec)).first,
    );
    expect(description.height, lessThan(30), reason: '完成行描述不应被挤到换行');
  });
}
