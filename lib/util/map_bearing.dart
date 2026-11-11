import 'dart:math' as math;
import 'dart:ui';

import 'km_markers.dart';

/// 用最近的轨迹点估算前进方向。
///
/// 返回角度：正北 0°，顺时针增长（东 90°、南 180°、西 270°）。
/// 取最后一段至少 [minDistanceMeters] 的位移，避免低速时 GPS 抖动让方向乱跳；
/// 位移不足时返回 null，调用方保持上一次方向。
double? travelBearingDegrees(
  List<Offset> latLonPoints, {
  double minDistanceMeters = 3,
  double preferDistanceMeters = 8,
}) {
  if (latLonPoints.length < 2) return null;
  final last = latLonPoints.last;
  if (!last.dx.isFinite || !last.dy.isFinite) return null;
  var previous = latLonPoints[latLonPoints.length - 2];
  var distance = distanceMeters(previous.dx, previous.dy, last.dx, last.dy);
  // 只回看最近 30 个点，长轨迹也不做无意义的全量扫描。
  for (
    var i = latLonPoints.length - 3;
    i >= 0 && i >= latLonPoints.length - 30;
    i--
  ) {
    final candidate = latLonPoints[i];
    if (!candidate.dx.isFinite || !candidate.dy.isFinite) continue;
    previous = candidate;
    distance = distanceMeters(candidate.dx, candidate.dy, last.dx, last.dy);
    if (distance >= preferDistanceMeters) break;
  }
  if (!distance.isFinite || distance < minDistanceMeters) return null;

  final lat1 = previous.dx * math.pi / 180;
  final lat2 = last.dx * math.pi / 180;
  final deltaLon = (last.dy - previous.dy) * math.pi / 180;
  final y = math.sin(deltaLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
  if (!x.isFinite || !y.isFinite || (x == 0 && y == 0)) return null;
  final degrees = math.atan2(y, x) * 180 / math.pi;
  return (degrees + 360) % 360;
}

/// 让地图转向更平滑：每次定位更新最多追 40°，小抖动直接忽略。
double blendBearingDegrees(double current, double target) {
  var delta = (target - current + 540) % 360 - 180;
  if (delta.abs() < 2.5) return current;
  delta = delta.clamp(-40.0, 40.0) * 0.6;
  return (current + delta + 360) % 360;
}
