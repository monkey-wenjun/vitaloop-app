import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/ui/screens/training_plan_screen.dart';

WorkoutSummary _run({
  required double meters,
  required int seconds,
  String sport = 'outdoor_run',
  DateTime? start,
}) => WorkoutSummary(
  id: 'w-$meters',
  sport: sport,
  source: 'watch',
  startMs: start?.millisecondsSinceEpoch ?? 0,
  endMs: (start?.millisecondsSinceEpoch ?? 0) + seconds * 1000,
  durationSec: seconds,
  distanceM: meters,
  calories: 0,
  avgHr: 0,
  maxHr: 0,
  steps: 0,
  load: 0,
  synced: true,
);

TrainingPlan _oneWeekPlan({
  RaceGoal goal = RaceGoal.tenK,
  int longRunKm = 10,
  required List<TrainingDay> days,
}) {
  final monday = DateTime(2026, 11, 2);
  return TrainingPlan(
    planId: 'plan_progress',
    name: '测试计划',
    goal: goal,
    raceDate: DateTime(2026, 12, 20),
    startDate: monday,
    basePaceSec: 330,
    longRunKm: longRunKm,
    createdMs: 1234000,
    weeks: [TrainingWeek(1, monday, days)],
  );
}

void main() {
  group('watchPlanPayload', () {
    test('7 天骨架、力量/跑步课类型和分段都按手表协议输出', () {
      final monday = DateTime(2026, 11, 2);
      final plan = TrainingPlan(
        planId: 'plan_test',
        name: '测试计划',
        goal: RaceGoal.tenK,
        raceDate: monday.add(const Duration(days: 56)),
        startDate: monday,
        basePaceSec: 330,
        longRunKm: 10,
        createdMs: 1234000,
        weeks: [
          TrainingWeek(1, monday, [
            TrainingDay(monday, const [
              TrainingSession(SessionKind.strength, strengthMinutes: 30),
            ]),
            TrainingDay(monday.add(const Duration(days: 1)), const [
              TrainingSession(SessionKind.easy, km: 5),
            ]),
            TrainingDay(monday.add(const Duration(days: 2)), const [
              TrainingSession(SessionKind.interval, km: 8, intervalBlocks: 6),
            ]),
            TrainingDay(monday.add(const Duration(days: 3)), const []),
            TrainingDay(monday.add(const Duration(days: 4)), const []),
            TrainingDay(monday.add(const Duration(days: 5)), const []),
            TrainingDay(monday.add(const Duration(days: 6)), const []),
          ]),
        ],
      );

      final payload = watchPlanPayload(plan, today: monday);
      final days = payload['days'] as List<dynamic>;
      expect(days, hasLength(7));
      expect(payload['punchSec'], 1234);
      expect(payload['currentWeekName'], '第1周');

      final strength =
          ((days[0] as Map<String, dynamic>)['courses'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(strength['courseType'], 5);
      expect(strength['durationSec'], 1800);
      expect(strength['segments'], isEmpty);

      final easy =
          ((days[1] as Map<String, dynamic>)['courses'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(easy['courseType'], 4);
      expect(easy['durationSec'], 5 * (330 * 1.22).round());
      final easySegments = (easy['segments'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(easySegments.first['actionId'], 'RD001');
      expect(easySegments.last['actionId'], 'RD005');

      final interval =
          ((days[2] as Map<String, dynamic>)['courses'] as List<dynamic>).single
              as Map<String, dynamic>;
      final intervalSegments = (interval['segments'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(intervalSegments, hasLength(14));
      expect(intervalSegments[1]['actionId'], 'RD002');
      expect(intervalSegments[2]['actionId'], 'RD003');
    });

    test('自适应配速和版本戳进入手表载荷', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          TrainingDay(monday, const [TrainingSession(SessionKind.easy, km: 5)]),
        ],
      ).copyWith(paceFactor: 1.03, punchSec: 8899);

      final payload = watchPlanPayload(plan, today: monday);
      final day =
          (payload['days'] as List<dynamic>).first as Map<String, dynamic>;
      final course =
          (day['courses'] as List<dynamic>).single as Map<String, dynamic>;

      expect(payload['punchSec'], 8899);
      expect(course['durationSec'], (5 * (330 * 1.22 * 1.03).round()));
    });
  });

  group('RunningBests', () {
    test('按距离窗挖出 5K/10K/半马/全马最好配速', () {
      final bests = RunningBests.mine([
        _run(meters: 5000, seconds: 1500),
        _run(meters: 10100, seconds: 3300),
        _run(meters: 21100, seconds: 7200),
        _run(meters: 42300, seconds: 15000),
      ]);

      expect(bests.runCount, 4);
      expect(bests.fiveKPace, 300);
      expect(bests.tenKPace, closeTo(327, 1));
      expect(bests.halfPace, closeTo(341, 1));
      expect(bests.fullPace, closeTo(355, 1));
      expect(bests.longestRunMeters, 42300);
      expect(bests.longestRunDurationSec, 15000);
      expect(bests.suggestGoal(), RaceGoal.full);
    });

    test('只有半马成绩时按 Riegel 外推全马配速', () {
      final bests = RunningBests.mine([_run(meters: 21100, seconds: 7200)]);
      final basis = bests.paceBasis(RaceGoal.full);

      expect(basis, isNotNull);
      expect(basis!.paceSecPerKm, inInclusiveRange(350, 360));
      expect(basis.source, contains('半马'));
      expect(basis.source, contains('外推'));
    });

    test('没有分段成绩时用最长跑步距离和用时外推', () {
      final bests = RunningBests.mine([_run(meters: 12000, seconds: 4200)]);
      final basis = bests.paceBasis(RaceGoal.half);

      expect(basis, isNotNull);
      expect(basis!.source, contains('历史最长跑步'));
      expect(basis.paceSecPerKm, greaterThan(350));
    });

    test('走路和力量训练不参与跑步成绩匹配', () {
      final bests = RunningBests.mine([
        _run(meters: 12000, seconds: 7000, sport: 'walking'),
        _run(meters: 5000, seconds: 3000, sport: 'strength'),
        _run(meters: 5000, seconds: 1500, sport: 'treadmill'),
      ]);

      expect(bests.runCount, 1);
      expect(bests.fiveKPace, 300);
    });

    test('最长 21.45km 自动匹配半马，不跳到全马', () {
      final bests = RunningBests.mine([
        _run(meters: 21450, seconds: 8374),
        _run(meters: 5000, seconds: 1800),
      ]);

      expect(bests.longestRunKm, closeTo(21.45, 0.001));
      expect(bests.suggestGoal(), RaceGoal.half);
    });
  });

  group('TrainingPlan', () {
    test('全马从本周一排到比赛日所在周，最后一周比赛', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.full,
        raceDate: DateTime(2027, 3, 21),
        basePaceSec: 355,
        longRunKm: 26,
        now: DateTime(2026, 11, 7),
      );

      expect(plan.startDate, DateTime(2026, 11, 2));
      expect(plan.weeks.length, 20);
      expect(plan.weeks.first.start, DateTime(2026, 11, 2));

      final last = plan.weeks.last;
      expect(last.days[6].sessions.single.kind, SessionKind.race);
      expect(last.days[6].sessions.single.km, 42);
      expect(last.days[5].sessions.single.kind, SessionKind.long);
      expect(last.days[5].sessions.single.km, RaceGoal.full.activationKm);
      expect(last.days[3].sessions.single.kind, SessionKind.interval);

      // 赛前第二周减量
      final taper = plan.weeks[plan.weeks.length - 2];
      expect(taper.days[5].sessions.single.km, 22);
    });

    test('每周周日休息、周六长距离，且长距离不超过项目峰值', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.half,
        raceDate: DateTime(2027, 2, 7),
        basePaceSec: 348,
        longRunKm: 15,
        now: DateTime(2026, 11, 7),
      );

      for (final week in plan.weeks.take(plan.weeks.length - 1)) {
        expect(week.days[6].sessions, isEmpty);
        expect(week.days[5].sessions.single.kind, SessionKind.long);
        expect(
          week.days[5].sessions.single.km,
          lessThanOrEqualTo(RaceGoal.half.maxLongRunKm),
        );
      }
      expect(plan.weeks.first.days[3].sessions.single.kind, SessionKind.tempo);
    });

    test('半马长距离从保守起点渐进，不会在周六突然顶到 21km', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.half,
        raceDate: DateTime(2027, 2, 7),
        basePaceSec: 348,
        longRunKm: 8,
        now: DateTime(2026, 11, 7),
      );

      final buildWeeks = plan.weeks
          .take(plan.weeks.length - 2)
          .toList(growable: false);
      expect(buildWeeks.first.longRunKm, 8);
      expect(
        buildWeeks.map((w) => w.longRunKm).reduce(mathMax),
        lessThanOrEqualTo(RaceGoal.half.peakLongRunKm),
      );
      for (var i = 1; i < buildWeeks.length; i++) {
        expect(
          buildWeeks[i].longRunKm - buildWeeks[i - 1].longRunKm,
          lessThanOrEqualTo(RaceGoal.half.longRunStepKm),
        );
      }
      // 21km 只出现在比赛日，不出现在训练周六。
      final race = plan.weeks.last.days
          .expand((d) => d.sessions)
          .singleWhere((s) => s.kind == SessionKind.race);
      expect(race.km, 21);
    });

    test('全马尊重首周 9km 起点，每周 +2km，峰值 32km，42km 只在比赛日', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.full,
        raceDate: DateTime(2027, 3, 21),
        basePaceSec: 355,
        longRunKm: 9,
        now: DateTime(2026, 11, 7),
      );

      final buildWeeks = plan.weeks
          .take(plan.weeks.length - 2)
          .toList(growable: false);
      expect(buildWeeks.first.longRunKm, 9);
      expect(
        buildWeeks.map((w) => w.longRunKm).reduce(mathMax),
        lessThanOrEqualTo(RaceGoal.full.peakLongRunKm),
      );
      for (var i = 1; i < buildWeeks.length; i++) {
        expect(
          buildWeeks[i].longRunKm - buildWeeks[i - 1].longRunKm,
          lessThanOrEqualTo(RaceGoal.full.longRunStepKm),
        );
      }
      final longRuns = plan.weeks
          .expand((w) => w.days)
          .expand((d) => d.sessions)
          .where((s) => s.kind == SessionKind.long)
          .map((s) => s.km);
      expect(longRuns, isNot(contains(42)));
      final race = plan.weeks.last.days
          .expand((d) => d.sessions)
          .singleWhere((s) => s.kind == SessionKind.race);
      expect(race.km, 42);
    });

    test('v1 旧计划把 21km 当首周起点时，加载后自动重排', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.half,
        raceDate: DateTime(2027, 2, 7),
        basePaceSec: 348,
        longRunKm: 8,
        now: DateTime(2026, 11, 7),
      );
      final json = plan.toJson();
      json['v'] = 1;
      for (final week in (json['weeks'] as List).take(3)) {
        final days = (week as Map<String, dynamic>)['days'] as List;
        final saturday = days[5] as Map<String, dynamic>;
        final longRun = (saturday['s'] as List).single as Map<String, dynamic>;
        longRun['km'] = 21;
      }

      final restored = TrainingPlan.tryParse(jsonEncode(json));

      expect(restored, isNotNull);
      expect(restored!.weeks.first.longRunKm, RaceGoal.half.startLongRunKm);
      expect(restored.toJson()['v'], 2);
    });

    test('比赛落在用户选择的周六，赛后周日休息', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.half,
        raceDate: DateTime(2027, 1, 30),
        basePaceSec: 348,
        longRunKm: 11,
        now: DateTime(2026, 11, 7),
      );

      final last = plan.weeks.last;
      expect(last.days[5].date, DateTime(2027, 1, 30));
      expect(last.days[5].sessions.single.kind, SessionKind.race);
      expect(last.days[6].sessions, isEmpty);
    });

    test('保存后 JSON 能完整还原', () {
      final plan = TrainingPlan.generate(
        goal: RaceGoal.full,
        raceDate: DateTime(2027, 4, 11),
        basePaceSec: 360,
        longRunKm: 24,
        now: DateTime(2026, 11, 7),
      );
      final restored = TrainingPlan.tryParse(jsonEncode(plan.toJson()));

      expect(restored, isNotNull);
      expect(restored!.goal, RaceGoal.full);
      expect(restored.weeks.length, plan.weeks.length);
      expect(restored.raceDate, plan.raceDate);
      expect(
        restored.weeks.last.days[6].sessions.single.kind,
        SessionKind.race,
      );
    });

    test('自适应字段能随计划保存和还原', () {
      final plan =
          TrainingPlan.generate(
            goal: RaceGoal.half,
            raceDate: DateTime(2027, 2, 7),
            basePaceSec: 348,
            longRunKm: 15,
            now: DateTime(2026, 11, 7),
          ).copyWith(
            paceFactor: 1.03,
            lastAdaptedDay: 20771,
            punchSec: 4567,
            adjustments: [
              PlanAdjustment(
                madeAt: DateTime(2026, 11, 7),
                reason: '测试调整',
                paceFactor: 1.03,
                longRunKm: 14,
              ),
            ],
          );
      final restored = TrainingPlan.tryParse(jsonEncode(plan.toJson()));

      expect(restored, isNotNull);
      expect(restored!.paceFactor, 1.03);
      expect(restored.lastAdaptedDay, 20771);
      expect(restored.punchSec, 4567);
      expect(restored.adjustments.single.reason, '测试调整');
    });
  });

  group('课程完成记录', () {
    test('同日跑步记录按 0.6–1.5 倍距离自动匹配，一条记录只顶一节课', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          TrainingDay(monday, const [
            TrainingSession(SessionKind.easy, km: 5),
            TrainingSession(SessionKind.easy, km: 5),
          ]),
        ],
      );
      final progress = buildPlanProgress(
        plan: plan,
        workouts: [
          _run(
            meters: 5200,
            seconds: 1700,
            start: monday.add(const Duration(hours: 7)),
          ),
        ],
        manual: const {},
        now: DateTime(2026, 11, 7),
      );

      expect(progress.at(monday, 0)?.status, CourseCompletionStatus.auto);
      expect(progress.at(monday, 1), isNull);
      expect(progress.doneCount, 1);
      expect(progress.totalCount, 2);
    });

    test('距离超出容差的记录不匹配，力量课只能手动打卡', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          TrainingDay(monday, const [
            TrainingSession(SessionKind.easy, km: 5),
            TrainingSession(SessionKind.strength, strengthMinutes: 30),
          ]),
        ],
      );
      final progress = buildPlanProgress(
        plan: plan,
        workouts: [
          _run(
            meters: 8000,
            seconds: 2800,
            start: monday.add(const Duration(hours: 7)),
          ),
        ],
        manual: {courseCompletionKey(plan.planId, monday, 1): 2},
        now: DateTime(2026, 11, 7),
      );

      expect(progress.at(monday, 0), isNull);
      expect(progress.at(monday, 1)?.status, CourseCompletionStatus.manual);
      expect(progress.doneCount, 1);
    });

    test('手动取消后即使有匹配运动也不反弹', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          TrainingDay(monday, const [TrainingSession(SessionKind.easy, km: 5)]),
        ],
      );
      final progress = buildPlanProgress(
        plan: plan,
        workouts: [
          _run(
            meters: 5000,
            seconds: 1800,
            start: monday.add(const Duration(hours: 7)),
          ),
        ],
        manual: {courseCompletionKey(plan.planId, monday, 0): 0},
        now: DateTime(2026, 11, 7),
      );

      expect(progress.at(monday, 0)?.status, CourseCompletionStatus.cancelled);
      expect(progress.doneCount, 0);
    });
  });

  group('训练计划自适应', () {
    test('过去跑步课持续偏快时收紧配速 2%', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          for (var i = 0; i < 3; i++)
            TrainingDay(monday.add(Duration(days: i)), const [
              TrainingSession(SessionKind.easy, km: 5),
            ]),
        ],
      );
      final workouts = [
        for (var i = 0; i < 3; i++)
          _run(
            meters: 5000,
            seconds: 1600,
            start: monday.add(Duration(days: i, hours: 7)),
          ),
      ];
      final adapted = adaptTrainingPlan(
        plan: plan,
        workouts: workouts,
        hrv: const [],
        manual: const {},
        now: DateTime(2026, 11, 7),
      );

      expect(adapted.paceFactor, closeTo(0.98, 0.0001));
      expect(adapted.notes.single, contains('收紧'));
    });

    test('过去三节课只完成一节时放松配速 3%', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        days: [
          for (var i = 0; i < 3; i++)
            TrainingDay(monday.add(Duration(days: i)), const [
              TrainingSession(SessionKind.easy, km: 5),
            ]),
        ],
      );
      final adapted = adaptTrainingPlan(
        plan: plan,
        workouts: [
          _run(
            meters: 5000,
            seconds: 1800,
            start: monday.add(const Duration(days: 2, hours: 7)),
          ),
        ],
        hrv: const [],
        manual: const {},
        now: DateTime(2026, 11, 7),
      );

      expect(adapted.paceFactor, closeTo(1.03, 0.0001));
      expect(adapted.notes.single, contains('完成率'));
    });

    test('连续两晚 HRV 低于基线 90% 时长距离回撤 1km', () {
      final monday = DateTime(2026, 11, 2);
      final plan = _oneWeekPlan(
        goal: RaceGoal.half,
        longRunKm: 15,
        days: [
          TrainingDay(monday, const [TrainingSession(SessionKind.easy, km: 5)]),
        ],
      );
      final adapted = adaptTrainingPlan(
        plan: plan,
        workouts: const [],
        hrv: [
          for (var i = 0; i < 7; i++)
            DailyPoint(
              dateEpochDay: _epochDayForTest(DateTime(2026, 11, 1 - i)),
              value: i < 2 ? 80 : 100,
            ),
        ],
        manual: const {},
        now: DateTime(2026, 11, 7),
      );

      expect(adapted.longRunKm, 14);
      expect(adapted.notes.single, contains('HRV'));
    });

    test('自适应只回撤未来长距离，历史周保持原样', () {
      final monday = DateTime(2026, 11, 2);
      final nextMonday = monday.add(const Duration(days: 7));
      final plan = TrainingPlan(
        planId: 'plan_adapt',
        name: '测试计划',
        goal: RaceGoal.tenK,
        raceDate: DateTime(2026, 12, 20),
        startDate: monday,
        basePaceSec: 330,
        longRunKm: 15,
        createdMs: 1234000,
        weeks: [
          TrainingWeek(1, monday, [
            TrainingDay(monday, const [
              TrainingSession(SessionKind.long, km: 15),
            ]),
          ]),
          TrainingWeek(2, nextMonday, [
            TrainingDay(nextMonday, const [
              TrainingSession(SessionKind.long, km: 15),
            ]),
          ]),
        ],
      );
      final updated = plan.applyAdaptation(
        const PlanAdaptation(paceFactor: 1.03, longRunKm: 14, notes: ['测试回撤']),
        now: DateTime(2026, 11, 7),
      );

      expect(updated.weeks[0].days[0].sessions.single.km, 15);
      expect(updated.weeks[1].days[0].sessions.single.km, 14);
      expect(updated.paceFactor, 1.03);
      expect(updated.adjustments.single.reason, '测试回撤');
    });

    test('自适应不抬高比赛周的激活跑', () {
      final monday = DateTime(2026, 11, 2);
      final plan = TrainingPlan(
        planId: 'plan_race_week',
        name: '半马测试',
        goal: RaceGoal.half,
        raceDate: DateTime(2026, 11, 29),
        startDate: monday,
        basePaceSec: 360,
        longRunKm: 15,
        createdMs: 1234000,
        weeks: [
          TrainingWeek(1, monday, [
            TrainingDay(monday, const [
              TrainingSession(SessionKind.long, km: 15),
            ]),
          ]),
          TrainingWeek(2, monday.add(const Duration(days: 7)), [
            TrainingDay(monday.add(const Duration(days: 12)), const [
              TrainingSession(SessionKind.long, km: 15),
            ]),
          ]),
          TrainingWeek(3, monday.add(const Duration(days: 14)), [
            TrainingDay(monday.add(const Duration(days: 19)), const [
              TrainingSession(SessionKind.long, km: 6),
            ]),
            TrainingDay(monday.add(const Duration(days: 20)), const [
              TrainingSession(SessionKind.race, km: 21),
            ]),
          ]),
        ],
      );
      final updated = plan.applyAdaptation(
        const PlanAdaptation(paceFactor: 1.03, longRunKm: 9, notes: ['测试回撤']),
        now: DateTime(2026, 11, 9),
      );

      expect(updated.weeks[0].days[0].sessions.single.km, 15);
      expect(updated.weeks[1].days[0].sessions.single.km, 10);
      expect(updated.weeks[2].days[0].sessions.single.km, 6);
    });
  });
}

int mathMax(int a, int b) => a > b ? a : b;

int _epochDayForTest(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;
