enum DynamicsGrade {
  excellent('优秀'),
  good('良好'),
  average('一般'),
  high('偏高');

  const DynamicsGrade(this.label);

  final String label;
}

class DynamicsAssessment {
  const DynamicsAssessment({
    required this.grade,
    required this.headline,
    required this.advice,
  });

  final DynamicsGrade grade;
  final String headline;
  final String advice;
}

DynamicsAssessment? assessRunningDynamics({
  required String label,
  required double average,
}) {
  if (label == '垂直振幅') return assessVerticalOscillation(average);
  if (label == '左右触地平衡') return assessGroundContactBalance(average);
  return null;
}

/// 常见跑步动态参考区间，用于趋势观察，不作伤病判断。
DynamicsAssessment assessVerticalOscillation(double averageCm) {
  if (averageCm <= 8) {
    return const DynamicsAssessment(
      grade: DynamicsGrade.excellent,
      headline: '重心起伏较小',
      advice: '跑步经济性较好，继续保持放松落地。',
    );
  }
  if (averageCm <= 10) {
    return const DynamicsAssessment(
      grade: DynamicsGrade.good,
      headline: '处于常见范围',
      advice: '可结合步频和触地时间一起观察。',
    );
  }
  if (averageCm <= 12) {
    return const DynamicsAssessment(
      grade: DynamicsGrade.average,
      headline: '重心起伏偏大',
      advice: '尝试提高步频、减少向上发力。',
    );
  }
  return const DynamicsAssessment(
    grade: DynamicsGrade.high,
    headline: '垂直振幅明显偏高',
    advice: '优先关注放松下落和步频稳定性。',
  );
}

/// 左右触地平衡以左腿占比表示；偏差 = |左腿占比 - 50%|。
DynamicsAssessment assessGroundContactBalance(double leftPct) {
  final difference = (leftPct - 50).abs();
  final side = leftPct > 50
      ? '偏左'
      : leftPct < 50
      ? '偏右'
      : '均衡';
  if (difference <= 1) {
    return const DynamicsAssessment(
      grade: DynamicsGrade.excellent,
      headline: '左右基本均衡',
      advice: '当前触地分配稳定。',
    );
  }
  if (difference <= 2) {
    return DynamicsAssessment(
      grade: DynamicsGrade.good,
      headline: '轻度$side',
      advice: '偏差较小，继续观察长距离后的变化。',
    );
  }
  if (difference <= 3) {
    return DynamicsAssessment(
      grade: DynamicsGrade.average,
      headline: '$side较明显',
      advice: '结合疲劳和力量左右差异一起判断。',
    );
  }
  return DynamicsAssessment(
    grade: DynamicsGrade.high,
    headline: '$side偏差较大',
    advice: '建议回顾跑姿、力量平衡和近期疲劳。',
  );
}
