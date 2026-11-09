String fmtInt(num value) {
  final n = value.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) buf.write(',');
    buf.write(n[i]);
  }
  return buf.toString();
}

String fmtDuration(int seconds) {
  if (seconds <= 0) return '0:00';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String fmtDurationShort(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h${m.toString().padLeft(2, '0')}';
  return '${m}min';
}

String fmtSleep(int? minutes) {
  if (minutes == null) return '--';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h}h${m.toString().padLeft(2, '0')}';
}

String fmtDistance(num meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
  return '${meters.round()} m';
}

String fmtPace(num meters, int seconds) {
  if (meters <= 0 || seconds <= 0) return '--';
  final secPerKm = seconds / (meters / 1000);
  final m = secPerKm ~/ 60;
  final s = (secPerKm % 60).round();
  return "$m'${s.toString().padLeft(2, '0')}\"";
}

String two(int value) => value.toString().padLeft(2, '0');

const weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

String weekday(DateTime d) => weekdayNames[d.weekday - 1];

String monthDay(DateTime d) => '${d.month}月${d.day}日';

String monthDayShort(DateTime d) => '${d.month}/${two(d.day)}';

String clock(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

String relativeDay(DateTime d, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final a = DateTime(d.year, d.month, d.day);
  final b = DateTime(today.year, today.month, today.day);
  final diff = b.difference(a).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff == 2) return '前天';
  if (diff < 7) return weekday(d);
  return monthDayShort(d);
}

String sportName(String sport) => switch (sport) {
  // 手机端手动记录直接存中文项目名，和手表同步的英文 sport 混在同一张表里。
  'outdoor_run' || 'running' || 'trail_running' || '户外跑步' => '户外跑步',
  'indoor_run' || 'treadmill' || '室内跑步' => '室内跑步',
  'cycling' || 'indoor_cycling' || 'spinning' || '骑行' => '骑行',
  'walk' || 'walking' || '健走' => '健走',
  'hiking' || '徒步' => '徒步',
  'strength' || 'free_training' || 'core' || '力量训练' => '力量训练',
  'swim' || 'swimming' || '游泳' => '游泳',
  'climbing' || '登山' => '登山',
  'elliptical' => '椭圆机',
  'rowing' => '划船',
  'jump_rope' => '跳绳',
  'stretching' => '拉伸',
  'yoga' => '瑜伽',
  'pilates' => '普拉提',
  'dance' => '舞蹈',
  'hiit' => 'HIIT',
  'stepper' => '踏步机',
  'walker' => '漫步机',
  _ => '运动',
};

String sportEmoji(String sport) => switch (sport) {
  'cycling' || 'indoor_cycling' || 'spinning' || '骑行' => '🚴',
  'strength' || 'free_training' || 'core' || '力量训练' => '🏋️',
  'hiking' || 'climbing' || '徒步' => '🥾',
  'walk' || 'walking' || '健走' => '🚶',
  'swim' || 'swimming' || '游泳' => '🏊',
  _ => '🏃',
};

/// 手表情绪状态码的实测含义（旧库 2136 条，只出现 1/2/3）：
/// 1 = 愉悦度 2.5 / 激活度 89.8，2 = 33.9 / 39.5，3 = 88.3 / 7.2。
/// 也就是状态码沿愉悦度升、沿激活度降：3 是最平静愉悦的一档，不是「兴奋」；
/// 1 是又低愉悦又高兴奋，对应紧张/焦虑，不是「平静」。
String emotionLabel(int status) => switch (status) {
  1 => '紧张',
  2 => '一般',
  3 => '平静',
  _ => '状态 $status',
};

/// -1 偏消极 / 0 中性 / 1 偏积极。
int emotionPolarity(int status) => switch (status) {
  1 => -1,
  3 => 1,
  _ => 0,
};

/// 手表心律筛查结果码：1 正常窦性心律，2/3 疑似早搏/房颤，4/5 风险提醒。
String arrhythmiaLabel(int type) => switch (type) {
  1 => '正常',
  2 => '疑似早搏',
  3 => '疑似房颤',
  4 => '房颤风险',
  5 => '早搏风险',
  _ => '未知',
};

String greeting(DateTime now) {
  final h = now.hour;
  if (h < 6) return '夜深了';
  if (h < 11) return '早上好';
  if (h < 14) return '中午好';
  if (h < 18) return '下午好';
  return '晚上好';
}

/// 按生日算周岁；生日缺失或格式不对返回 0。
int ageFromBirthDate(String? birthDate) {
  final d = DateTime.tryParse(birthDate ?? '');
  if (d == null) return 0;
  final now = DateTime.now();
  var age = now.year - d.year;
  if (now.month < d.month || (now.month == d.month && now.day < d.day)) age--;
  return age;
}

/// 最大心率估算：220 − 年龄；年龄缺失时退回 188。
int estimatedMaxHr(String? birthDate) {
  final age = ageFromBirthDate(birthDate);
  return age > 0 ? 220 - age : 188;
}

/// 基础代谢（Mifflin-St Jeor），单位 kcal/天。
/// 档案不全时返回 0，调用方就不要把基础代谢算进总消耗。
int basalMetabolicRate({
  required double weightKg,
  required double heightCm,
  required int age,
  required String gender,
}) {
  if (weightKg <= 0 || heightCm <= 0 || age <= 0) return 0;
  final base = 10 * weightKg + 6.25 * heightCm - 5 * age;
  final bmr = gender == 'female' ? base - 161 : base + 5;
  return bmr <= 0 ? 0 : bmr.round();
}
