import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/ui/screens/sleep/sleep_data.dart';

void main() {
  group('NightSleepData', () {
    test('normalizes stages and calculates night metrics', () {
      final start = DateTime(2026, 11, 7, 23).millisecondsSinceEpoch;
      final summary = SleepSummary(
        dateEpochDay: 20800,
        totalMinutes: 462,
        deepMinutes: 132,
        lightMinutes: 212,
        remMinutes: 118,
        awakeMinutes: 25,
        napMinutes: 0,
        startMs: start,
        endMs: start + const Duration(hours: 8, minutes: 7).inMilliseconds,
        efficiency: 95,
        score: 88,
      );
      final detail = SleepDetail(
        summary: summary,
        stages: [
          SleepStage(
            startMs: start,
            endMs: start + const Duration(minutes: 8).inMilliseconds,
            stage: 'awake',
          ),
          SleepStage(
            startMs: start + const Duration(minutes: 8).inMilliseconds,
            endMs: start + const Duration(minutes: 38).inMilliseconds,
            stage: 'light',
          ),
          SleepStage(
            startMs: start + const Duration(minutes: 38).inMilliseconds,
            endMs: start + const Duration(minutes: 90).inMilliseconds,
            stage: 'deep',
          ),
          SleepStage(
            startMs: start + const Duration(minutes: 90).inMilliseconds,
            endMs: start + const Duration(minutes: 100).inMilliseconds,
            stage: 'awake',
          ),
          SleepStage(
            startMs: start + const Duration(minutes: 100).inMilliseconds,
            endMs: start + const Duration(hours: 8, minutes: 7).inMilliseconds,
            stage: 'rem',
          ),
        ],
        chartStartMs: start,
        chartEndMs: start + const Duration(hours: 8, minutes: 7).inMilliseconds,
      );

      final data = NightSleepData.fromDetail(detail);

      expect(data.bands, hasLength(5));
      expect(data.spanMinutes, 487);
      expect(data.inBedMinutes, 487);
      expect(data.awakenings, 2);
      expect(data.longestSleepBand, 387);
      expect(data.deepShare, closeTo(132 / 487, 0.0001));
    });

    test('clips stages to the chart window', () {
      final start = DateTime(2026, 11, 7, 23).millisecondsSinceEpoch;
      final summary = SleepSummary(
        dateEpochDay: 20800,
        totalMinutes: 60,
        deepMinutes: 20,
        lightMinutes: 20,
        remMinutes: 20,
        awakeMinutes: 0,
        napMinutes: 0,
        startMs: start,
        endMs: start + const Duration(hours: 1).inMilliseconds,
        efficiency: 100,
        score: 80,
      );
      final detail = SleepDetail(
        summary: summary,
        stages: [
          SleepStage(
            startMs: start - const Duration(minutes: 10).inMilliseconds,
            endMs: start + const Duration(minutes: 30).inMilliseconds,
            stage: 'light',
          ),
          SleepStage(
            startMs: start + const Duration(minutes: 30).inMilliseconds,
            endMs: start + const Duration(minutes: 80).inMilliseconds,
            stage: 'deep',
          ),
        ],
        chartStartMs: start,
        chartEndMs: start + const Duration(hours: 1).inMilliseconds,
      );

      final data = NightSleepData.fromDetail(detail);

      expect(data.bands.first.startMs, start);
      expect(data.bands.last.endMs, detail.chartEndMs);
    });
  });

  test('SleepPeriodData builds a gap-aware fixed trend window', () {
    final today = DateTime.now();
    final epochDay = DateTime(
      today.year,
      today.month,
      today.day,
    ).difference(DateTime(1970, 1, 1)).inDays;
    final data = SleepPeriodData.fromSeries(
      rangeIndex: 1,
      total: [DailyPoint(dateEpochDay: epochDay, value: 420)],
      deep: [DailyPoint(dateEpochDay: epochDay, value: 95)],
      rem: [DailyPoint(dateEpochDay: epochDay, value: 96)],
      awake: [DailyPoint(dateEpochDay: epochDay, value: 20)],
    );

    expect(data.nights, 1);
    expect(data.trend, hasLength(7));
    expect(data.trend.last.hasData, isTrue);
    expect(data.trend.last.lightMinutes, 229);
    expect(data.efficiency, 95);
  });
}
