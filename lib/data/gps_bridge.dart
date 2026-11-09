import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.speed,
    required this.accuracy,
    required this.ts,
  });

  final double lat;
  final double lon;
  final double alt;
  final double speed;
  final double accuracy;
  final int ts;

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    'alt': alt,
    'speed': speed,
    'ts': ts,
  };
}

/// 手机 GPS 采集与轨迹累计。只有精度可接受、且移动超过 2 米的点才计入里程，避免站着不动也涨距离。
class GpsBridge {
  GpsBridge._();

  static final GpsBridge instance = GpsBridge._();

  static const _method = MethodChannel('vitaloop/gps');
  static const _events = EventChannel('vitaloop/gps_events');

  final fixes = ValueNotifier<List<GpsFix>>(const []);
  final distanceM = ValueNotifier<double>(0);
  final speedMps = ValueNotifier<double>(0);
  final active = ValueNotifier<bool>(false);
  final state = ValueNotifier<String>('idle');

  // ignore: unused_field
  StreamSubscription? _sub;
  bool _listening = false;

  Future<void> _ensureListen() async {
    if (_listening) return;
    _listening = true;
    try {
      _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    } catch (_) {
      _listening = false;
    }
  }

  void _onEvent(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      if (msg['type'] == 'state') {
        state.value = msg['state'] as String? ?? 'unknown';
        if (state.value.startsWith('stopped')) active.value = false;
        return;
      }
      if (msg['type'] != 'point') return;
      final fix = GpsFix(
        lat: (msg['lat'] as num).toDouble(),
        lon: (msg['lon'] as num).toDouble(),
        alt: (msg['alt'] as num?)?.toDouble() ?? 0,
        speed: (msg['speed'] as num?)?.toDouble() ?? 0,
        accuracy: (msg['accuracy'] as num?)?.toDouble() ?? 0,
        ts:
            (msg['ts'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
      if (fix.accuracy > 80) return;
      final current = fixes.value;
      if (current.isEmpty) {
        fixes.value = [fix];
        speedMps.value = fix.speed < 0 ? 0 : fix.speed;
        return;
      }
      final last = current.last;
      final meters = _haversine(last.lat, last.lon, fix.lat, fix.lon);
      final dt = (fix.ts - last.ts) / 1000.0;
      speedMps.value = fix.speed > 0.2
          ? fix.speed
          : (dt > 0 ? meters / dt : 0).clamp(0.0, 15.0).toDouble();
      if (meters < 2) return;
      if (meters > 200) return;
      fixes.value = [...current, fix];
      distanceM.value = distanceM.value + meters;
    } catch (_) {}
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180;
    final p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180;
    final dl = (lon2 - lon1) * math.pi / 180;
    final h =
        math.pow(math.sin(dp / 2), 2) +
        math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  Future<bool> requestPermissions() async {
    try {
      return await _method.invokeMethod<bool>('request_permissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 最近一次已知位置：用于实时页打开瞬间先把地图落到当前位置，
  /// 不必等 GPS 第一帧（否则底图会先停在 (0, 0) 的海面）。
  Future<GpsFix?> lastKnown() async {
    try {
      final raw = await _method.invokeMethod<String>('last');
      if (raw == null || raw.isEmpty) return null;
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final lat = (msg['lat'] as num?)?.toDouble();
      final lon = (msg['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return null;
      if (lat.abs() > 85 || lon.abs() > 180) return null;
      if (lat == 0 && lon == 0) return null;
      return GpsFix(
        lat: lat,
        lon: lon,
        alt: (msg['alt'] as num?)?.toDouble() ?? 0,
        speed: (msg['speed'] as num?)?.toDouble() ?? 0,
        accuracy: (msg['accuracy'] as num?)?.toDouble() ?? 0,
        ts:
            (msg['ts'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> start() async {
    await _ensureListen();
    final granted = await requestPermissions();
    if (!granted) {
      state.value = 'failed:未授予定位权限';
      return false;
    }
    try {
      final ok = await _method.invokeMethod<bool>('start') ?? false;
      active.value = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    active.value = false;
  }

  void reset() {
    fixes.value = const [];
    distanceM.value = 0;
    speedMps.value = 0;
  }

  Future<void> keepScreenOn(bool enabled) async {
    try {
      await _method.invokeMethod('keep_screen_on', {'enabled': enabled});
    } catch (_) {}
  }
}
