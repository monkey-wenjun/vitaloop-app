import '../../../src/rust/api/types.dart';
import '../../../util/range_buckets.dart';

enum SleepStageKind { awake, rem, light, deep }

SleepStageKind? sleepStageKindFrom(String value) => switch (value) {
  'awake' => SleepStageKind.awake,
  'rem' => SleepStageKind.rem,
  'light' => SleepStageKind.light,
  'deep' => SleepStageKind.deep,
  _ => null,
};

class SleepBand {
  const SleepBand({
    required this.kind,
    required this.startMs,
    required this.endMs,
  });

  final SleepStageKind kind;
  final int startMs;
  final int endMs;

  int get durationMinutes => ((endMs - startMs) / 60000).round();
}

class NightSleepData {
  const NightSleepData({
    required this.detail,
    required this.bands,
    required this.startMs,
    required this.endMs,
  });

  factory NightSleepData.fromDetail(SleepDetail detail) {
    final start = detail.chartStartMs.toInt();
    final end = detail.chartEndMs.toInt();
    final bands = <SleepBand>[
      for (final stage in detail.stages)
        if (sleepStageKindFrom(stage.stage) case final kind?)
          if (stage.endMs.toInt().clamp(start, end) >
              stage.startMs.toInt().clamp(start, end))
            SleepBand(
              kind: kind,
              startMs: stage.startMs.toInt().clamp(start, end),
              endMs: stage.endMs.toInt().clamp(start, end),
            ),
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    return NightSleepData(
      detail: detail,
      bands: bands,
      startMs: start,
      endMs: end,
    );
  }

  final SleepDetail detail;
  final List<SleepBand> bands;
  final int startMs;
  final int endMs;

  SleepSummary get summary => detail.summary;
  int get spanMinutes => ((endMs - startMs) / 60000).round();
  int get inBedMinutes => summary.totalMinutes + summary.awakeMinutes;
  int get awakenings =>
      bands.where((band) => band.kind == SleepStageKind.awake).length;
  double get deepShare =>
      inBedMinutes <= 0 ? 0 : summary.deepMinutes / inBedMinutes;

  int get longestSleepBand {
    var longest = 0;
    for (final band in bands) {
      if (band.kind != SleepStageKind.awake) {
        final duration = band.durationMinutes;
        if (duration > longest) longest = duration;
      }
    }
    return longest;
  }
}

class SleepPeriodData {
  const SleepPeriodData({
    required this.rangeIndex,
    required this.nights,
    required this.avgTotal,
    required this.avgDeep,
    required this.avgRem,
    required this.avgAwake,
    required this.trend,
  });

  factory SleepPeriodData.fromSeries({
    required int rangeIndex,
    required List<DailyPoint> total,
    required List<DailyPoint> deep,
    required List<DailyPoint> rem,
    required List<DailyPoint> awake,
  }) {
    double average(List<DailyPoint> points) => points.isEmpty
        ? 0
        : points.fold<double>(0, (sum, point) => sum + point.value) /
              points.length;

    final totalByDay = {for (final p in total) p.dateEpochDay: p.value};
    final deepByDay = {for (final p in deep) p.dateEpochDay: p.value};
    final remByDay = {for (final p in rem) p.dateEpochDay: p.value};
    final awakeByDay = {for (final p in awake) p.dateEpochDay: p.value};
    final today = DateTime.now();
    final from = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: rangeDays[rangeIndex] - 1));

    final trend = <SleepTrendPoint>[];
    for (var i = 0; i < rangeDays[rangeIndex]; i++) {
      final date = from.add(Duration(days: i));
      final epochDay = date.difference(DateTime(1970, 1, 1)).inDays;
      final totalMinutes = totalByDay[epochDay] ?? 0;
      final deepMinutes = deepByDay[epochDay] ?? 0;
      final remMinutes = remByDay[epochDay] ?? 0;
      final awakeMinutes = awakeByDay[epochDay] ?? 0;
      trend.add(
        SleepTrendPoint(
          date: date,
          totalMinutes: totalMinutes,
          deepMinutes: deepMinutes,
          remMinutes: remMinutes,
          awakeMinutes: awakeMinutes,
          hasData:
              totalMinutes > 0 ||
              deepMinutes > 0 ||
              remMinutes > 0 ||
              awakeMinutes > 0,
        ),
      );
    }

    return SleepPeriodData(
      rangeIndex: rangeIndex,
      nights: total.length,
      avgTotal: average(total),
      avgDeep: average(deep),
      avgRem: average(rem),
      avgAwake: average(awake),
      trend: trend,
    );
  }

  final int rangeIndex;
  final int nights;
  final double avgTotal;
  final double avgDeep;
  final double avgRem;
  final double avgAwake;
  final List<SleepTrendPoint> trend;

  double get avgLight =>
      (avgTotal - avgDeep - avgRem).clamp(0, double.infinity);
  double get avgInBed => avgTotal + avgAwake;
  int get efficiency => avgInBed <= 0 ? 0 : (avgTotal / avgInBed * 100).round();
  double get deepShare => avgInBed <= 0 ? 0 : avgDeep / avgInBed;
}

class SleepTrendPoint {
  const SleepTrendPoint({
    required this.date,
    required this.totalMinutes,
    required this.deepMinutes,
    required this.remMinutes,
    required this.awakeMinutes,
    required this.hasData,
  });

  final DateTime date;
  final double totalMinutes;
  final double deepMinutes;
  final double remMinutes;
  final double awakeMinutes;
  final bool hasData;

  double get lightMinutes =>
      (totalMinutes - deepMinutes - remMinutes).clamp(0, double.infinity);
}
