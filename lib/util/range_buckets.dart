import '../src/rust/api/types.dart';

const rangeLabels = ['日', '周', '月', '半年', '年'];
const rangeDays = [1, 7, 30, 182, 365];

class RangeBucket {
  const RangeBucket({
    required this.start,
    required this.value,
    required this.label,
  });

  final DateTime start;
  final double value;
  final String label;
}

DateTime epochDayToDate(int day) =>
    DateTime(1970, 1, 1).add(Duration(days: day));

/// 周/月保持逐日，半年按自然周合并，年按自然月合并。
/// 桶要铺满整个窗口：只按有数据的日子出桶，「近 30 天」的标题下面会配一条只有两天的横轴。
List<RangeBucket> bucketSeries(
  List<DailyPoint> points,
  int rangeIndex, {
  bool sum = false,
}) {
  final today = _dayStart(DateTime.now());
  final from = today.subtract(Duration(days: rangeDays[rangeIndex] - 1));
  if (rangeIndex <= 2) {
    final byDay = {
      for (final p in points)
        _dayStart(epochDayToDate(p.dateEpochDay)): p.value,
    };
    return [
      for (var d = from; !d.isAfter(today); d = d.add(const Duration(days: 1)))
        RangeBucket(start: d, value: byDay[d] ?? 0, label: dayLabel(d)),
    ];
  }
  final groups = <int, List<double>>{};
  final starts = <int, DateTime>{};
  for (final p in points) {
    final key = _groupKey(epochDayToDate(p.dateEpochDay), rangeIndex);
    (starts[key] ??= _groupStart(epochDayToDate(p.dateEpochDay), rangeIndex));
    groups.putIfAbsent(key, () => []).add(p.value);
  }
  for (var d = from; !d.isAfter(today); d = d.add(const Duration(days: 1))) {
    final key = _groupKey(d, rangeIndex);
    starts[key] ??= _groupStart(d, rangeIndex);
    groups[key] ??= const [];
  }
  final keys = groups.keys.toList()..sort();
  return [
    for (final key in keys)
      RangeBucket(
        start: starts[key]!,
        value: groups[key]!.isEmpty
            ? 0
            : sum
            ? groups[key]!.fold(0.0, (a, b) => a + b)
            : groups[key]!.reduce((a, b) => a + b) / groups[key]!.length,
        label: rangeIndex == 4
            ? '${starts[key]!.month}月'
            : dayLabel(starts[key]!),
      ),
  ];
}

DateTime _dayStart(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _groupStart(DateTime date, int rangeIndex) => rangeIndex == 3
    ? _dayStart(date).subtract(Duration(days: date.weekday - 1))
    : DateTime(date.year, date.month, 1);

int _groupKey(DateTime date, int rangeIndex) {
  final start = _groupStart(date, rangeIndex);
  return start.year * 10000 + start.month * 100 + start.day;
}

String dayLabel(DateTime date) => '${date.month}/${date.day}';
