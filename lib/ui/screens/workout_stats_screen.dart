import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/range_buckets.dart';
import '../components.dart';
import '../nav.dart';

/// 运动数据统计：按 日/周/月/半年/年 维度聚合运动记录（参考华为运动健康「数据统计」）。
class WorkoutStatsScreen extends StatefulWidget {
  const WorkoutStatsScreen({
    super.key,
    required this.workouts,
    this.bmrPerDay = 0,
  });

  final List<WorkoutSummary> workouts;

  /// 基础代谢 kcal/天。旧版统计页的「消耗」包含基础代谢，这里保持一致；
  /// 档案不全时为 0，只显示运动消耗。
  final int bmrPerDay;

  @override
  State<WorkoutStatsScreen> createState() => _WorkoutStatsScreenState();
}

class _StatsBucket {
  const _StatsBucket({
    required this.start,
    required this.label,
    required this.count,
    required this.distanceM,
    required this.seconds,
    required this.calories,
  });

  final DateTime start;
  final String label;
  final int count;
  final double distanceM;
  final int seconds;
  final int calories;
}

class _WorkoutStatsScreenState extends State<WorkoutStatsScreen> {
  int _range = 0;
  late DateTime _calMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _selectedDay;

  /// (窗口标题, 窗口天数, 分桶方式) 分桶：0=按天 1=按自然周 2=按自然月
  static const _configs = [
    ('近 7 天', 7, 0),
    ('近 4 周', 28, 1),
    ('近 6 个月', 182, 2),
    ('近半年', 182, 1),
    ('近一年', 365, 2),
  ];

  List<_StatsBucket> _buckets() {
    final (_, windowDays, mode) = _configs[_range];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: windowDays - 1));
    final inRange = widget.workouts
        .where(
          (w) =>
              DateTime.fromMillisecondsSinceEpoch(w.startMs)
                  .isAfter(start.subtract(const Duration(milliseconds: 1))),
        )
        .toList();

    // 先把窗口铺满空桶，保证图上能看到没有运动的时间段
    final keys = <int, _StatsBucket>{};
    int basalDays(DateTime bucketStart, DateTime bucketEnd) {
      if (widget.bmrPerDay <= 0) return 0;
      final from = bucketStart.isBefore(start) ? start : bucketStart;
      final to = bucketEnd.isAfter(today) ? today : bucketEnd;
      if (to.isBefore(from)) return 0;
      return to.difference(from).inDays + 1;
    }

    void touch(DateTime day, String label) {
      final key = day.year * 10000 + day.month * 100 + day.day;
      final end = switch (mode) {
        0 => day,
        1 => day.add(const Duration(days: 6)),
        _ => DateTime(day.year, day.month + 1, 0),
      };
      keys.putIfAbsent(
        key,
        () => _StatsBucket(
          start: day,
          label: label,
          count: 0,
          distanceM: 0,
          seconds: 0,
          calories: widget.bmrPerDay * basalDays(day, end),
        ),
      );
    }

    if (mode == 0) {
      for (var i = 0; i < windowDays; i++) {
        final d = start.add(Duration(days: i));
        touch(d, dayLabel(d));
      }
    } else if (mode == 1) {
      var ws = start.subtract(Duration(days: start.weekday - 1));
      while (!ws.isAfter(now)) {
        touch(ws, dayLabel(ws));
        ws = ws.add(const Duration(days: 7));
      }
    } else {
      var ms = DateTime(start.year, start.month, 1);
      while (!ms.isAfter(now)) {
        touch(
          ms,
          ms.year == now.year
              ? '${ms.month}月'
              : '${ms.year % 100}年${ms.month}月',
        );
        ms = DateTime(ms.year, ms.month + 1, 1);
      }
    }

    for (final w in inRange) {
      final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      final bucketStart = switch (mode) {
        0 => DateTime(d.year, d.month, d.day),
        1 => d.subtract(Duration(days: d.weekday - 1)),
        _ => DateTime(d.year, d.month, 1),
      };
      final key =
          bucketStart.year * 10000 + bucketStart.month * 100 + bucketStart.day;
      final b = keys[key];
      if (b == null) continue;
      keys[key] = _StatsBucket(
        start: b.start,
        label: b.label,
        count: b.count + 1,
        distanceM: b.distanceM + w.distanceM,
        seconds: b.seconds + w.durationSec,
        calories: b.calories + w.calories,
      );
    }
    final list = keys.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  ({int count, double km, int seconds, int calories}) _totalsSince(
    DateTime start,
  ) {
    var count = 0;
    var km = 0.0;
    var seconds = 0;
    var calories = 0;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final w in widget.workouts) {
      final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      if (d.isBefore(start)) continue;
      count++;
      km += w.distanceM / 1000;
      seconds += w.durationSec;
      calories += w.calories;
    }
    if (widget.bmrPerDay > 0 && !start.isAfter(today)) {
      calories += widget.bmrPerDay * (today.difference(start).inDays + 1);
    }
    return (count: count, km: km, seconds: seconds, calories: calories);
  }

  Widget _overview(BuildContext context) {
    final v = context.v;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final monthStart = DateTime(now.year, now.month, 1);
    final yearStart = DateTime(now.year, 1, 1);
    final week = _totalsSince(weekStart);
    final month = _totalsSince(monthStart);
    final year = _totalsSince(yearStart);
    Widget col(
      String label,
      ({int count, double km, int seconds, int calories}) t,
    ) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: VText.label.copyWith(fontSize: 10, color: v.muted),
            ),
            const SizedBox(height: 5),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${t.count}',
                    style: VText.value.copyWith(
                      fontSize: 19,
                      color: v.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  TextSpan(
                    text: ' 次',
                    style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${t.km.toStringAsFixed(1)} km · ${fmtDurationShort(t.seconds)}',
              style: VText.label.copyWith(fontSize: 9.5, color: v.ink2),
            ),
          ],
        ),
      );
    }

    return VCard(
      child: Row(
        children: [col('本周', week), col('本月', month), col('本年', year)],
      ),
    );
  }

  Widget _calendar(BuildContext context) {
    final v = context.v;
    final first = DateTime(_calMonth.year, _calMonth.month, 1);
    final days = DateTime(_calMonth.year, _calMonth.month + 1, 0).day;
    final lead = first.weekday - 1;
    final byDay = <int, List<WorkoutSummary>>{};
    for (final w in widget.workouts) {
      final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      if (d.year != _calMonth.year || d.month != _calMonth.month) continue;
      byDay.putIfAbsent(d.day, () => []).add(w);
    }
    final selected = _selectedDay;
    final selectedList = selected == null
        ? const <WorkoutSummary>[]
        : (byDay[selected.day] ?? const []);
    final selectedKm = selectedList.fold<double>(
      0,
      (a, w) => a + w.distanceM / 1000,
    );
    final selectedSec = selectedList.fold<int>(0, (a, w) => a + w.durationSec);
    final selectedKcal = selectedList.fold<int>(0, (a, w) => a + w.calories);

    return VCard(
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => setState(() {
                  _calMonth = DateTime(_calMonth.year, _calMonth.month - 1);
                  _selectedDay = null;
                }),
                icon: Icon(Icons.chevron_left_rounded, color: v.ink2),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_calMonth.year} 年 ${_calMonth.month} 月',
                    style: VText.h3.copyWith(color: v.ink),
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() {
                  _calMonth = DateTime(_calMonth.year, _calMonth.month + 1);
                  _selectedDay = null;
                }),
                icon: Icon(Icons.chevron_right_rounded, color: v.ink2),
              ),
            ],
          ),
          Row(
            children: [
              for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: v.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.92,
            children: [
              for (var i = 0; i < lead; i++) const SizedBox.shrink(),
              for (var day = 1; day <= days; day++)
                _dayCell(context, day, byDay[day] ?? const []),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: v.tintGrey,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                selectedList.isEmpty
                    ? '${selected.month} 月 ${selected.day} 日 · 没有运动记录'
                    : '${selected.month} 月 ${selected.day} 日 · ${selectedList.length} 次 · '
                          '${selectedKm.toStringAsFixed(1)} km · ${fmtDurationShort(selectedSec)} · ${fmtInt(selectedKcal)} kcal',
                style: VText.label.copyWith(color: v.ink2, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayCell(BuildContext context, int day, List<WorkoutSummary> list) {
    final v = context.v;
    final km = list.fold<double>(0, (a, w) => a + w.distanceM / 1000);
    final hasData = list.isNotEmpty;
    final selected =
        _selectedDay?.day == day &&
        _selectedDay?.month == _calMonth.month &&
        _selectedDay?.year == _calMonth.year;
    final alpha = hasData
        ? 0.14 + (km / 20).clamp(0.0, 1.0).toDouble() * 0.5
        : 0.0;
    return GestureDetector(
      key: ValueKey('cal-$day'),
      onTap: () => setState(
        () => _selectedDay = DateTime(_calMonth.year, _calMonth.month, day),
      ),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: hasData ? v.blue.withValues(alpha: alpha) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: v.blueInk, width: 1.4) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: VText.label.copyWith(
                fontSize: 11,
                fontWeight: hasData ? FontWeight.w800 : FontWeight.w500,
                color: hasData ? v.blueInk : v.ink2,
              ),
            ),
            if (hasData)
              Text(
                km.toStringAsFixed(0),
                style: VText.label.copyWith(
                  fontSize: 8,
                  color: v.blueInk.withValues(alpha: 0.8),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final buckets = _buckets();
    final (title, _, _) = _configs[_range];
    final count = buckets.fold<int>(0, (a, b) => a + b.count);
    final distance = buckets.fold<double>(0, (a, b) => a + b.distanceM);
    final seconds = buckets.fold<int>(0, (a, b) => a + b.seconds);
    final calories = buckets.fold<int>(0, (a, b) => a + b.calories);

    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '数据统计'),
            VSegmented(
              options: const ['日', '周', '月', '半年', '年'],
              index: _range,
              onChanged: (i) => setState(() => _range = i),
              margin: const EdgeInsets.only(top: 2, bottom: 12),
            ),
            VCard(
              background: v.mint,
              foreground: v.mintInk,
              padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: VText.h3.copyWith(
                      color: v.mintInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCol(
                          label: '运动',
                          value: '$count',
                          unit: '次',
                          color: v.mintInk,
                        ),
                      ),
                      Expanded(
                        child: _StatCol(
                          label: '距离',
                          value: (distance / 1000).toStringAsFixed(1),
                          unit: 'km',
                          color: v.mintInk,
                        ),
                      ),
                      Expanded(
                        child: _StatCol(
                          label: '时长',
                          value: fmtDurationShort(seconds),
                          unit: '',
                          color: v.mintInk,
                        ),
                      ),
                      Expanded(
                        child: _StatCol(
                          label: '消耗',
                          value: fmtInt(calories),
                          unit: 'kcal',
                          color: v.mintInk,
                        ),
                      ),
                    ],
                  ),
                  if (widget.bmrPerDay > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '消耗含基础代谢 ${fmtInt(widget.bmrPerDay)} kcal/天',
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: v.mintInk.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const VSectionHead(title: '周 / 月 / 年'),
            _overview(context),
            const VSectionHead(title: '运动日历'),
            _calendar(context),
            const VSectionHead(title: '距离 · km'),
            VCard(
              child: VRangeBars(
                buckets: [
                  for (final b in buckets)
                    RangeBucket(
                      start: b.start,
                      value: b.distanceM / 1000,
                      label: b.label,
                    ),
                ],
                color: v.blue,
                height: 88,
              ),
            ),
            const VSectionHead(title: '时长 · 分钟'),
            VCard(
              child: VRangeBars(
                buckets: [
                  for (final b in buckets)
                    RangeBucket(
                      start: b.start,
                      value: b.seconds / 60.0,
                      label: b.label,
                    ),
                ],
                color: v.greenInk,
                height: 88,
              ),
            ),
            VSectionHead(
              title: widget.bmrPerDay > 0 ? '消耗 · kcal（含基础代谢）' : '消耗 · kcal',
            ),
            VCard(
              child: VRangeBars(
                buckets: [
                  for (final b in buckets)
                    RangeBucket(
                      start: b.start,
                      value: b.calories.toDouble(),
                      label: b.label,
                    ),
                ],
                color: v.warnInk,
                height: 88,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCol extends StatelessWidget {
  const _StatCol({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: VText.value.copyWith(
                  fontSize: 19,
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (unit.isNotEmpty)
                TextSpan(
                  text: ' $unit',
                  style: VText.label.copyWith(
                    fontSize: 10,
                    color: color.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: VText.label.copyWith(
            fontSize: 9.5,
            color: color.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
