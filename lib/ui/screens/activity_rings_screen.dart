import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 今日 / 本周 / 本月 / 本年的活动三环、热量柱状图和逐日明细。
///
/// 官方三环（字典 300002）优先；手表只发完整天，所以当天没有官方块时，
/// 热量与锻炼时长回退到 daily_metrics，保证页面不会因为当天块还没落地而空着。
///
/// [ActivityRingsSection] 是不带页面外壳的内容区：活动热量详情页直接内嵌它，
/// 与原有的活动热量趋势合成一页；[ActivityRingsScreen] 只是给它套一层带标题的
/// 滚动外壳，供预览 / 测试使用。
class ActivityRingsScreen extends StatelessWidget {
  const ActivityRingsScreen({
    super.key,
    this.initialRings,
    this.initialCalories,
    this.initialMinutes,
  });

  /// 测试/预览注入；正常运行留空，由 [ActivityRingsSection] 自行拉取。
  final List<DailyRing>? initialRings;
  final MetricDetail? initialCalories;
  final MetricDetail? initialMinutes;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const VDetailHeader(title: '活动三环'),
              ActivityRingsSection(
                initialRings: initialRings,
                initialCalories: initialCalories,
                initialMinutes: initialMinutes,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 活动三环内容区：可独立成页（见 [ActivityRingsScreen]），也可内嵌进活动热量详情页。
class ActivityRingsSection extends StatefulWidget {
  const ActivityRingsSection({
    super.key,
    this.initialRings,
    this.initialCalories,
    this.initialMinutes,
  });

  final List<DailyRing>? initialRings;
  final MetricDetail? initialCalories;
  final MetricDetail? initialMinutes;

  @override
  State<ActivityRingsSection> createState() => _ActivityRingsSectionState();
}

class _RingDay {
  const _RingDay({
    required this.date,
    required this.calories,
    required this.calorieGoal,
    required this.minutes,
    required this.minuteGoal,
    required this.hours,
    required this.hourGoal,
    required this.official,
  });

  final DateTime date;
  final double calories;
  final double calorieGoal;
  final double minutes;
  final double minuteGoal;
  final double hours;
  final double hourGoal;
  final bool official;
}

class _RingBucket {
  const _RingBucket({
    required this.start,
    required this.label,
    required this.calories,
    required this.minutes,
    required this.hours,
    required this.days,
    required this.officialDays,
  });

  final DateTime start;
  final String label;
  final double calories;
  final double minutes;
  final double hours;
  final int days;
  final int officialDays;
}

class _ActivityRingsSectionState extends State<ActivityRingsSection> {
  static const _tabs = ['今日', '本周', '本月', '本年'];
  static const _fallbackCalorieGoal = 500.0;
  static const _fallbackMinuteGoal = 60.0;
  static const _fallbackHourGoal = 3.0;

  int _tab = 0;
  bool _loading = true;
  Object? _error;
  List<DailyRing> _rings = const [];
  MetricDetail? _calories;
  MetricDetail? _minutes;

  @override
  void initState() {
    super.initState();
    if (widget.initialRings != null) {
      _rings = widget.initialRings!;
      _calories = widget.initialCalories;
      _minutes = widget.initialMinutes;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rings = await VitaloopApi.dailyRings(limit: 800);
      final calories = await VitaloopApi.metricDetail(
        'active_calories',
        days: 365,
      );
      final minutes = await VitaloopApi.metricDetail(
        'active_minutes',
        days: 365,
      );
      if (!mounted) return;
      setState(() {
        _rings = rings;
        _calories = calories;
        _minutes = minutes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  (DateTime, DateTime) get _range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = switch (_tab) {
      1 => today.subtract(Duration(days: today.weekday - 1)),
      2 => DateTime(today.year, today.month),
      3 => DateTime(today.year),
      _ => today,
    };
    return (start, today);
  }

  DailyRing? get _latestRing {
    DailyRing? latest;
    for (final ring in _rings) {
      if (latest == null ||
          ring.dateEpochDay.toInt() > latest.dateEpochDay.toInt()) {
        latest = ring;
      }
    }
    return latest;
  }

  List<_RingDay> _days() {
    final (start, end) = _range;
    final ringByDay = {
      for (final ring in _rings) ring.dateEpochDay.toInt(): ring,
    };
    final calorieByDay = {
      for (final p in _calories?.days ?? const <DailyPoint>[])
        p.dateEpochDay.toInt(): p.value,
    };
    final minuteByDay = {
      for (final p in _minutes?.days ?? const <DailyPoint>[])
        p.dateEpochDay.toInt(): p.value,
    };
    final latest = _latestRing;
    final fallbackCalorieGoal = latest == null
        ? _fallbackCalorieGoal
        : latest.calorieGoalMilli / 1000;
    final fallbackMinuteGoal = latest == null
        ? _fallbackMinuteGoal
        : latest.durationGoalMin.toDouble();
    final fallbackHourGoal = latest == null
        ? _fallbackHourGoal
        : latest.activeGoalHours.toDouble();

    final result = <_RingDay>[];
    for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      final day = _epochDay(d);
      final ring = ringByDay[day];
      final calories = ring == null
          ? calorieByDay[day] ?? 0
          : ring.calorieUserMilli / 1000;
      final minutes = ring == null
          ? minuteByDay[day] ?? 0
          : ring.durationUserMin.toDouble();
      final hours = ring?.activeUserHours.toDouble() ?? 0;
      final calorieGoal = ring == null
          ? fallbackCalorieGoal
          : ring.calorieGoalMilli / 1000;
      final minuteGoal = ring == null
          ? fallbackMinuteGoal
          : ring.durationGoalMin.toDouble();
      final hourGoal = ring == null
          ? fallbackHourGoal
          : ring.activeGoalHours.toDouble();
      result.add(
        _RingDay(
          date: d,
          calories: calories,
          calorieGoal: calorieGoal > 0 ? calorieGoal : _fallbackCalorieGoal,
          minutes: minutes,
          minuteGoal: minuteGoal > 0 ? minuteGoal : _fallbackMinuteGoal,
          hours: hours,
          hourGoal: hourGoal > 0 ? hourGoal : _fallbackHourGoal,
          official: ring != null,
        ),
      );
    }
    return result;
  }

  List<_RingBucket> _buckets(List<_RingDay> days) {
    if (_tab == 3) {
      final groups = <int, List<_RingDay>>{};
      for (final day in days) {
        groups.putIfAbsent(day.date.month, () => []).add(day);
      }
      final keys = groups.keys.toList()..sort();
      return [
        for (final key in keys)
          _RingBucket(
            start: DateTime(days.first.date.year, key),
            label: '$key月',
            calories: groups[key]!.fold(0, (a, b) => a + b.calories),
            minutes: groups[key]!.fold(0, (a, b) => a + b.minutes),
            hours: groups[key]!.fold(0, (a, b) => a + b.hours),
            days: groups[key]!.length,
            officialDays: groups[key]!.where((d) => d.official).length,
          ),
      ];
    }
    return [
      for (final day in days)
        _RingBucket(
          start: day.date,
          label: '${day.date.month}/${day.date.day}',
          calories: day.calories,
          minutes: day.minutes,
          hours: day.hours,
          days: 1,
          officialDays: day.official ? 1 : 0,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final days = _days();
    final buckets = _buckets(days);
    final calories = days.fold<double>(0, (a, b) => a + b.calories);
    final calorieGoal = days.fold<double>(0, (a, b) => a + b.calorieGoal);
    final minutes = days.fold<double>(0, (a, b) => a + b.minutes);
    final minuteGoal = days.fold<double>(0, (a, b) => a + b.minuteGoal);
    final hours = days.fold<double>(0, (a, b) => a + b.hours);
    final hourGoal = days.fold<double>(0, (a, b) => a + b.hourGoal);
    final hasData = days.any(
      (d) => d.calories > 0 || d.minutes > 0 || d.hours > 0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VSegmented(
          options: _tabs,
          index: _tab,
          onChanged: (i) => setState(() => _tab = i),
          margin: const EdgeInsets.only(top: 2, bottom: 12),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 80),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          VCard(
            child: Column(
              children: [
                Text('活动数据加载失败', style: VText.value.copyWith(color: v.ink)),
                const SizedBox(height: 6),
                Text(
                  '$_error',
                  textAlign: TextAlign.center,
                  style: VText.label.copyWith(color: v.muted),
                ),
                const SizedBox(height: 10),
                VGhostButton(label: '重试', onTap: _load),
              ],
            ),
          )
        else if (!hasData)
          VCard(
            child: Column(
              children: [
                Icon(
                  Icons.local_fire_department_rounded,
                  size: 34,
                  color: v.muted,
                ),
                const SizedBox(height: 8),
                Text('还没有活动三环数据', style: VText.value.copyWith(color: v.ink)),
                const SizedBox(height: 6),
                Text(
                  '手表同步每日活动汇总后，这里会按今日/本周/本月/本年聚合。',
                  textAlign: TextAlign.center,
                  style: VText.label.copyWith(color: v.muted, height: 1.5),
                ),
              ],
            ),
          )
        else ...[
          VCard(
            background: v.mint,
            foreground: v.mintInk,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Column(
              children: [
                _TripleRings(
                  calories: calories,
                  calorieGoal: calorieGoal,
                  minutes: minutes,
                  minuteGoal: minuteGoal,
                  hours: hours,
                  hourGoal: hourGoal,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _Legend(
                        color: v.warn,
                        label: '活动热量',
                        value: '${fmtInt(calories.round())} kcal',
                        goal: '目标 ${fmtInt(calorieGoal.round())}',
                      ),
                    ),
                    Expanded(
                      child: _Legend(
                        color: v.green,
                        label: '锻炼时长',
                        value: fmtDurationShort(minutes.round() * 60),
                        goal: '目标 ${fmtDurationShort(minuteGoal.round() * 60)}',
                      ),
                    ),
                    Expanded(
                      child: _Legend(
                        color: v.blue,
                        label: '活动小时',
                        value: '${_num(hours)} 小时',
                        goal: '目标 ${_num(hourGoal)}',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const VSectionHead(title: '活动热量 · kcal'),
          VCard(
            child: _ActivityBars(buckets: buckets, color: v.warn),
          ),
          const VSectionHead(title: '明细'),
          VCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final bucket in buckets.reversed)
                  _BucketRow(bucket: bucket),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        VCard(
          background: v.tintGrey,
          child: Text(
            '官方三环来自手表每日汇总，只有完整的天才会下发；当天还没有官方块时，热量和锻炼时长用本机每日汇总兜底。',
            style: VText.label.copyWith(color: v.muted, height: 1.55),
          ),
        ),
      ],
    );
  }
}

class _TripleRings extends StatelessWidget {
  const _TripleRings({
    required this.calories,
    required this.calorieGoal,
    required this.minutes,
    required this.minuteGoal,
    required this.hours,
    required this.hourGoal,
  });

  final double calories;
  final double calorieGoal;
  final double minutes;
  final double minuteGoal;
  final double hours;
  final double hourGoal;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return SizedBox(
      width: 230,
      height: 230,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(230),
            painter: _TripleRingPainter(
              calories: calories,
              calorieGoal: calorieGoal,
              minutes: minutes,
              minuteGoal: minuteGoal,
              hours: hours,
              hourGoal: hourGoal,
              track: v.mintInk.withValues(alpha: 0.12),
              calorieColor: v.warn,
              minuteColor: v.green,
              hourColor: v.blue,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fmtInt(calories.round()),
                style: VText.num.copyWith(fontSize: 34, color: v.mintInk),
              ),
              Text(
                '活动热量 kcal',
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: v.mintInk.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TripleRingPainter extends CustomPainter {
  _TripleRingPainter({
    required this.calories,
    required this.calorieGoal,
    required this.minutes,
    required this.minuteGoal,
    required this.hours,
    required this.hourGoal,
    required this.track,
    required this.calorieColor,
    required this.minuteColor,
    required this.hourColor,
  });

  final double calories;
  final double calorieGoal;
  final double minutes;
  final double minuteGoal;
  final double hours;
  final double hourGoal;
  final Color track;
  final Color calorieColor;
  final Color minuteColor;
  final Color hourColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final base = math.min(size.width, size.height) / 2 - 13;
    void draw(double radius, double value, double goal, Color color) {
      final bg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..color = track;
      final fg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..color = color;
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, bg);
      if (goal <= 0) return;
      final fraction = (value / goal).clamp(0.0, 1.0);
      if (fraction <= 0) return;
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false, fg);
    }

    draw(base, calories, calorieGoal, calorieColor);
    draw(base - 22, minutes, minuteGoal, minuteColor);
    draw(base - 44, hours, hourGoal, hourColor);
  }

  @override
  bool shouldRepaint(covariant _TripleRingPainter old) =>
      old.calories != calories ||
      old.calorieGoal != calorieGoal ||
      old.minutes != minutes ||
      old.minuteGoal != minuteGoal ||
      old.hours != hours ||
      old.hourGoal != hourGoal ||
      old.track != track;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.value,
    required this.goal,
  });

  final Color color;
  final String label;
  final String value;
  final String goal;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Column(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: VText.label.copyWith(
            fontSize: 9.5,
            color: v.mintInk.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: VText.label.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: v.mintInk,
          ),
        ),
        Text(
          goal,
          style: VText.label.copyWith(
            fontSize: 8.5,
            color: v.mintInk.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }
}

class _ActivityBars extends StatefulWidget {
  const _ActivityBars({required this.buckets, required this.color});

  final List<_RingBucket> buckets;
  final Color color;

  @override
  State<_ActivityBars> createState() => _ActivityBarsState();
}

class _ActivityBarsState extends State<_ActivityBars> {
  int? _selected;

  void _select(double dx, double width) {
    final count = widget.buckets.length;
    if (count == 0) return;
    final index = (dx / math.max(1, width) * count).floor().clamp(0, count - 1);
    if (index != _selected) setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final buckets = widget.buckets;
    if (buckets.isEmpty) {
      return Text('暂无数据', style: VText.label.copyWith(color: v.muted));
    }
    final maxValue = buckets.fold<double>(0, (a, b) => math.max(a, b.calories));
    final selected = _selected != null && _selected! < buckets.length
        ? buckets[_selected!]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          child: selected == null
              ? Text(
                  '点柱子查看日期和数值',
                  key: const ValueKey('hint'),
                  style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                )
              : Text(
                  '${selected.label} · ${fmtInt(selected.calories.round())} kcal'
                  '${selected.days > 1 ? ' · ${selected.officialDays}/${selected.days} 天官方' : ''}',
                  key: ValueKey('${selected.label}${selected.calories}'),
                  style: VText.label.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: v.ink,
                  ),
                ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 116,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _select(d.localPosition.dx, width),
                onHorizontalDragUpdate: (d) =>
                    _select(d.localPosition.dx, width),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < buckets.length; i++) ...[
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              constraints: const BoxConstraints(maxWidth: 18),
                              width: double.infinity,
                              height: maxValue <= 0
                                  ? 3
                                  : 6 +
                                        86 *
                                            (buckets[i].calories / maxValue)
                                                .clamp(0.0, 1.0),
                              decoration: BoxDecoration(
                                color: i == _selected
                                    ? widget.color
                                    : widget.color.withValues(
                                        alpha: v.isDark ? 0.45 : 0.28,
                                      ),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (i != buckets.length - 1)
                        SizedBox(width: buckets.length > 16 ? 2 : 5),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              buckets.first.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
            const Spacer(),
            Text(
              buckets.last.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
          ],
        ),
      ],
    );
  }
}

class _BucketRow extends StatelessWidget {
  const _BucketRow({required this.bucket});

  final _RingBucket bucket;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: bucket.officialDays > 0 ? v.green : v.muted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bucket.label,
                  style: VText.label.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: v.ink,
                  ),
                ),
                Text(
                  bucket.days > 1
                      ? '${bucket.officialDays}/${bucket.days} 天有官方三环'
                      : bucket.officialDays > 0
                      ? '官方三环'
                      : '本机汇总',
                  style: VText.label.copyWith(fontSize: 9, color: v.muted),
                ),
              ],
            ),
          ),
          Text(
            '${fmtInt(bucket.calories.round())} kcal',
            style: VText.label.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: v.warn,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            fmtDurationShort(bucket.minutes.round() * 60),
            style: VText.label.copyWith(fontSize: 10, color: v.ink2),
          ),
          const SizedBox(width: 10),
          Text(
            '${_num(bucket.hours)}h',
            style: VText.label.copyWith(fontSize: 10, color: v.ink2),
          ),
        ],
      ),
    );
  }
}

int _epochDay(DateTime date) => date.difference(DateTime(1970)).inDays;

String _num(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
