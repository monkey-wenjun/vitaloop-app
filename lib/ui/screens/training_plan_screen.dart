import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

const _planSettingKey = 'training_plan_v1';
const _planManualSettingKey = 'training_plan_manual_completion_v1';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dateKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

int _epochDay(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

bool _legacyPlanJson(String raw) {
  try {
    final json = jsonDecode(raw);
    return json is Map && ((json['v'] as num?)?.toInt() ?? 1) < 2;
  } catch (_) {
    return false;
  }
}

String paceLabelOf(int secPerKm) =>
    "${secPerKm ~/ 60}'${(secPerKm % 60).toString().padLeft(2, '0')}\"";

/// 目标赛事。长距离上限/基准按项目常规备赛口径：
/// 半马峰值 21km、全马峰值 42km，赛前第二周减量，比赛周只保留激活跑。
enum RaceGoal {
  fiveK(5.0, '5K', '5k', 6, 10, 3, 5, 2, 6),
  tenK(10.0, '10K', '10k', 8, 15, 4, 7, 3, 8),
  half(21.0975, '半马', 'hm', 15, 21, 6, 10, 5, 12),
  full(42.195, '全马', 'fm', 26, 42, 10, 18, 8, 16);

  const RaceGoal(
    this.km,
    this.label,
    this.idPrefix,
    this.defaultLongRunKm,
    this.maxLongRunKm,
    this.activationKm,
    this.taperFloorKm,
    this.taperStepKm,
    this.defaultWeeks,
  );

  final double km;
  final String label;
  final String idPrefix;
  final int defaultLongRunKm;
  final int maxLongRunKm;
  final int activationKm;
  final int taperFloorKm;
  final int taperStepKm;
  final int defaultWeeks;

  /// 长距离每周递增幅度：全马需要更快堆到 30km+，其余项目每周 +1km。
  int get longRunStepKm => this == RaceGoal.full ? 2 : 1;

  /// 首周周六长距离的安全起点。历史最长距离只说明「能跑完」，不能直接
  /// 当作每周训练量；否则会出现周中 5–6km、周六 21km 的断崖。
  int get startLongRunKm => switch (this) {
    RaceGoal.fiveK => 4,
    RaceGoal.tenK => 6,
    RaceGoal.half => 8,
    RaceGoal.full => 12,
  };

  /// 训练期长距离峰值。比赛距离本身只在比赛日跑，不在训练中反复顶满。
  int get peakLongRunKm => switch (this) {
    RaceGoal.fiveK => 7,
    RaceGoal.tenK => 12,
    RaceGoal.half => 18,
    RaceGoal.full => 32,
  };

  static RaceGoal fromName(String? name) =>
      values.firstWhere((g) => g.name == name, orElse: () => RaceGoal.half);
}

class PaceBasis {
  const PaceBasis(this.paceSecPerKm, this.source);

  final int paceSecPerKm;
  final String source;
}

/// 从历史跑步记录挖掘成绩。距离窗与旧版一致：
/// 全马 40–44km、半马 20–22km、10km 9.5–10.5km、5km 4.8–5.3km。
class RunningBests {
  const RunningBests({
    this.fiveKPace,
    this.tenKPace,
    this.halfPace,
    this.fullPace,
    this.longestRunMeters,
    this.longestRunDurationSec,
    this.longestRunPaceSec,
    this.runCount = 0,
  });

  final int? fiveKPace;
  final int? tenKPace;
  final int? halfPace;
  final int? fullPace;
  final double? longestRunMeters;
  final int? longestRunDurationSec;
  final int? longestRunPaceSec;
  final int runCount;

  double? get longestRunKm {
    final meters = longestRunMeters;
    if (meters == null || meters <= 0) return null;
    return meters / 1000.0;
  }

  bool get hasLongestRun =>
      (longestRunMeters ?? 0) > 0 && (longestRunPaceSec ?? 0) > 0;

  /// 没有历史成绩时返回 null，界面会提示先手动选配速。
  PaceBasis? paceBasis(RaceGoal goal) {
    final same = switch (goal) {
      RaceGoal.fiveK => fiveKPace,
      RaceGoal.tenK => tenKPace,
      RaceGoal.half => halfPace,
      RaceGoal.full => fullPace,
    };
    if (same != null) return PaceBasis(same, '你的${goal.label}最好成绩');

    final (fromKm, fromPace, source) = switch ((
      halfPace,
      tenKPace,
      fiveKPace,
    )) {
      (final half?, _, _) => (21.0975, half, '半马最好成绩'),
      (_, final ten?, _) => (10.0, ten, '10 公里最好成绩'),
      (_, _, final five?) => (5.0, five, '5 公里最好成绩'),
      _ when hasLongestRun => (
        longestRunKm!,
        longestRunPaceSec!,
        '历史最长跑步 ${longestRunKm!.toStringAsFixed(1)}km',
      ),
      _ => (0.0, 0, ''),
    };
    if (fromKm <= 0 || fromPace <= 0) return null;
    // Riegel：T2 = T1 × (D2/D1)^1.06，换算成配速就是 × (D2/D1)^0.06。
    final pace = (fromPace * math.pow(goal.km / fromKm, 0.06)).round();
    return PaceBasis(pace, '$source外推');
  }

  RaceGoal suggestGoal() {
    final km = longestRunKm ?? 0;
    if (km >= 32) return RaceGoal.full;
    if (km >= 17) return RaceGoal.half;
    if (km >= 8) return RaceGoal.tenK;
    return RaceGoal.fiveK;
  }

  static RunningBests mine(List<WorkoutSummary> workouts) {
    final runs = <WorkoutSummary>[];
    WorkoutSummary? longest;
    for (final w in workouts) {
      if (!_isRun(w) || w.durationSec <= 0) continue;
      runs.add(w);
      if (w.distanceM > 0 &&
          (longest == null || w.distanceM > longest.distanceM)) {
        longest = w;
      }
    }
    return RunningBests(
      fiveKPace: _bestPace(runs, 4800, 5300),
      tenKPace: _bestPace(runs, 9500, 10500),
      halfPace: _bestPace(runs, 20000, 22000),
      fullPace: _bestPace(runs, 40000, 44000),
      longestRunMeters: longest?.distanceM,
      longestRunDurationSec: longest?.durationSec,
      longestRunPaceSec: longest == null
          ? null
          : (longest.durationSec * 1000 / longest.distanceM).round(),
      runCount: runs.length,
    );
  }

  static bool _isRun(WorkoutSummary w) {
    final s = w.sport.toLowerCase();
    return s.contains('run') ||
        s == 'treadmill' ||
        s.contains('跑步') ||
        s.contains('慢跑');
  }

  static int? _bestPace(
    List<WorkoutSummary> runs,
    double minMeters,
    double maxMeters,
  ) {
    double best = double.infinity;
    for (final w in runs) {
      if (w.distanceM < minMeters ||
          w.distanceM > maxMeters ||
          w.durationSec <= 0) {
        continue;
      }
      final pace = w.durationSec * 1000 / w.distanceM;
      if (pace < best) best = pace;
    }
    return best.isFinite ? best.round() : null;
  }
}

enum SessionKind {
  easy(1.22, '轻松跑'),
  long(1.12, '长距离'),
  tempo(1.02, '节奏跑'),
  interval(0.93, '间歇跑'),
  strength(0.0, '力量训练'),
  race(1.0, '比赛日');

  const SessionKind(this.paceFactor, this.label);

  final double paceFactor;
  final String label;

  static SessionKind fromName(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => SessionKind.easy);
}

class TrainingSession {
  const TrainingSession(
    this.kind, {
    this.km = 0,
    this.strengthMinutes = 0,
    this.intervalBlocks = 0,
  });

  final SessionKind kind;
  final int km;
  final int strengthMinutes;
  final int intervalBlocks;

  int targetPaceSec(int basePaceSec, {double paceFactor = 1.0}) =>
      (basePaceSec * kind.paceFactor * paceFactor).round();

  String describe(int basePaceSec, {double paceFactor = 1.0}) => switch (kind) {
    SessionKind.strength => '力量 $strengthMinutes 分钟',
    SessionKind.race => '比赛 ${km.toStringAsFixed(1)} km',
    _ when intervalBlocks > 1 =>
      '${kind.label} ${km}km · ${paceLabelOf(targetPaceSec(basePaceSec, paceFactor: paceFactor))} · $intervalBlocks 组',
    _ =>
      '${kind.label} ${km}km · ${paceLabelOf(targetPaceSec(basePaceSec, paceFactor: paceFactor))}',
  };

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'km': km,
    'm': strengthMinutes,
    'b': intervalBlocks,
  };

  static TrainingSession fromJson(Map<String, dynamic> json) => TrainingSession(
    SessionKind.fromName(json['k'] as String?),
    km: (json['km'] as num?)?.toInt() ?? 0,
    strengthMinutes: (json['m'] as num?)?.toInt() ?? 0,
    intervalBlocks: (json['b'] as num?)?.toInt() ?? 0,
  );
}

class TrainingDay {
  const TrainingDay(this.date, this.sessions);

  final DateTime date;
  final List<TrainingSession> sessions;

  Map<String, dynamic> toJson() => {
    'd': _dateKey(date),
    's': sessions.map((s) => s.toJson()).toList(),
  };

  static TrainingDay fromJson(Map<String, dynamic> json) =>
      TrainingDay(DateTime.parse(json['d'] as String), [
        for (final s in (json['s'] as List? ?? const []))
          TrainingSession.fromJson(Map<String, dynamic>.from(s as Map)),
      ]);
}

class TrainingWeek {
  const TrainingWeek(this.weekNum, this.start, this.days);

  final int weekNum;
  final DateTime start;
  final List<TrainingDay> days;

  int get totalRunKm => days
      .expand((d) => d.sessions)
      .where((s) => s.kind != SessionKind.strength)
      .fold(0.0, (sum, s) => sum + s.km)
      .round();

  int get longRunKm {
    final longs = days
        .expand((d) => d.sessions)
        .where((s) => s.kind == SessionKind.long || s.kind == SessionKind.race)
        .map((s) => s.km);
    return longs.isEmpty ? 0 : longs.reduce(math.max);
  }

  Map<String, dynamic> toJson() => {
    'n': weekNum,
    'start': _dateKey(start),
    'days': days.map((d) => d.toJson()).toList(),
  };

  static TrainingWeek fromJson(Map<String, dynamic> json) => TrainingWeek(
    (json['n'] as num).toInt(),
    DateTime.parse(json['start'] as String),
    [
      for (final d in (json['days'] as List? ?? const []))
        TrainingDay.fromJson(Map<String, dynamic>.from(d as Map)),
    ],
  );
}

class TrainingPlan {
  const TrainingPlan({
    required this.planId,
    required this.name,
    required this.goal,
    required this.raceDate,
    required this.startDate,
    required this.basePaceSec,
    required this.longRunKm,
    required this.createdMs,
    required this.weeks,
    this.paceFactor = 1.0,
    this.lastAdaptedDay = 0,
    this.punchSec = 0,
    this.adjustments = const [],
  });

  final String planId;
  final String name;
  final RaceGoal goal;
  final DateTime raceDate;
  final DateTime startDate;
  final int basePaceSec;
  final int longRunKm;
  final int createdMs;
  final List<TrainingWeek> weeks;

  /// 自适应累计配速因子，>1 表示放慢。
  final double paceFactor;

  /// 最近一次自适应评估日期（epoch day）：一天最多评估一次。
  final int lastAdaptedDay;

  /// 手表计划版本戳；内容不变时必须保持稳定。
  final int punchSec;
  final List<PlanAdjustment> adjustments;

  int get daysLeft =>
      _dateOnly(raceDate).difference(_dateOnly(DateTime.now())).inDays;

  TrainingWeek? get currentWeek {
    if (weeks.isEmpty) return null;
    final today = _dateOnly(DateTime.now());
    for (final week in weeks.reversed) {
      if (!week.start.isAfter(today)) return week;
    }
    return weeks.first;
  }

  /// 周期由比赛日期决定：从本周一排到比赛日所在那周。
  static TrainingPlan generate({
    required RaceGoal goal,
    required DateTime raceDate,
    required int basePaceSec,
    required int longRunKm,
    double paceFactor = 1.0,
    int lastAdaptedDay = 0,
    int punchSec = 0,
    List<PlanAdjustment> adjustments = const [],
    String? planId,
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final firstMonday = today.subtract(Duration(days: today.weekday - 1));
    final race = _dateOnly(raceDate);
    final raceMonday = race.subtract(Duration(days: race.weekday - 1));
    var totalWeeks = raceMonday.difference(firstMonday).inDays ~/ 7 + 1;
    if (totalWeeks < 1) totalWeeks = 1;
    final weeks = <TrainingWeek>[];
    final raceDayIndex = race.weekday - 1;
    for (var idx = 0; idx < totalWeeks; idx++) {
      final start = firstMonday.add(Duration(days: idx * 7));
      weeks.add(
        _buildWeek(goal, idx, totalWeeks, start, longRunKm, raceDayIndex),
      );
    }
    return TrainingPlan(
      planId:
          planId ??
          '${goal.idPrefix}_${firstMonday.millisecondsSinceEpoch ~/ 1000}_r${race.millisecondsSinceEpoch ~/ 1000}',
      name: '${goal.label}备战 ${race.month}.${race.day}',
      goal: goal,
      raceDate: race,
      startDate: firstMonday,
      basePaceSec: basePaceSec,
      longRunKm: longRunKm,
      createdMs: DateTime.now().millisecondsSinceEpoch,
      weeks: weeks,
      paceFactor: paceFactor,
      lastAdaptedDay: lastAdaptedDay,
      punchSec: punchSec,
      adjustments: adjustments,
    );
  }

  static TrainingWeek _buildWeek(
    RaceGoal goal,
    int weekIdx,
    int totalWeeks,
    DateTime start,
    int longRunBase,
    int raceDayIndex,
  ) {
    final days = <TrainingDay>[];
    for (var dow = 0; dow < 7; dow++) {
      days.add(
        TrainingDay(
          start.add(Duration(days: dow)),
          _courses(goal, weekIdx, totalWeeks, dow, longRunBase, raceDayIndex),
        ),
      );
    }
    return TrainingWeek(weekIdx + 1, start, days);
  }

  /// 非比赛周周日休息、周六长距离、周四固定质量课；比赛周严格落在所选
  /// 比赛日，比赛日之后全部休息。
  /// 单周 一力/二跑/三力/四质量/五跑，双周 一跑/二力/三跑/四质量/五力。
  static List<TrainingSession> _courses(
    RaceGoal goal,
    int weekIdx,
    int totalWeeks,
    int dow,
    int longRunBase,
    int raceDayIndex,
  ) {
    final isRaceWeek = weekIdx == totalWeeks - 1;
    if (isRaceWeek && dow == raceDayIndex) {
      return [TrainingSession(SessionKind.race, km: goal.km.round())];
    }
    if (isRaceWeek && dow > raceDayIndex) return const [];
    final oddWeek = weekIdx % 2 == 0;
    final dailyKm = goal == RaceGoal.full ? 8 : 5;
    final buildCap = goal == RaceGoal.full ? 4 : 2;
    final tempoKm = weekIdx == 0 ? dailyKm : (goal == RaceGoal.full ? 12 : 8);
    final volumeKm = dailyKm + 1 + math.min(weekIdx, buildCap).toInt();
    return switch (dow) {
      0 => oddWeek ? [_strength()] : [_run(SessionKind.easy, dailyKm)],
      1 => oddWeek ? [_run(SessionKind.easy, volumeKm)] : [_strength()],
      2 => oddWeek ? [_strength()] : [_run(SessionKind.easy, volumeKm)],
      3 =>
        isRaceWeek
            ? [_run(SessionKind.interval, dailyKm + 1, blocks: 3)]
            : [_run(SessionKind.tempo, tempoKm)],
      4 =>
        isRaceWeek
            ? const []
            : oddWeek
            ? [_run(SessionKind.easy, dailyKm)]
            : [_strength()],
      5 => [_longRun(goal, weekIdx, totalWeeks, longRunBase)],
      6 => const [],
      _ => const [],
    };
  }

  static TrainingSession _longRun(
    RaceGoal goal,
    int weekIdx,
    int totalWeeks,
    int base,
  ) {
    final peak = goal.peakLongRunKm;
    // 向导里的「首周长距离」是用户可见、可调的；目标项目的
    // startLongRunKm 只是没有历史时的默认值，不能把用户选的下限硬夹回去。
    final start = base.clamp(4, peak).toInt();
    final step = goal.longRunStepKm;
    final km = switch (weekIdx) {
      _ when weekIdx == totalWeeks - 1 => goal.activationKm,
      _ when weekIdx == totalWeeks - 2 && totalWeeks >= 4 => _taperLongRunKm(
        goal,
        start,
        weekIdx,
        step,
        peak,
      ),
      _ => math.min(peak, start + weekIdx * step),
    };
    return TrainingSession(SessionKind.long, km: km);
  }

  /// 赛前减量周不能比上一周还长，也不能低于激活跑的量级。
  static int _taperLongRunKm(
    RaceGoal goal,
    int start,
    int weekIdx,
    int step,
    int peak,
  ) {
    final previous = math.min(peak, start + math.max(0, weekIdx - 1) * step);
    final target = math.max(goal.activationKm + 1, (previous * 0.7).round());
    return math.min(previous, target);
  }

  static TrainingSession _run(SessionKind kind, int km, {int blocks = 0}) =>
      TrainingSession(kind, km: km, intervalBlocks: blocks);

  static TrainingSession _strength() =>
      const TrainingSession(SessionKind.strength, strengthMinutes: 30);

  Map<String, dynamic> toJson() => {
    'v': 2,
    'id': planId,
    'name': name,
    'goal': goal.name,
    'race': _dateKey(raceDate),
    'start': _dateKey(startDate),
    'pace': basePaceSec,
    'long': longRunKm,
    'created': createdMs,
    'pf': paceFactor,
    'adapted': lastAdaptedDay,
    'punch': punchSec,
    'adjust': adjustments.map((a) => a.toJson()).toList(),
    'weeks': weeks.map((w) => w.toJson()).toList(),
  };

  TrainingPlan copyWith({
    String? planId,
    String? name,
    RaceGoal? goal,
    DateTime? raceDate,
    DateTime? startDate,
    int? basePaceSec,
    int? longRunKm,
    int? createdMs,
    List<TrainingWeek>? weeks,
    double? paceFactor,
    int? lastAdaptedDay,
    int? punchSec,
    List<PlanAdjustment>? adjustments,
  }) => TrainingPlan(
    planId: planId ?? this.planId,
    name: name ?? this.name,
    goal: goal ?? this.goal,
    raceDate: raceDate ?? this.raceDate,
    startDate: startDate ?? this.startDate,
    basePaceSec: basePaceSec ?? this.basePaceSec,
    longRunKm: longRunKm ?? this.longRunKm,
    createdMs: createdMs ?? this.createdMs,
    weeks: weeks ?? this.weeks,
    paceFactor: paceFactor ?? this.paceFactor,
    lastAdaptedDay: lastAdaptedDay ?? this.lastAdaptedDay,
    punchSec: punchSec ?? this.punchSec,
    adjustments: adjustments ?? this.adjustments,
  );

  /// 把自适应结果应用到未来课表。过去周保持原样，避免重算后历史完成记录对不上。
  TrainingPlan applyAdaptation(PlanAdaptation adaptation, {DateTime? now}) {
    final today = _dateOnly(now ?? DateTime.now());
    final delta = longRunKm - adaptation.longRunKm;
    final adjustedWeeks = delta == 0
        ? weeks
        : [
            for (var i = 0; i < weeks.length; i++)
              TrainingWeek(weeks[i].weekNum, weeks[i].start, [
                for (final day in weeks[i].days)
                  TrainingDay(day.date, [
                    for (final session in day.sessions)
                      if (day.date.isBefore(today) ||
                          session.kind != SessionKind.long ||
                          _hasRace(weeks[i]))
                        session
                      else
                        TrainingSession(
                          SessionKind.long,
                          km: math.max(goal.taperFloorKm, session.km - delta),
                        ),
                  ]),
              ]),
          ];
    final note = PlanAdjustment(
      madeAt: today,
      reason: adaptation.notes.join('；'),
      paceFactor: adaptation.paceFactor,
      longRunKm: adaptation.longRunKm,
    );
    return copyWith(
      weeks: adjustedWeeks,
      paceFactor: adaptation.paceFactor,
      longRunKm: adaptation.longRunKm,
      lastAdaptedDay: _epochDay(today),
      punchSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      adjustments: [...adjustments, note],
    );
  }

  static bool _hasRace(TrainingWeek week) => week.days.any(
    (day) => day.sessions.any((session) => session.kind == SessionKind.race),
  );

  static TrainingPlan? tryParse(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final plan = TrainingPlan(
        planId: json['id'] as String,
        name: json['name'] as String,
        goal: RaceGoal.fromName(json['goal'] as String?),
        raceDate: DateTime.parse(json['race'] as String),
        startDate: DateTime.parse(json['start'] as String),
        basePaceSec: (json['pace'] as num).toInt(),
        longRunKm: (json['long'] as num).toInt(),
        createdMs: (json['created'] as num).toInt(),
        paceFactor: (json['pf'] as num?)?.toDouble() ?? 1.0,
        lastAdaptedDay: (json['adapted'] as num?)?.toInt() ?? 0,
        punchSec: (json['punch'] as num?)?.toInt() ?? 0,
        adjustments: [
          for (final a in (json['adjust'] as List? ?? const []))
            PlanAdjustment.fromJson(Map<String, dynamic>.from(a as Map)),
        ],
        weeks: [
          for (final w in (json['weeks'] as List? ?? const []))
            TrainingWeek.fromJson(Map<String, dynamic>.from(w as Map)),
        ],
      );
      final version = (json['v'] as num?)?.toInt() ?? 1;
      if (version < 2 && plan.needsLegacyScheduleRebuild) {
        return plan.rebuildLegacySchedule();
      }
      return plan;
    } catch (_) {
      return null;
    }
  }

  /// v1 计划把历史最长距离当成首周长距离，前几周就会出现远超当前
  /// 周跑量的周六长距离。只在确实命中这种断崖时才重排。
  bool get needsLegacyScheduleRebuild {
    if (weeks.isEmpty) return true;
    for (var i = 0; i < math.min(3, weeks.length); i++) {
      if (weeks[i].longRunKm > goal.startLongRunKm + 2) return true;
    }
    return false;
  }

  /// 重排旧计划：过去的周保持不动，未来的周按新的渐进规则重建。
  TrainingPlan rebuildLegacySchedule({DateTime? now}) {
    final safeStart = math.min(longRunKm, goal.startLongRunKm);
    final regenerated = TrainingPlan.generate(
      goal: goal,
      raceDate: raceDate,
      basePaceSec: basePaceSec,
      longRunKm: safeStart,
      paceFactor: paceFactor,
      lastAdaptedDay: lastAdaptedDay,
      adjustments: adjustments,
      planId: planId,
      now: startDate,
    );
    final today = _dateOnly(now ?? DateTime.now());
    final merged = <TrainingWeek>[];
    for (var i = 0; i < weeks.length && i < regenerated.weeks.length; i++) {
      final current = weeks[i];
      final rebuilt = regenerated.weeks[i];
      // 断崖周即便已经过去也不能原样保留：旧版正是把 21km 写进了首周周六。
      // 正常的历史周仍按原计划保留，只有异常周整周按新规则重建。
      final malformed = current.longRunKm > goal.startLongRunKm + 2;
      final days = <TrainingDay>[];
      for (var j = 0; j < rebuilt.days.length; j++) {
        final oldDay = j < current.days.length ? current.days[j] : null;
        days.add(
          oldDay != null && !malformed && oldDay.date.isBefore(today)
              ? oldDay
              : rebuilt.days[j],
        );
      }
      merged.add(TrainingWeek(rebuilt.weekNum, rebuilt.start, days));
    }
    if (regenerated.weeks.length > merged.length) {
      merged.addAll(regenerated.weeks.skip(merged.length));
    }
    return copyWith(
      weeks: merged,
      longRunKm: safeStart,
      punchSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }
}

class PlanAdjustment {
  const PlanAdjustment({
    required this.madeAt,
    required this.reason,
    required this.paceFactor,
    required this.longRunKm,
  });

  final DateTime madeAt;
  final String reason;
  final double paceFactor;
  final int longRunKm;

  Map<String, dynamic> toJson() => {
    'd': _dateKey(madeAt),
    'r': reason,
    'p': paceFactor,
    'l': longRunKm,
  };

  static PlanAdjustment fromJson(Map<String, dynamic> json) => PlanAdjustment(
    madeAt: DateTime.parse(json['d'] as String),
    reason: json['r'] as String? ?? '',
    paceFactor: (json['p'] as num?)?.toDouble() ?? 1.0,
    longRunKm: (json['l'] as num?)?.toInt() ?? 0,
  );
}

enum CourseCompletionStatus { auto, manual, cancelled }

class CourseCompletion {
  const CourseCompletion(this.status, {this.workout});

  final CourseCompletionStatus status;
  final WorkoutSummary? workout;

  bool get done => status != CourseCompletionStatus.cancelled;

  String get detail {
    if (status == CourseCompletionStatus.manual) return '手动';
    final w = workout;
    if (workout == null || w!.distanceM <= 0 || w.durationSec <= 0) return '';
    return '${fmtDistance(w.distanceM)} · ${fmtPace(w.distanceM, w.durationSec)}';
  }
}

String courseCompletionKey(String planId, DateTime date, int courseIndex) =>
    '$planId|${_dateKey(date)}|$courseIndex';

bool isRunWorkout(String sport) {
  final s = sport.toLowerCase();
  return s.contains('run') ||
      s == 'treadmill' ||
      s.contains('跑步') ||
      s.contains('慢跑');
}

bool _autoRunnable(SessionKind kind) =>
    kind == SessionKind.easy ||
    kind == SessionKind.long ||
    kind == SessionKind.tempo ||
    kind == SessionKind.interval;

class PlanProgress {
  const PlanProgress({
    required this.plan,
    required this.items,
    required this.doneCount,
    required this.totalCount,
    required this.pastRunnableTotal,
    required this.pastRunnableMatched,
  });

  final TrainingPlan plan;
  final Map<String, CourseCompletion> items;
  final int doneCount;
  final int totalCount;

  /// 自适应只统计今天之前的跑步课。
  final int pastRunnableTotal;
  final int pastRunnableMatched;

  double get completionRate => totalCount == 0 ? 0 : doneCount / totalCount;

  double get adaptiveCompletionRate =>
      pastRunnableTotal == 0 ? 1 : pastRunnableMatched / pastRunnableTotal;

  CourseCompletion? at(DateTime date, int courseIndex) =>
      items[courseCompletionKey(plan.planId, date, courseIndex)];

  int weekDone(TrainingWeek week) => [
    for (final day in week.days)
      for (var i = 0; i < day.sessions.length; i++)
        if (at(day.date, i)?.done == true) 1,
  ].length;

  int weekTotal(TrainingWeek week) =>
      week.days.fold(0, (sum, day) => sum + day.sessions.length);
}

PlanProgress buildPlanProgress({
  required TrainingPlan plan,
  required List<WorkoutSummary> workouts,
  required Map<String, int> manual,
  DateTime? now,
}) {
  final today = _dateOnly(now ?? DateTime.now());
  final byDate = <String, List<WorkoutSummary>>{};
  for (final workout in workouts) {
    final at = DateTime.fromMillisecondsSinceEpoch(workout.startMs.toInt());
    byDate.putIfAbsent(_dateKey(at), () => []).add(workout);
  }

  final items = <String, CourseCompletion>{};
  var done = 0;
  var total = 0;
  var pastRunnable = 0;
  var pastMatched = 0;
  for (final week in plan.weeks) {
    for (final day in week.days) {
      final pool = (byDate[_dateKey(day.date)] ?? const <WorkoutSummary>[])
          .toList();
      for (var index = 0; index < day.sessions.length; index++) {
        total++;
        final session = day.sessions[index];
        final key = courseCompletionKey(plan.planId, day.date, index);
        final manualStatus = manual[key];
        if (manualStatus == 0) {
          items[key] = const CourseCompletion(CourseCompletionStatus.cancelled);
          continue;
        }
        if (manualStatus == 2) {
          items[key] = const CourseCompletion(CourseCompletionStatus.manual);
          done++;
          continue;
        }

        final isPastRunnable =
            day.date.isBefore(today) && _autoRunnable(session.kind);
        if (isPastRunnable) pastRunnable++;
        if (day.date.isAfter(today) || !_autoRunnable(session.kind)) continue;

        final hit = _matchCourse(session, pool);
        if (hit == null) continue;
        pool.remove(hit);
        items[key] = CourseCompletion(
          CourseCompletionStatus.auto,
          workout: hit,
        );
        done++;
        if (isPastRunnable) pastMatched++;
      }
    }
  }
  return PlanProgress(
    plan: plan,
    items: items,
    doneCount: done,
    totalCount: total,
    pastRunnableTotal: pastRunnable,
    pastRunnableMatched: pastMatched,
  );
}

WorkoutSummary? _matchCourse(
  TrainingSession session,
  List<WorkoutSummary> pool,
) {
  final plannedMeters = session.km * 1000.0;
  if (plannedMeters <= 0) return null;
  for (final workout in pool) {
    if (!isRunWorkout(workout.sport) ||
        workout.durationSec <= 0 ||
        workout.distanceM < plannedMeters * 0.6 ||
        workout.distanceM > plannedMeters * 1.5) {
      continue;
    }
    return workout;
  }
  return null;
}

class PlanAdaptation {
  const PlanAdaptation({
    required this.paceFactor,
    required this.longRunKm,
    required this.notes,
  });

  final double paceFactor;
  final int longRunKm;
  final List<String> notes;
}

/// 旧版 PlanAdapter 的端上规则：配速漂移 + 完成率 + 近两晚 HRV 回撤。
PlanAdaptation adaptTrainingPlan({
  required TrainingPlan plan,
  required List<WorkoutSummary> workouts,
  required List<DailyPoint> hrv,
  required Map<String, int> manual,
  DateTime? now,
}) {
  final today = _dateOnly(now ?? DateTime.now());
  final progress = buildPlanProgress(
    plan: plan,
    workouts: workouts,
    manual: manual,
    now: today,
  );
  final ratios = <double>[];
  for (final week in plan.weeks) {
    for (final day in week.days) {
      if (!day.date.isBefore(today)) continue;
      for (var index = 0; index < day.sessions.length; index++) {
        final session = day.sessions[index];
        if (!_autoRunnable(session.kind)) continue;
        final completion = progress.at(day.date, index);
        final workout = completion?.workout;
        if (completion?.status != CourseCompletionStatus.auto ||
            workout == null ||
            workout.distanceM <= 0 ||
            workout.durationSec <= 0) {
          continue;
        }
        final plannedPace = session.targetPaceSec(
          plan.basePaceSec,
          paceFactor: plan.paceFactor,
        );
        if (plannedPace <= 0) continue;
        final actualPace = workout.durationSec * 1000 / workout.distanceM;
        ratios.add(actualPace / plannedPace);
      }
    }
  }

  var factor = plan.paceFactor;
  var longKm = plan.longRunKm;
  final notes = <String>[];
  if (ratios.isNotEmpty) {
    var ema = ratios.last;
    for (final ratio in ratios.skip(math.max(0, ratios.length - 4))) {
      ema = 0.4 * ratio + 0.6 * ema;
    }
    if (ema < 0.96 && progress.adaptiveCompletionRate >= 0.6) {
      factor *= 0.98;
      notes.add(
        '近 ${ratios.length} 次课快于计划（漂移 ${ema.toStringAsFixed(2)}），配速收紧 2%',
      );
    } else if (ema > 1.06) {
      factor *= 1.03;
      notes.add('实测配速慢于计划（漂移 ${ema.toStringAsFixed(2)}），配速放松 3%');
    }
  }

  if (progress.pastRunnableTotal >= 3 &&
      progress.adaptiveCompletionRate < 0.6) {
    factor *= 1.03;
    notes.add(
      '课程完成率 ${(progress.adaptiveCompletionRate * 100).round()}% 偏低'
      '（${progress.pastRunnableTotal} 次课完成 ${progress.pastRunnableMatched} 次），配速放松 3%',
    );
  }

  if (_hrvDips(hrv)) {
    longKm = math.max(plan.goal.taperFloorKm, longKm - 1);
    notes.add('连续两晚 HRV 低于基线 90%，长距离回撤至 $longKm km');
  }
  factor = factor.clamp(0.92, 1.15).toDouble();
  return PlanAdaptation(
    paceFactor: double.parse(factor.toStringAsFixed(4)),
    longRunKm: longKm,
    notes: notes,
  );
}

bool _hrvDips(List<DailyPoint> hrv) {
  final valid = [
    for (final point in hrv)
      if (point.value > 0) point,
  ]..sort((a, b) => a.dateEpochDay.compareTo(b.dateEpochDay));
  if (valid.length < 3) return false;
  final baselinePoints = valid.length > 14
      ? valid.sublist(valid.length - 14)
      : valid;
  final values = [for (final point in baselinePoints) point.value]..sort();
  final median = values.length.isOdd
      ? values[values.length ~/ 2]
      : (values[values.length ~/ 2 - 1] + values[values.length ~/ 2]) / 2;
  if (median <= 0) return false;
  return valid
      .sublist(valid.length - 2)
      .every((point) => point.value < median * 0.9);
}

/// 生成手表协议需要的“当前周”载荷。日期/配速都在这里换算成秒，
/// Kotlin 侧只负责编码 TrainingPlan / CourseStorageInfo。
Map<String, dynamic> watchPlanPayload(TrainingPlan plan, {DateTime? today}) {
  final now = _dateOnly(today ?? DateTime.now());
  final week = plan.currentWeek;
  if (week == null) {
    throw StateError('训练计划没有周安排');
  }
  final weekStart = _dateOnly(week.start);
  final byDate = {for (final day in week.days) _dateKey(day.date): day};
  final days = <Map<String, dynamic>>[];
  for (var offset = 0; offset < 7; offset++) {
    final date = weekStart.add(Duration(days: offset));
    final day = byDate[_dateKey(date)];
    final passed = date.isBefore(now);
    days.add({
      'startSec': date.millisecondsSinceEpoch ~/ 1000,
      'isDayPunch': 0,
      'courses': passed
          ? const <Map<String, dynamic>>[]
          : [
              for (var i = 0; i < (day?.sessions.length ?? 0); i++)
                _watchCourse(plan, week, offset, i, day!.sessions[i]),
            ],
    });
  }
  return {
    'planId': plan.planId,
    'planName': plan.name,
    'planStartSec':
        _dateOnly(plan.weeks.first.start).millisecondsSinceEpoch ~/ 1000,
    'planTotalDays': plan.weeks.length * 7,
    'planTotalWeeks': plan.weeks.length,
    'currentWeekNum': week.weekNum,
    'currentWeekName': '第${week.weekNum}周',
    'currentWeekStartSec': weekStart.millisecondsSinceEpoch ~/ 1000,
    'currentWeekEndSec':
        weekStart.add(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000 -
        1,
    // 内容不变必须保持稳定，否则手表永远认为有新版本、反复重推。
    'punchSec': plan.punchSec > 0 ? plan.punchSec : plan.createdMs ~/ 1000,
    'days': days,
  };
}

Map<String, dynamic> _watchCourse(
  TrainingPlan plan,
  TrainingWeek week,
  int dayOffset,
  int courseIndex,
  TrainingSession session,
) {
  final courseType = switch (session.kind) {
    SessionKind.strength => 5,
    SessionKind.race => 0,
    _ => 4,
  };
  final durationSec = switch (session.kind) {
    SessionKind.strength => session.strengthMinutes * 60,
    SessionKind.race => 0,
    _ => math.max(
      60,
      session.km *
          session.targetPaceSec(plan.basePaceSec, paceFactor: plan.paceFactor),
    ),
  };
  final name = switch (session.kind) {
    SessionKind.strength =>
      '${session.kind.label} ${session.strengthMinutes}分钟',
    SessionKind.race => '${plan.goal.label}比赛',
    _ => '${session.kind.label} ${session.km}km',
  };
  return {
    'id':
        '${plan.planId}_w${week.weekNum}d$dayOffset'
        '_c$courseIndex',
    'name': name,
    'durationSec': durationSec,
    'courseType': courseType,
    'defineType': 0,
    'exerciseVersion': '1',
    'updateSec': plan.createdMs ~/ 1000,
    'segments': switch (session.kind) {
      SessionKind.easy ||
      SessionKind.long ||
      SessionKind.tempo ||
      SessionKind.interval => _runSegments(session, durationSec),
      _ => const <Map<String, dynamic>>[],
    },
  };
}

List<Map<String, dynamic>> _runSegments(TrainingSession session, int totalSec) {
  final zone = switch (session.kind) {
    SessionKind.easy || SessionKind.long => 2,
    SessionKind.tempo => 3,
    SessionKind.interval => 4,
    _ => 2,
  };
  final warmup = math.min(600, totalSec ~/ 6);
  final cooldown = math.min(300, totalSec ~/ 8);
  final main = math.max(60, totalSec - warmup - cooldown);
  Map<String, dynamic> segment(String actionId, int seconds, int heartZone) => {
    'actionId': actionId,
    'durationSec': seconds,
    'intensityType': 17,
    'intensityZone': heartZone,
  };
  if (session.kind != SessionKind.interval || session.intervalBlocks <= 1) {
    return [
      segment('RD001', warmup, 1),
      segment('RD002', main, zone),
      segment('RD005', cooldown, 1),
    ];
  }
  final blocks = session.intervalBlocks;
  final fastSec = main * 2 ~/ (blocks * 3);
  final walkSec = math.max(60, (main - fastSec * blocks) ~/ blocks);
  return [
    segment('RD001', warmup, 1),
    for (var i = 0; i < blocks; i++) ...[
      segment('RD002', fastSec, zone),
      segment('RD003', walkSec, 1),
    ],
    segment('RD005', cooldown, 1),
  ];
}

class TrainingPlanScreen extends StatefulWidget {
  const TrainingPlanScreen({super.key, required this.state});

  final AppState state;

  @override
  State<TrainingPlanScreen> createState() => _TrainingPlanScreenState();
}

class _TrainingPlanScreenState extends State<TrainingPlanScreen> {
  TrainingPlan? _plan;
  Map<String, int> _manual = {};
  bool _loaded = false;
  bool _adapting = false;

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    TrainingPlan? loaded;
    final manual = <String, int>{};
    try {
      final raw = await VitaloopApi.setting(_planSettingKey);
      loaded = TrainingPlan.tryParse(raw);
      if (loaded != null && _legacyPlanJson(raw)) {
        await VitaloopApi.setSetting(
          _planSettingKey,
          jsonEncode(loaded.toJson()),
        );
      }
    } catch (_) {
      // 读取失败就按没有计划处理，不影响重新创建。
    }
    try {
      final manualRaw = await VitaloopApi.setting(_planManualSettingKey);
      if (manualRaw.trim().isNotEmpty) {
        final decoded = jsonDecode(manualRaw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is num) {
              manual[entry.key.toString()] = value.toInt();
            }
          }
        }
      }
    } catch (_) {
      // 打卡记录损坏时按未打卡处理，计划本身仍可正常打开。
    }
    if (mounted) {
      setState(() {
        _plan = loaded;
        _manual = manual;
      });
    }
    if (mounted) setState(() => _loaded = true);
    if (loaded != null) unawaited(_maybeAdapt(loaded));
  }

  Future<void> _openWizard() async {
    final bests = RunningBests.mine(widget.state.workouts);
    final plan = await showDialog<TrainingPlan>(
      context: context,
      builder: (_) => _PlanWizardDialog(bests: bests, current: _plan),
    );
    if (plan == null || !mounted) return;
    try {
      final now = DateTime.now();
      final stamped = plan.copyWith(
        lastAdaptedDay: _epochDay(now),
        punchSec: now.millisecondsSinceEpoch ~/ 1000,
      );
      await VitaloopApi.setSetting(
        _planSettingKey,
        jsonEncode(stamped.toJson()),
      );
      await VitaloopApi.setSetting('training_plan_goal', stamped.goal.label);
      if (mounted) setState(() => _plan = stamped);
      unawaited(_syncPlanToWatch(stamped));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存计划失败：$e')));
      }
    }
  }

  Future<void> _maybeAdapt(TrainingPlan plan) async {
    if (_adapting) return;
    final today = _dateOnly(DateTime.now());
    if (plan.lastAdaptedDay == _epochDay(today)) return;
    _adapting = true;
    try {
      final hrv = await VitaloopApi.metricSeries('hrv', 14);
      final adaptation = adaptTrainingPlan(
        plan: plan,
        workouts: widget.state.workouts,
        hrv: hrv,
        manual: _manual,
        now: today,
      );
      final updated = adaptation.notes.isEmpty
          ? plan.copyWith(lastAdaptedDay: _epochDay(today))
          : plan.applyAdaptation(adaptation, now: today);
      await VitaloopApi.setSetting(
        _planSettingKey,
        jsonEncode(updated.toJson()),
      );
      if (mounted) setState(() => _plan = updated);
      if (adaptation.notes.isNotEmpty) {
        unawaited(_syncPlanToWatch(updated));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('计划已按最近训练调整：${adaptation.notes.join('；')}')),
          );
        }
      }
    } catch (_) {
      // 自适应失败保留原计划，不影响课表展示。
    } finally {
      _adapting = false;
    }
  }

  Future<void> _toggleManual(
    TrainingPlan plan,
    DateTime date,
    int courseIndex,
    bool done,
  ) async {
    final key = courseCompletionKey(plan.planId, date, courseIndex);
    setState(() {
      _manual[key] = done ? 2 : 0;
    });
    try {
      await VitaloopApi.setSetting(_planManualSettingKey, jsonEncode(_manual));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存打卡失败：$e')));
      }
    }
  }

  Future<void> _syncPlanToWatch(TrainingPlan plan) async {
    try {
      final result = await WatchBridge.instance.pushTrainingPlan(
        jsonEncode(watchPlanPayload(plan)),
      );
      if (!mounted) return;
      final message = result['message'] as String? ?? '训练计划已保存';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      // 桥接失败不影响本机计划。
    }
  }

  Future<void> _deletePlan() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除训练计划', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '会删除本机的备赛课表，历史运动记录不受影响。',
          style: VText.body.copyWith(color: ctx.v.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final planId = _plan?.planId ?? '';
    await VitaloopApi.setSetting(_planSettingKey, '');
    await VitaloopApi.setSetting('training_plan_goal', '');
    _manual.removeWhere((key, _) => key.startsWith('$planId|'));
    await VitaloopApi.setSetting(_planManualSettingKey, jsonEncode(_manual));
    if (planId.isNotEmpty) {
      unawaited(WatchBridge.instance.finishTrainingPlan(planId));
    }
    if (mounted) setState(() => _plan = null);
  }

  void _showWeek(TrainingPlan plan, TrainingWeek week) {
    final v = context.v;
    showModalBottomSheet(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        maxChildSize: 0.9,
        builder: (ctx, controller) => StatefulBuilder(
          builder: (ctx, setSheetState) {
            final progress = buildPlanProgress(
              plan: plan,
              workouts: widget.state.workouts,
              manual: _manual,
            );
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 30),
              children: [
                Text(
                  '第 ${week.weekNum} 周',
                  style: VText.h2.copyWith(color: ctx.v.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  '${monthDayShort(week.start)} – ${monthDayShort(week.start.add(const Duration(days: 6)))} · 跑量 ${week.totalRunKm} km · 完成 ${progress.weekDone(week)}/${progress.weekTotal(week)}',
                  style: VText.meta.copyWith(color: ctx.v.muted),
                ),
                const SizedBox(height: 14),
                for (final day in week.days) ...[
                  _CourseDayRow(
                    plan: plan,
                    day: day,
                    progress: progress,
                    onToggle: (date, index, done) async {
                      await _toggleManual(plan, date, index, done);
                      if (ctx.mounted) setSheetState(() {});
                    },
                  ),
                  Divider(color: ctx.v.line, height: 1),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: widget.state,
          builder: (context, _) {
            final plan = _plan;
            final progress = plan == null
                ? null
                : buildPlanProgress(
                    plan: plan,
                    workouts: widget.state.workouts,
                    manual: _manual,
                  );
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                const VDetailHeader(title: '训练计划'),
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.only(top: 120),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (plan == null)
                  _EmptyPlanCard(onCreate: _openWizard)
                else ...[
                  _PlanHero(plan: plan, progress: progress!),
                  const VSectionHead(title: '本周安排'),
                  _CurrentWeekCard(
                    plan: plan,
                    progress: progress,
                    onToggle: (date, index, done) =>
                        _toggleManual(plan, date, index, done),
                    onTap: plan.currentWeek == null
                        ? null
                        : () => _showWeek(plan, plan.currentWeek!),
                  ),
                  VSectionHead(
                    title: '全部周次',
                    trailing: '${plan.weeks.length} 周',
                  ),
                  for (final week in plan.weeks)
                    _WeekRow(
                      plan: plan,
                      week: week,
                      progress: progress,
                      onTap: () => _showWeek(plan, week),
                    ),
                  const SizedBox(height: 6),
                  VPrimaryButton(
                    label: '重新生成计划',
                    icon: Icons.refresh_rounded,
                    onTap: _openWizard,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _deletePlan,
                    child: Text(
                      '删除计划',
                      style: VText.meta.copyWith(color: v.muted),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EmptyPlanCard extends StatelessWidget {
  const _EmptyPlanCard({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Column(
      children: [
        VCard(
          background: v.mint,
          foreground: v.mintInk,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '按比赛日生成课表',
                style: VText.value.copyWith(fontSize: 21, color: v.mintInk),
              ),
              const SizedBox(height: 7),
              Text(
                '读取历史跑步记录里的最长距离、最长用时和跑步次数，自动匹配目标配速；从本周一排到比赛日所在那周。',
                style: VText.label.copyWith(
                  color: v.mintInk.withValues(alpha: 0.8),
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        VPrimaryButton(
          label: '创建训练计划',
          icon: Icons.auto_awesome_rounded,
          onTap: onCreate,
        ),
      ],
    );
  }
}

class _PlanHero extends StatelessWidget {
  const _PlanHero({required this.plan, required this.progress});

  final TrainingPlan plan;
  final PlanProgress progress;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final week = plan.currentWeek;
    final countdown = plan.daysLeft > 0
        ? '距比赛 ${plan.daysLeft} 天'
        : (plan.daysLeft == 0 ? '今天是比赛日' : '比赛日已过');
    return VCard(
      background: v.mint,
      foreground: v.mintInk,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            plan.name,
            style: VText.value.copyWith(fontSize: 22, color: v.mintInk),
          ),
          const SizedBox(height: 5),
          Text(
            '${monthDay(plan.raceDate)} · $countdown${week == null ? '' : ' · 第 ${week.weekNum}/${plan.weeks.length} 周'}',
            style: VText.label.copyWith(
              color: v.mintInk.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _HeroStat(label: '总周数', value: '${plan.weeks.length} 周'),
              _HeroStat(label: '目标配速', value: paceLabelOf(plan.basePaceSec)),
              _HeroStat(label: '长距离基准', value: '${plan.longRunKm} km'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '当前课表已完成 ${progress.doneCount}/${progress.totalCount}'
            ' · ${(progress.completionRate * 100).round()}%',
            style: VText.meta.copyWith(
              color: v.mintInk.withValues(alpha: 0.82),
            ),
          ),
          if (plan.adjustments.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '最近调整：${plan.adjustments.last.reason}',
              style: VText.meta.copyWith(
                color: v.mintInk.withValues(alpha: 0.72),
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: VText.h3.copyWith(fontSize: 15, color: v.mintInk)),
          const SizedBox(height: 2),
          Text(
            label,
            style: VText.meta.copyWith(
              color: v.mintInk.withValues(alpha: 0.66),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentWeekCard extends StatelessWidget {
  const _CurrentWeekCard({
    required this.plan,
    required this.progress,
    required this.onToggle,
    this.onTap,
  });

  final TrainingPlan plan;
  final PlanProgress progress;
  final Future<void> Function(DateTime date, int index, bool done) onToggle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final week = plan.currentWeek;
    if (week == null) {
      return const VCard(child: Text('计划里还没有周次'));
    }
    return VCard(
      onTap: onTap,
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '本周完成 ${progress.weekDone(week)}/${progress.weekTotal(week)}',
                style: VText.meta.copyWith(color: v.muted),
              ),
              const Spacer(),
              Text('点日期看全部周次', style: VText.meta.copyWith(color: v.muted)),
            ],
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < week.days.length; i++) ...[
            if (i > 0) Divider(color: v.line, height: 1),
            _CourseDayRow(
              plan: plan,
              day: week.days[i],
              progress: progress,
              onToggle: onToggle,
            ),
          ],
        ],
      ),
    );
  }
}

class _DoneCircle extends StatelessWidget {
  const _DoneCircle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: context.v.greenInk, width: 1.5),
      ),
    );
  }
}

class _CourseDayRow extends StatelessWidget {
  const _CourseDayRow({
    required this.plan,
    required this.day,
    required this.progress,
    required this.onToggle,
  });

  final TrainingPlan plan;
  final TrainingDay day;
  final PlanProgress progress;
  final Future<void> Function(DateTime date, int index, bool done) onToggle;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final today = _dateOnly(DateTime.now());
    final canCheck = !day.date.isAfter(today);
    if (day.sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 50,
              child: Text(
                weekday(day.date),
                style: VText.meta.copyWith(color: v.muted),
              ),
            ),
            Expanded(
              child: Text('休息', style: VText.body.copyWith(color: v.muted)),
            ),
            Text(
              monthDayShort(day.date),
              style: VText.meta.copyWith(color: v.muted),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                weekday(day.date),
                style: VText.meta.copyWith(
                  color: day.date.weekday == DateTime.sunday ? v.muted : v.ink2,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                for (var index = 0; index < day.sessions.length; index++)
                  PlanCourseLine(
                    plan: plan,
                    day: day,
                    index: index,
                    completion: progress.at(day.date, index),
                    canCheck: canCheck,
                    onToggle: onToggle,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              monthDayShort(day.date),
              style: VText.meta.copyWith(color: v.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class PlanCourseLine extends StatelessWidget {
  const PlanCourseLine({
    super.key,
    required this.plan,
    required this.day,
    required this.index,
    required this.completion,
    required this.canCheck,
    required this.onToggle,
  });

  final TrainingPlan plan;
  final TrainingDay day;
  final int index;
  final CourseCompletion? completion;
  final bool canCheck;
  final Future<void> Function(DateTime date, int index, bool done) onToggle;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final session = day.sessions[index];
    final c = completion;
    final done = c?.done == true;
    final cancelled = c?.status == CourseCompletionStatus.cancelled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    session.describe(
                      plan.basePaceSec,
                      paceFactor: plan.paceFactor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VText.body.copyWith(
                      color: done ? v.greenInk : v.ink2,
                    ),
                  ),
                ),
                if (done) ...[
                  const SizedBox(width: 5),
                  const _DoneCircle(),
                  if ((c?.detail ?? '').isNotEmpty) ...[
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 132),
                      child: Text(
                        c!.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: VText.meta.copyWith(color: v.greenInk),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          // 完成/未完成共用同一个固定宽度的尾部槽，打卡、取消、补卡
          // 都贴右边缘，不会因为完成标记和多出来的详情文字错位。
          const SizedBox(width: 6),
          SizedBox(
            width: 46,
            child: Align(
              alignment: Alignment.centerRight,
              child: done
                  ? TextButton(
                      onPressed: () {
                        unawaited(onToggle(day.date, index, false));
                      },
                      style: _compactButtonStyle,
                      child: Text(
                        '取消',
                        style: VText.meta.copyWith(color: v.muted),
                      ),
                    )
                  : canCheck
                  ? TextButton(
                      onPressed: () {
                        unawaited(onToggle(day.date, index, true));
                      },
                      style: _compactButtonStyle,
                      child: Text(
                        cancelled ? '补卡' : '打卡',
                        style: VText.meta.copyWith(
                          color: cancelled ? v.warnInk : v.blueInk,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

final _compactButtonStyle = TextButton.styleFrom(
  minimumSize: const Size(0, 30),
  padding: const EdgeInsets.symmetric(horizontal: 7),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day, required this.basePaceSec});

  final TrainingDay day;
  final int basePaceSec;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final session = day.sessions.isEmpty ? null : day.sessions.first;
    final extra = day.sessions.length > 1
        ? ' +${day.sessions.length - 1} 项'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              weekday(day.date),
              style: VText.meta.copyWith(
                color: day.date.weekday == DateTime.sunday ? v.muted : v.ink2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              session == null ? '休息' : '${session.describe(basePaceSec)}$extra',
              style: VText.body.copyWith(
                color: session == null ? v.muted : v.ink2,
              ),
            ),
          ),
          Text(
            monthDayShort(day.date),
            style: VText.meta.copyWith(color: v.muted),
          ),
        ],
      ),
    );
  }
}

class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.plan,
    required this.week,
    required this.progress,
    required this.onTap,
  });

  final TrainingPlan plan;
  final TrainingWeek week;
  final PlanProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final isCurrent = plan.currentWeek?.weekNum == week.weekNum;
    return VCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isCurrent ? v.tintBlue : v.tintGrey,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Text(
              '${week.weekNum}',
              style: VText.h3.copyWith(color: isCurrent ? v.blueInk : v.ink2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '第 ${week.weekNum} 周',
                      style: VText.h3.copyWith(color: v.ink),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: v.tintBlue,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '本周',
                          style: VText.meta.copyWith(color: v.blueInk),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${monthDayShort(week.start)} – ${monthDayShort(week.start.add(const Duration(days: 6)))}'
                  ' · 跑量 ${week.totalRunKm} km · 完成 ${progress.weekDone(week)}/${progress.weekTotal(week)}',
                  style: VText.meta.copyWith(color: v.muted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: v.muted),
        ],
      ),
    );
  }
}

class _PlanWizardDialog extends StatefulWidget {
  const _PlanWizardDialog({required this.bests, this.current});

  final RunningBests bests;
  final TrainingPlan? current;

  @override
  State<_PlanWizardDialog> createState() => _PlanWizardDialogState();
}

class _PlanWizardDialogState extends State<_PlanWizardDialog> {
  late RaceGoal _goal;
  late DateTime _raceDate;
  int? _paceOverride;
  int? _longRunOverride;
  bool _dateTouched = false;
  int _step = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _goal = widget.current?.goal ?? widget.bests.suggestGoal();
    _raceDate = widget.current?.raceDate ?? _defaultRaceDate(_goal);
  }

  DateTime _defaultRaceDate(RaceGoal goal) {
    final today = _dateOnly(DateTime.now());
    return today.add(Duration(days: goal.defaultWeeks * 7));
  }

  int get _paceSec =>
      _paceOverride ?? widget.bests.paceBasis(_goal)?.paceSecPerKm ?? 330;

  int get _longRunKm => _longRunOverride ?? _autoLongRunKm(_goal);

  int _autoLongRunKm(RaceGoal goal) {
    final longest = widget.bests.longestRunKm;
    if (longest == null) return goal.startLongRunKm;
    // 历史最长只用于避免起点过低；再强也不直接顶到峰值。周中都是
    // 5–6km 时，周六从 4–8km 起步，每周只加 1–2km。
    final fromAbility = math.max(4, (longest * 0.4).round());
    return math.min(goal.startLongRunKm, fromAbility);
  }

  int get _weeksToRace {
    final today = _dateOnly(DateTime.now());
    final firstMonday = today.subtract(Duration(days: today.weekday - 1));
    final race = _dateOnly(_raceDate);
    final raceMonday = race.subtract(Duration(days: race.weekday - 1));
    return math.max(1, raceMonday.difference(firstMonday).inDays ~/ 7 + 1);
  }

  void _selectGoal(int index) {
    final goal = RaceGoal.values[index];
    setState(() {
      _goal = goal;
      _paceOverride = null;
      _longRunOverride = null;
      if (!_dateTouched) _raceDate = _defaultRaceDate(goal);
      _error = null;
    });
  }

  Future<void> _pickRaceDate() async {
    final now = _dateOnly(DateTime.now());
    final initial = _raceDate.isAfter(now)
        ? _raceDate
        : _defaultRaceDate(_goal);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.add(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      helpText: '选择比赛日期',
      // 系统字号偏大时 DatePickerDialog 会按 textScale 放大到超出屏幕，
      // 中文七列日历会被裁掉。日历内部固定 1.0，保证整月完整可见。
      builder: (ctx, child) =>
          MediaQuery.withClampedTextScaling(maxScaleFactor: 1.0, child: child!),
    );
    if (picked == null) return;
    setState(() {
      _raceDate = _dateOnly(picked);
      _dateTouched = true;
      _error = null;
    });
  }

  void _save() {
    if (!_raceDate.isAfter(_dateOnly(DateTime.now()))) {
      setState(() => _error = '比赛日必须晚于今天');
      return;
    }
    final plan = TrainingPlan.generate(
      goal: _goal,
      raceDate: _raceDate,
      basePaceSec: _paceSec,
      longRunKm: _longRunKm,
    );
    Navigator.of(context).pop(plan);
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height - 40,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: v.bg,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _step == 0 ? '创建训练计划' : '计划预览',
                            style: VText.h2.copyWith(color: v.ink),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _step == 0
                                ? '按历史跑步记录自动匹配强度和长距离'
                                : '确认后保存到本机，可随时重新生成',
                            style: VText.meta.copyWith(color: v.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: v.muted),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  children: _step == 0 ? _configStep() : _previewStep(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _step == 0
                            ? () => Navigator.of(context).pop()
                            : () => setState(() => _step = 0),
                        child: Text(
                          _step == 0 ? '取消' : '上一步',
                          style: VText.meta.copyWith(color: v.muted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: VPrimaryButton(
                        label: _step == 0 ? '预览计划' : '生成并保存',
                        icon: _step == 0
                            ? Icons.visibility_rounded
                            : Icons.download_done_rounded,
                        onTap: () {
                          if (_step == 0) {
                            setState(() => _step = 1);
                          } else {
                            _save();
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _configStep() {
    final v = context.v;
    final basis = widget.bests.paceBasis(_goal);
    final bests = widget.bests;
    return [
      VCard(
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 17, color: v.blueInk),
                const SizedBox(width: 7),
                Text('历史跑步', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: v.tintBlue,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '自动匹配',
                    style: VText.meta.copyWith(color: v.blueInk),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _HistoryStat(label: '跑步次数', value: '${bests.runCount} 次'),
                _HistoryStat(
                  label: '最长距离',
                  value: bests.longestRunMeters == null
                      ? '--'
                      : fmtDistance(bests.longestRunMeters!),
                ),
                _HistoryStat(
                  label: '最长用时',
                  value: bests.longestRunDurationSec == null
                      ? '--'
                      : fmtDuration(bests.longestRunDurationSec!),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              basis == null
                  ? '历史记录里还没有可用的跑步成绩，先用手动配速生成，之后可以重新匹配。'
                  : '匹配配速 ${paceLabelOf(basis.paceSecPerKm)} · ${basis.source}',
              style: VText.meta.copyWith(
                color: basis == null ? v.warnInk : v.greenInk,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
      VCard(
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('赛事', style: VText.h3.copyWith(color: v.ink)),
            VSegmented(
              options: [for (final g in RaceGoal.values) g.label],
              index: _goal.index,
              onChanged: _selectGoal,
              margin: const EdgeInsets.only(top: 8, bottom: 10),
            ),
            InkWell(
              onTap: _pickRaceDate,
              borderRadius: BorderRadius.circular(13),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: v.tintGrey,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Row(
                  children: [
                    Icon(Icons.event_rounded, size: 17, color: v.ink2),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '比赛日 ${_raceDate.year}.${_raceDate.month}.${_raceDate.day}',
                        style: VText.body.copyWith(color: v.ink),
                      ),
                    ),
                    Text(
                      '训练 $_weeksToRace 周 · 剩 ${math.max(0, _raceDate.difference(_dateOnly(DateTime.now())).inDays)} 天',
                      style: VText.meta.copyWith(color: v.muted),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, size: 18, color: v.muted),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      VCard(
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('目标配速', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                Text(
                  '${paceLabelOf(_paceSec)}${_paceOverride == null ? '（按成绩）' : '（手动）'}',
                  style: VText.meta.copyWith(
                    color: _paceOverride == null ? v.greenInk : v.ink2,
                  ),
                ),
              ],
            ),
            Slider(
              min: 240,
              max: 600,
              divisions: 72,
              value: _paceSec.clamp(240, 600).toDouble(),
              onChanged: (value) =>
                  setState(() => _paceOverride = value.round()),
            ),
            Text(
              '配速越慢数值越大；5\'00" 表示每公里 5 分钟。',
              style: VText.meta.copyWith(color: v.muted),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('首周长距离', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                Text(
                  '$_longRunKm km${_longRunOverride == null ? '（默认）' : '（手动）'}',
                  style: VText.meta.copyWith(
                    color: _longRunOverride == null ? v.greenInk : v.ink2,
                  ),
                ),
              ],
            ),
            Slider(
              min: 4,
              max: _goal.peakLongRunKm.toDouble(),
              divisions: _goal.peakLongRunKm - 4,
              value: _longRunKm.clamp(4, _goal.peakLongRunKm).toDouble(),
              onChanged: (value) =>
                  setState(() => _longRunOverride = value.round()),
            ),
            Text(
              '从 $_longRunKm km 起步，每周最多 +${_goal.longRunStepKm} km，'
              '训练期峰值 ${_goal.peakLongRunKm} km；'
              '${_goal.label}比赛距离只在比赛日跑；赛前两周减量。',
              style: VText.meta.copyWith(color: v.muted, height: 1.5),
            ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(_error!, style: VText.meta.copyWith(color: v.warnInk)),
        ),
    ];
  }

  List<Widget> _previewStep() {
    final v = context.v;
    final plan = TrainingPlan.generate(
      goal: _goal,
      raceDate: _raceDate,
      basePaceSec: _paceSec,
      longRunKm: _longRunKm,
    );
    return [
      VCard(
        background: v.mint,
        foreground: v.mintInk,
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.name,
              style: VText.value.copyWith(fontSize: 21, color: v.mintInk),
            ),
            const SizedBox(height: 6),
            Text(
              '${monthDay(plan.raceDate)} · 共 ${plan.weeks.length} 周 · 目标配速 ${paceLabelOf(plan.basePaceSec)}',
              style: VText.label.copyWith(
                color: v.mintInk.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '从本周一排到比赛日所在周；非比赛周周日休息、周六长距离、周四质量课，比赛周按所选比赛日收尾。',
              style: VText.meta.copyWith(
                color: v.mintInk.withValues(alpha: 0.75),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
      const VSectionHead(title: '全部周次'),
      for (final week in plan.weeks) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 5),
          child: Row(
            children: [
              Text(
                '第 ${week.weekNum} 周',
                style: VText.h3.copyWith(color: v.ink),
              ),
              const Spacer(),
              Text(
                '${monthDayShort(week.start)} – ${monthDayShort(week.start.add(const Duration(days: 6)))} · 跑量 ${week.totalRunKm} km',
                style: VText.meta.copyWith(color: v.muted),
              ),
            ],
          ),
        ),
        VCard(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < week.days.length; i++) ...[
                if (i > 0) Divider(color: v.line, height: 1),
                _DayRow(day: week.days[i], basePaceSec: plan.basePaceSec),
              ],
            ],
          ),
        ),
      ],
      if (_error != null)
        Text(_error!, style: VText.meta.copyWith(color: v.warnInk)),
    ];
  }
}

class _HistoryStat extends StatelessWidget {
  const _HistoryStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: VText.h3.copyWith(color: v.ink)),
          const SizedBox(height: 2),
          Text(label, style: VText.meta.copyWith(color: v.muted)),
        ],
      ),
    );
  }
}
