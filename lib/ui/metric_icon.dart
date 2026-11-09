import 'package:flutter/material.dart';

/// 指标 → 图标。首页卡片、详情页页头、记录页共用同一张表，
/// 避免同一个指标在两个页面画成两个样子。
IconData metricIcon(String metric) => switch (metric) {
  'steps' => Icons.directions_walk_rounded,
  'calories' || 'active_calories' => Icons.local_fire_department_rounded,
  'distance' => Icons.route_rounded,
  'active_minutes' || 'exercise_minutes' => Icons.schedule_rounded,
  'heart_rate' => Icons.favorite_rounded,
  'resting_hr' => Icons.monitor_heart_rounded,
  'hrv' => Icons.waves_rounded,
  'sleep' => Icons.bedtime_rounded,
  'deep_sleep' => Icons.hotel_rounded,
  'stress' => Icons.psychology_rounded,
  'spo2' => Icons.bloodtype_rounded,
  'skin_temp' || 'temperature' || 'body_temp' => Icons.thermostat_rounded,
  'respiration' => Icons.air_rounded,
  'weight' => Icons.monitor_weight_rounded,
  'bp' => Icons.speed_rounded,
  'glucose' => Icons.water_drop_rounded,
  'emotion' => Icons.emoji_emotions_rounded,
  'vo2max' => Icons.directions_run_rounded,
  _ => Icons.insights_rounded,
};
