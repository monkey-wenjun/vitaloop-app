/// 旧版 BloodPressureScreen / BloodGlucoseScreen 的参考标准。
///
/// 只放纯计算和静态表格，UI 和单元测试共用同一套边界，避免把阈值写死在
/// 两个地方后慢慢漂移。
library;

enum BpLevel { normal, elevated, stage1, stage2 }

class BpReferenceRow {
  const BpReferenceRow({
    required this.label,
    required this.systolic,
    required this.diastolic,
    required this.level,
  });

  final String label;
  final String systolic;
  final String diastolic;
  final BpLevel level;
}

const bpReferenceRows = <BpReferenceRow>[
  BpReferenceRow(
    label: '正常',
    systolic: '<120',
    diastolic: '<80',
    level: BpLevel.normal,
  ),
  BpReferenceRow(
    label: '偏高',
    systolic: '120-129',
    diastolic: '<80',
    level: BpLevel.elevated,
  ),
  BpReferenceRow(
    label: '高血压1级',
    systolic: '130-139',
    diastolic: '80-89',
    level: BpLevel.stage1,
  ),
  BpReferenceRow(
    label: '高血压2级',
    systolic: '≥140',
    diastolic: '≥90',
    level: BpLevel.stage2,
  ),
];

/// 收缩压/舒张压分级。任一指标达到更高一级就按更高的算。
BpLevel bpLevel(int systolic, int diastolic) {
  if (systolic >= 140 || diastolic >= 90) return BpLevel.stage2;
  if (systolic >= 130 || diastolic >= 80) return BpLevel.stage1;
  if (systolic >= 120) return BpLevel.elevated;
  return BpLevel.normal;
}

String bpLevelLabel(BpLevel level) => switch (level) {
  BpLevel.normal => '正常',
  BpLevel.elevated => '偏高',
  BpLevel.stage1 => '高血压1级',
  BpLevel.stage2 => '高血压2级',
};

enum BmiLevel { underweight, normal, overweight, obese }

class BmiReferenceRow {
  const BmiReferenceRow({
    required this.label,
    required this.range,
    required this.level,
  });

  final String label;
  final String range;
  final BmiLevel level;
}

const bmiReferenceRows = <BmiReferenceRow>[
  BmiReferenceRow(label: '偏瘦', range: '< 18.5', level: BmiLevel.underweight),
  BmiReferenceRow(label: '正常', range: '18.5 - 23.9', level: BmiLevel.normal),
  BmiReferenceRow(
    label: '偏胖',
    range: '24.0 - 27.9',
    level: BmiLevel.overweight,
  ),
  BmiReferenceRow(label: '肥胖', range: '≥ 28.0', level: BmiLevel.obese),
];

BmiLevel bmiLevel(double bmi) {
  if (bmi < 18.5) return BmiLevel.underweight;
  if (bmi < 24.0) return BmiLevel.normal;
  if (bmi < 28.0) return BmiLevel.overweight;
  return BmiLevel.obese;
}

String bmiLevelLabel(BmiLevel level) => switch (level) {
  BmiLevel.underweight => '偏瘦',
  BmiLevel.normal => '正常',
  BmiLevel.overweight => '偏胖',
  BmiLevel.obese => '肥胖',
};

enum GlucoseStandard { fasting, afterMeal }

enum GlucoseLevel { low, normal, impaired, diabetes }

class GlucoseReferenceRow {
  const GlucoseReferenceRow({
    required this.label,
    required this.range,
    required this.level,
  });

  final String label;
  final String range;
  final GlucoseLevel level;
}

const fastingGlucoseRows = <GlucoseReferenceRow>[
  GlucoseReferenceRow(
    label: '正常',
    range: '3.9 - 6.1',
    level: GlucoseLevel.normal,
  ),
  GlucoseReferenceRow(
    label: '空腹血糖受损',
    range: '6.1 - 7.0',
    level: GlucoseLevel.impaired,
  ),
  GlucoseReferenceRow(
    label: '糖尿病',
    range: '≥7.0',
    level: GlucoseLevel.diabetes,
  ),
];

const afterMealGlucoseRows = <GlucoseReferenceRow>[
  GlucoseReferenceRow(label: '正常', range: '<7.8', level: GlucoseLevel.normal),
  GlucoseReferenceRow(
    label: '糖耐量减低',
    range: '7.8 - 11.1',
    level: GlucoseLevel.impaired,
  ),
  GlucoseReferenceRow(
    label: '糖尿病',
    range: '≥11.1',
    level: GlucoseLevel.diabetes,
  ),
];

/// 空腹、餐前、睡前都用空腹标准；只有「餐后」用餐后 2 小时标准。
/// 「随机」没有可对照的时点，返回 null，不强行分级。
GlucoseStandard? glucoseStandardFor(String measureType) =>
    switch (measureType) {
      'fasting' || 'before_meal' || 'bedtime' => GlucoseStandard.fasting,
      'after_meal' => GlucoseStandard.afterMeal,
      _ => null,
    };

GlucoseLevel? glucoseLevel(double value, String measureType) {
  final standard = glucoseStandardFor(measureType);
  if (standard == null) return null;
  if (standard == GlucoseStandard.fasting) {
    if (value < 3.9) return GlucoseLevel.low;
    if (value < 6.1) return GlucoseLevel.normal;
    if (value < 7.0) return GlucoseLevel.impaired;
    return GlucoseLevel.diabetes;
  }
  if (value < 7.8) return GlucoseLevel.normal;
  if (value < 11.1) return GlucoseLevel.impaired;
  return GlucoseLevel.diabetes;
}

String? glucoseLevelLabel(double value, String measureType) {
  final level = glucoseLevel(value, measureType);
  final standard = glucoseStandardFor(measureType);
  if (level == null || standard == null) return null;
  return switch (level) {
    GlucoseLevel.low => '偏低',
    GlucoseLevel.normal => '正常',
    GlucoseLevel.impaired =>
      standard == GlucoseStandard.fasting ? '空腹血糖受损' : '糖耐量减低',
    GlucoseLevel.diabetes => '糖尿病',
  };
}
