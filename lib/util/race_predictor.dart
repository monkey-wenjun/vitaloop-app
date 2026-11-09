import 'dart:math' as math;

import '../src/rust/api/types.dart';

/// 用已有的 5K / 10K / 半马 / 全马最好成绩按 Riegel 公式外推。
///
/// T2 = T1 × (D2 / D1)^1.06。选离目标距离最近的那条纪录当基准，
/// 这样外推幅度最小，结果也更可信。
class RacePrediction {
  const RacePrediction({
    required this.targetKm,
    required this.timeSec,
    required this.paceSecPerKm,
    required this.sourceMetric,
    required this.sourceLabel,
    required this.sourceKm,
    required this.sourceSec,
  });

  final double targetKm;
  final int timeSec;
  final int paceSecPerKm;
  final String sourceMetric;
  final String sourceLabel;
  final double sourceKm;
  final int sourceSec;
}

const _riegelExponent = 1.06;

const _sources = [('5k', 5.0), ('10k', 10.0), ('half', 21.0), ('full', 42.0)];

RacePrediction? predictRace(List<PersonalRecord> records, double targetKm) {
  if (targetKm <= 0) return null;
  final running = records.where((r) => r.sport == 'running');
  PersonalRecord? bestRecord;
  double bestSourceKm = 0;
  var bestLogDistance = double.infinity;
  for (final source in _sources) {
    final metric = source.$1;
    final sourceKm = source.$2;
    PersonalRecord? record;
    for (final candidate in running) {
      if (candidate.metric == metric && candidate.value > 0) {
        record = candidate;
        break;
      }
    }
    if (record == null) continue;
    final distance = (math.log(sourceKm / targetKm)).abs();
    if (distance < bestLogDistance) {
      bestLogDistance = distance;
      bestRecord = record;
      bestSourceKm = sourceKm;
    }
  }
  if (bestRecord == null) return null;
  final sourceSec = bestRecord.value.round();
  if (sourceSec <= 0) return null;
  final timeSec =
      (sourceSec * math.pow(targetKm / bestSourceKm, _riegelExponent)).round();
  if (timeSec <= 0) return null;
  return RacePrediction(
    targetKm: targetKm,
    timeSec: timeSec,
    paceSecPerKm: (timeSec / targetKm).round(),
    sourceMetric: bestRecord.metric,
    sourceLabel: bestRecord.label,
    sourceKm: bestSourceKm,
    sourceSec: sourceSec,
  );
}
