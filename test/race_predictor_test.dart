import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/util/race_predictor.dart';

PersonalRecord _record(String metric, String label, double value) {
  return PersonalRecord(
    sport: 'running',
    metric: metric,
    label: label,
    value: value,
    unit: '秒',
    workoutId: 'w1',
    achievedMs: 0,
  );
}

void main() {
  test('没有跑步纪录时不预估', () {
    expect(predictRace(const [], 21.0975), isNull);
    expect(
      predictRace([_record('longest', '最远距离', 10)], 21.0975),
      isNull,
    );
  });

  test('半马用最近的 10K 成绩按 Riegel 外推', () {
    final prediction = predictRace([
      _record('5k', '5 公里最好成绩', 1200),
      _record('10k', '10 公里最好成绩', 3000),
    ], 21.0975);
    expect(prediction, isNotNull);
    expect(prediction!.sourceMetric, '10k');
    expect(prediction.timeSec, 6619);
    expect(prediction.sourceKm, 10);
  });

  test('全马优先使用半马成绩而不是更远的 10K', () {
    final prediction = predictRace([
      _record('10k', '10 公里最好成绩', 3000),
      _record('half', '半马最好成绩', 7200),
    ], 42.195);
    expect(prediction, isNotNull);
    expect(prediction!.sourceMetric, 'half');
    expect(prediction.sourceSec, 7200);
    expect(prediction.timeSec, 15085);
  });
}
