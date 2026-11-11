import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'blog_hr.dart';
import '../src/rust/api/types.dart';
import '../state/app_state.dart';

/// 手表闹钟。index=0 为智能唤醒，1..5 为普通闹钟。
class WatchAlarm {
  const WatchAlarm({
    required this.index,
    required this.enabled,
    required this.hour,
    required this.minute,
    this.repeatMask = 0,
    this.label = '闹钟',
    this.smartWakeupIntervalMinutes,
  });

  final int index;
  final bool enabled;
  final int hour;
  final int minute;
  final int repeatMask;
  final String label;
  final int? smartWakeupIntervalMinutes;

  bool get isSmart => index == 0;

  factory WatchAlarm.fromJson(Map<String, dynamic> json) => WatchAlarm(
    index: (json['index'] as num?)?.toInt() ?? 1,
    enabled: json['isEnabled'] as bool? ?? json['enabled'] as bool? ?? false,
    hour: (json['hourOfDay'] as num?)?.toInt() ?? 0,
    minute: (json['minuteOfHour'] as num?)?.toInt() ?? 0,
    repeatMask: (json['repeatMask'] as num?)?.toInt() ?? 0,
    label: json['label'] as String? ?? '闹钟',
    smartWakeupIntervalMinutes: (json['smartWakeupIntervalMinutes'] as num?)
        ?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'index': index,
    'isEnabled': enabled,
    'hourOfDay': hour,
    'minuteOfHour': minute,
    'repeatMask': repeatMask,
    'label': label,
    'smartWakeupIntervalMinutes': smartWakeupIntervalMinutes,
  };

  WatchAlarm copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    int? repeatMask,
    String? label,
  }) => WatchAlarm(
    index: index,
    enabled: enabled ?? this.enabled,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    repeatMask: repeatMask ?? this.repeatMask,
    label: label ?? this.label,
    smartWakeupIntervalMinutes: smartWakeupIntervalMinutes,
  );

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String get repeatLabel {
    if (repeatMask == 0) return '仅一次';
    if (repeatMask == 0x7f) return '每天';
    if (repeatMask == 0x1f) return '工作日';
    if (repeatMask == 0x60) return '周末';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final days = [
      for (var i = 0; i < 7; i++)
        if (repeatMask & (1 << i) != 0) '周${names[i]}',
    ];
    return days.isEmpty ? '仅一次' : days.join('、');
  }
}

class WatchLiveFrame {
  const WatchLiveFrame({
    required this.sport,
    required this.speedKmh,
    required this.heartRate,
    required this.calories,
    required this.distanceM,
    required this.climb,
    required this.altitude,
    required this.startedAt,
    required this.lastFrameAt,
    required this.pulled,
    this.operator,
    this.cadence,
    this.power,
    this.averageHeartRate,
    this.maxHeartRate,
    this.lat,
    this.lon,
  });

  final int sport;
  final double speedKmh;
  final int heartRate;
  final int calories;
  final int distanceM;
  final int climb;
  final int altitude;
  final int startedAt;
  final int lastFrameAt;
  final bool pulled;
  final int? operator;
  final int? cadence;
  final int? power;
  final int? averageHeartRate;
  final int? maxHeartRate;
  final double? lat;
  final double? lon;

  factory WatchLiveFrame.fromJson(Map<String, dynamic> json) {
    int intValue(String key, [int fallback = 0]) =>
        (json[key] as num?)?.toInt() ?? fallback;
    double doubleValue(String key, [double fallback = 0]) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    return WatchLiveFrame(
      sport: intValue('sport'),
      speedKmh: doubleValue('speedKmh'),
      heartRate: intValue('heartRate'),
      calories: intValue('calories'),
      distanceM: intValue('distanceM'),
      climb: intValue('climb'),
      altitude: intValue('altitude'),
      startedAt: intValue('startedAt'),
      lastFrameAt: intValue('lastFrameAt'),
      pulled: json['pulled'] == true,
      operator: (json['operator'] as num?)?.toInt(),
      cadence: (json['cadence'] as num?)?.toInt(),
      power: (json['power'] as num?)?.toInt(),
      averageHeartRate: (json['averageHeartRate'] as num?)?.toInt(),
      maxHeartRate: (json['maxHeartRate'] as num?)?.toInt(),
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
    );
  }

  /// 平均配速（秒/公里）：用时 ÷ 距离。距离或时长不足时返回 null。
  int? get avgPaceSecPerKm {
    if (distanceM < 100 || startedAt <= 0) return null;
    final elapsedSec = (lastFrameAt - startedAt) / 1000.0;
    if (elapsedSec < 1) return null;
    final km = distanceM / 1000.0;
    final pace = (elapsedSec / km).round();
    if (pace <= 0 || pace > 3600) return null;
    return pace;
  }
}

class WatchLiveEnd {
  const WatchLiveEnd({required this.at, required this.reason});

  final int at;
  final String reason;
}

class WatchTrackPoint {
  const WatchTrackPoint({
    required this.lat,
    required this.lon,
    required this.ts,
  });

  final double lat;
  final double lon;
  final int ts;
}

/// 手表直连桥：订阅原生连接/同步事件，批量写入 Rust store。
class WatchBridge {
  WatchBridge._();

  static final WatchBridge instance = WatchBridge._();

  static const _method = MethodChannel('vitaloop/watch');
  static const _events = EventChannel('vitaloop/watch_events');

  final state = ValueNotifier<String>('disconnected');
  final lastSync = ValueNotifier<DateTime?>(null);
  final autoSync = ValueNotifier<bool>(true);
  final watchTools = ValueNotifier<Map<String, dynamic>>(const {});
  final workoutLive = ValueNotifier<WatchLiveFrame?>(null);
  final workoutTrack = ValueNotifier<List<WatchTrackPoint>>(const []);
  final workoutAutoOpen = ValueNotifier<int>(0);
  final workoutEnded = ValueNotifier<WatchLiveEnd?>(null);
  final workoutRealtimeStatus = ValueNotifier<Map<String, dynamic>>(const {});
  List<Map<String, dynamic>> _buffer = [];
  Timer? _flushTimer;
  final Map<String, int> _blogPushCursors = {};
  // ignore: unused_field
  StreamSubscription? _sub;
  bool _listening = false;
  AppState? _appState;

  void attach(AppState appState) {
    _appState = appState;
    _ensureListen();
  }

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
      final kind = msg['kind'] as String?;
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      if (kind == 'state') {
        final v = payload['v'] as String? ?? 'disconnected';
        state.value = v;
        if (v == 'ready') {
          _saveIdentityLastSync();
        }
      } else if (kind == 'data') {
        final t = payload['t'] as String?;
        if (t == 'watch_live') {
          _onLiveFrame(payload);
          return;
        }
        if (t == 'watch_live_end') {
          workoutEnded.value = WatchLiveEnd(
            at:
                (payload['at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
            reason: payload['reason'] as String? ?? '手表已结束运动',
          );
          return;
        }
        if (t == 'sync_done') {
          lastSync.value = DateTime.now();
          // 睡眠详情文件在主同步完成后异步下载、解析并落库。这里再补一次
          // 延迟刷新，避免最后一笔 sleep_segment 早于 UI 刷新时首页长期停在 "--"。
          Timer(const Duration(seconds: 8), () {
            unawaited(_appState?.refresh() ?? Future<void>.value());
          });
        }
        if (t == 'watch_tools') {
          watchTools.value =
              (payload['status'] as Map?)?.cast<String, dynamic>() ?? const {};
        }
        _buffer.add(payload);
        _flushTimer ??= Timer(const Duration(seconds: 2), _flush);
        if (_buffer.length >= 100) _flush();
      }
    } catch (_) {}
  }

  void _onLiveFrame(Map<String, dynamic> payload) {
    final frame = WatchLiveFrame.fromJson(payload);
    workoutLive.value = frame;
    if (payload['autoOpen'] == true) {
      workoutTrack.value = const [];
      workoutEnded.value = null;
      workoutAutoOpen.value = frame.lastFrameAt > 0
          ? frame.lastFrameAt
          : DateTime.now().millisecondsSinceEpoch;
    }
    final lat = frame.lat;
    final lon = frame.lon;
    if (lat == null || lon == null) return;
    final current = workoutTrack.value;
    final last = current.isEmpty ? null : current.last;
    if (last != null && last.lat == lat && last.lon == lon) return;
    workoutTrack.value = [
      ...current,
      WatchTrackPoint(lat: lat, lon: lon, ts: frame.lastFrameAt),
    ].take(4000).toList();
  }

  Future<void> _saveIdentityLastSync() async {
    try {
      final id = await VitaloopApi.watchIdentity();
      if (id.address.isEmpty) return;
    } catch (_) {}
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    final batch = _buffer;
    _buffer = [];
    try {
      await VitaloopApi.ingestWatchData(
        eventsJson: jsonEncode({'events': batch}),
      );
      unawaited(_pushMetricsToBlog(batch));
      await _appState?.refresh();
    } catch (_) {
      // 入库失败丢批：下一轮 1 分钟增量同步会补回数据
    }
  }

  /// 手表同步来的健康指标顺带推给 blogapi：博客马拉松页各卡片/曲线读的
  /// 是 blogapi 的 realtime_* 表，老 heart_sync App 停推后只能靠这里续上。
  /// 每个指标独立游标只前进，重同步回放的旧事件不会重复刷接口。
  static const _blogMetricPaths = {
    'hr': 'heart-rate/realtime',
    'spo2': 'spo2/realtime',
    'resting_hr': 'resting-heart-rate/realtime',
    'hrv': 'hrv/realtime',
    'respiration': 'respiratory-rate/realtime',
    'stress': 'stress/realtime',
    'skin_temp': 'temperature/realtime',
    'emotion': 'emotion/realtime',
    'arrhythmia': 'arrhythmia/realtime',
    'apnea': 'apnea/realtime',
  };

  static Map<String, dynamic>? _blogPayload(String t, Map<String, dynamic> ev) {
    num? v(String k) => ev[k] as num?;
    final base = <String, dynamic>{'source': 'vitaloop'};
    switch (t) {
      case 'hr':
        return {...base, 'heart_rate': v('bpm')};
      case 'spo2':
        return {...base, 'spo2': v('v')};
      case 'resting_hr':
      case 'respiration':
        return {...base, 'value': v('v')};
      case 'hrv':
        return {...base, 'rmssd': v('v')};
      case 'stress':
        return {...base, 'score': v('v')};
      case 'skin_temp':
        return {...base, 'value': v('v')};
      case 'emotion':
        return {
          ...base,
          'status': v('status'),
          'valence': v('valence'),
          'arousal': v('arousal'),
        };
      case 'arrhythmia':
        return {
          ...base,
          'result_type': v('result'),
          'measure_type': v('measure_type'),
        };
      case 'apnea':
        return {...base, 'level': v('level')};
    }
    return null;
  }

  Future<void> _pushMetricsToBlog(List<Map<String, dynamic>> batch) async {
    if (!BlogHrApi.enabled) return;
    final defaultCursor =
        DateTime.now().millisecondsSinceEpoch - 3 * 86400000;
    for (final entry in _blogMetricPaths.entries) {
      final t = entry.key;
      try {
        var cursor = _blogPushCursors[t];
        if (cursor == null) {
          final saved = await VitaloopApi.setting(
            'blog_push_last_ts_$t',
            '',
          );
          // 首次启用只回补最近 3 天，够博客 24h/7d 图用，也避免装机时打满接口
          cursor = int.tryParse(saved) ?? defaultCursor;
          _blogPushCursors[t] = cursor;
        }
        final points =
            [
                  for (final ev in batch)
                    if (ev['t'] == t)
                      (
                        tsMs: (ev['ts'] as num?)?.toInt() ?? 0,
                        payload: _blogPayload(t, ev),
                      ),
                ]
                .where(
                  (p) =>
                      p.tsMs > cursor! &&
                      p.payload != null &&
                      // 数值字段（除 source/timestamp 外）至少一个非 null；
                      // 手表侧已对 hr/spo2/resting_hr 过滤 0 值
                      p.payload!.entries.any(
                        (x) => x.key != 'source' && x.value is num,
                      ),
                )
                .map(
                  (p) => (
                    tsMs: p.tsMs,
                    body: {...p.payload!, 'timestamp': p.tsMs},
                  ),
                )
                .toList()
              ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
        if (points.isEmpty) continue;
        final newTs = await BlogHrApi.pushMetric(entry.value, points);
        if (newTs != null && newTs > cursor) {
          _blogPushCursors[t] = newTs;
          await VitaloopApi.setSetting('blog_push_last_ts_$t', '$newTs');
        }
      } catch (_) {}
    }
  }

  Future<void> autoConnect() async {
    await VitaloopApi.readyFuture;
    await loadAutoSync();
    try {
      final id = await VitaloopApi.watchIdentity();
      if (id.address.isNotEmpty) {
        await connect(id.address, id.name);
      }
    } catch (_) {}
  }

  Future<void> loadAutoSync() async {
    try {
      final enabled = await _method.invokeMethod<bool>('auto_sync');
      if (enabled != null) autoSync.value = enabled;
    } catch (_) {}
  }

  Future<void> setAutoSync(bool enabled) async {
    autoSync.value = enabled;
    try {
      await _method.invokeMethod<bool>('set_auto_sync', {'enabled': enabled});
    } catch (_) {}
  }

  Future<bool> weatherSyncEnabled() async {
    try {
      return await _method.invokeMethod<bool>('weather_sync') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setWeatherSync(bool enabled) async {
    try {
      await _method.invokeMethod<bool>('set_weather_sync', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  Future<bool> dndEnabled() async {
    try {
      return await _method.invokeMethod<bool>('dnd_get') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setDndEnabled(bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('dnd_set', {
            'enabled': enabled,
          }) ??
          enabled;
    } catch (_) {
      return enabled;
    }
  }

  Future<Map<String, bool>> watchSettings() async {
    try {
      final raw = await _method.invokeMethod<String>('watch_settings');
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw) as Map;
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value == true),
      );
    } catch (_) {
      return const {};
    }
  }

  Future<bool> setWatchSetting(String key, bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('watch_setting_set', {
            'key': key,
            'enabled': enabled,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> dndPlan() async {
    try {
      final raw = await _method.invokeMethod<String>('dnd_plan');
      if (raw == null || raw.isEmpty) return const {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
    }
  }

  Future<bool> setDndPlan({
    required String mode,
    required String start,
    required String end,
    required int repeatMask,
    required bool liftWrist,
  }) async {
    try {
      return await _method.invokeMethod<bool>('dnd_plan_set', {
            'mode': mode,
            'start': start,
            'end': end,
            'repeatMask': repeatMask,
            'liftWrist': liftWrist,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<String> syncAllSettings() async {
    try {
      return await _method.invokeMethod<String>('sync_all_settings') ?? '已提交同步';
    } catch (e) {
      return '同步失败：$e';
    }
  }

  Future<bool> factoryReset() async {
    try {
      return await _method.invokeMethod<bool>('factory_reset') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> notificationAccess() async {
    try {
      return await _method.invokeMethod<bool>('notification_access') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationAccess() async {
    try {
      await _method.invokeMethod('open_notification_access');
    } catch (_) {}
  }

  Future<bool> notificationForwardEnabled() async {
    try {
      return await _method.invokeMethod<bool>('notification_forward') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> setNotificationForward(bool enabled) async {
    try {
      await _method.invokeMethod('set_notification_forward', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  Future<({String mode, Set<String> packages})> notificationFilter() async {
    try {
      final raw = await _method.invokeMethod<dynamic>('notification_filter');
      final map = raw is Map ? raw : const {};
      return (
        mode: map['mode'] as String? ?? 'all',
        packages: ((map['packages'] as List?) ?? const [])
            .map((e) => '$e')
            .where((e) => e.isNotEmpty)
            .toSet(),
      );
    } catch (_) {
      return (mode: 'all', packages: <String>{});
    }
  }

  Future<void> setNotificationFilter(String mode, Set<String> packages) async {
    try {
      await _method.invokeMethod('set_notification_filter', {
        'mode': mode,
        'packages': packages.toList(),
      });
    } catch (_) {}
  }

  Future<List<({String name, String package})>> notificationApps() async {
    try {
      final raw = await _method.invokeMethod<dynamic>('notification_apps');
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! List) return const [];
      return [
          for (final item in decoded.whereType<Map>())
            (
              name: item['name'] as String? ?? item['package'] as String? ?? '',
              package: item['package'] as String? ?? '',
            ),
        ].where((e) => e.package.isNotEmpty).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  Future<bool> workoutRealtimeEnabled() async {
    try {
      return await _method.invokeMethod<bool>('workout_realtime') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> setWorkoutRealtimeEnabled(bool enabled) async {
    try {
      final value =
          await _method.invokeMethod<bool>('set_workout_realtime', {
            'enabled': enabled,
          }) ??
          enabled;
      await refreshWorkoutRealtimeStatus();
      return value;
    } catch (_) {
      return enabled;
    }
  }

  Future<Map<String, dynamic>> refreshWorkoutRealtimeStatus() async {
    try {
      final raw = await _method.invokeMethod<String>('workout_realtime_status');
      if (raw == null || raw.isEmpty) return workoutRealtimeStatus.value;
      final value = jsonDecode(raw) as Map<String, dynamic>;
      workoutRealtimeStatus.value = value;
      return value;
    } catch (_) {
      return workoutRealtimeStatus.value;
    }
  }

  Future<WatchLiveFrame?> liveSnapshot() async {
    try {
      final raw = await _method.invokeMethod<String>('workout_live_snapshot');
      if (raw == null || raw.isEmpty) return null;
      final frame = WatchLiveFrame.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      workoutLive.value = frame;
      return frame;
    } catch (_) {
      return null;
    }
  }

  Future<List<WatchAlarm>> alarms() async {
    try {
      final raw = await _method.invokeMethod<String>('alarms_list');
      if (raw == null || raw.isEmpty) return const [];
      return [
        for (final item in jsonDecode(raw) as List<dynamic>)
          WatchAlarm.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 保存到本机；手表在线时原生层会立即下发，离线则在下次连接后补发。
  Future<bool> saveAlarms(List<WatchAlarm> alarms) async {
    try {
      return await _method.invokeMethod<bool>('alarms_save', {
            'alarms': jsonEncode([for (final a in alarms) a.toJson()]),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> syncAlarms() async {
    try {
      await _method.invokeMethod('alarms_sync');
    } catch (_) {}
  }

  Future<bool> holidaySkipEnabled() async {
    try {
      return await _method.invokeMethod<bool>('holiday_skip_get') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> setHolidaySkipEnabled(bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('holiday_skip_set', {
            'enabled': enabled,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> todayWorkday() async {
    try {
      return await _method.invokeMethod<bool>('today_workday') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<Map<String, dynamic>> calendarStatus() async {
    try {
      final raw = await _method.invokeMethod<String>('calendar_status');
      if (raw == null || raw.isEmpty) return const {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  /// 首次开启会触发系统日历读取权限申请；被拒绝时返回 false。
  Future<bool> setCalendarSyncEnabled(bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('calendar_set_enabled', {
            'enabled': enabled,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> syncCalendarNow() async {
    try {
      return await _method.invokeMethod<bool>('calendar_sync_now') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> pushTrainingPlan(String planJson) async {
    try {
      final raw = await _method.invokeMethod<String>('training_plan_push', {
        'plan': planJson,
      });
      if (raw == null || raw.isEmpty) {
        return const {'ok': false, 'message': '手表没有响应'};
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'message': '下发失败：$e'};
    }
  }

  Future<Map<String, dynamic>> finishTrainingPlan(String planId) async {
    try {
      final raw = await _method.invokeMethod<String>('training_plan_finish', {
        'plan_id': planId,
      });
      if (raw == null || raw.isEmpty) {
        return const {'ok': false, 'message': '手表没有响应'};
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'message': '完结失败：$e'};
    }
  }

  /// 把本机保存的路线下发给手表。点坐标统一按 GCJ-02 传入，原生编码器会转 WGS-84。
  Future<Map<String, dynamic>> pushRoute({
    required String name,
    required double distanceMeters,
    required List<GeoPoint> points,
  }) async {
    try {
      final raw = await _method.invokeMethod<String>('route_push', {
        'route': jsonEncode({
          'name': name,
          'distance_m': distanceMeters,
          'points': [
            for (final point in points) {'lat': point.lat, 'lon': point.lon},
          ],
        }),
      });
      if (raw == null || raw.isEmpty) {
        return const {'ok': false, 'message': '手表没有响应'};
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'message': '发送失败：$e'};
    }
  }

  /// 只检查手表地图通道、剩余空间和已有地图数量，不发文件。
  Future<Map<String, dynamic>> probeOfflineMap() async {
    try {
      final raw = await _method.invokeMethod<String>('offline_map_probe');
      if (raw == null || raw.isEmpty) {
        return const {'ok': false, 'message': '手表没有响应'};
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'message': '探测失败：$e'};
    }
  }

  /// 选择本地地图包（content Uri），不复制文件，交给原生线程直接读取下发。
  Future<Map<String, dynamic>?> pickOfflineMap() async {
    try {
      final raw = await _method.invokeMethod<dynamic>('pick_offline_map');
      if (raw is Map) return raw.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> pushOfflineMap(String uri) async {
    try {
      final raw = await _method.invokeMethod<String>('offline_map_push', {
        'uri': uri,
      });
      if (raw == null || raw.isEmpty) {
        return const {'ok': false, 'message': '手表没有响应'};
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'message': '发送失败：$e'};
    }
  }

  /// 系统蓝牙里已经配对过的华为手表。经典蓝牙手表通常不会出现在 BLE 扫描里。
  Future<List<Map<String, String>>> bondedDevices() async {
    try {
      final raw = await _method.invokeMethod<String>('bonded_devices');
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          {
            'name':
                (item as Map<String, dynamic>)['name'] as String? ??
                'HUAWEI WATCH',
            'address': item['address'] as String? ?? '',
          },
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 重置增量游标，强制回拉最近几天。用于补回入库失败或手表延迟上传的数据。
  Future<void> resyncRecent({int days = 7}) async {
    await _method.invokeMethod<void>('resync', {'days': days});
  }

  Future<void> connect(String mac, String name, {String? account}) async {
    await VitaloopApi.readyFuture;
    await _ensureListen();
    // 凭据存在 Rust 侧（旧版迁移或本机配对产生），协议栈读的是设备级 SharedPreferences，
    // 所以连接前把它们取出来交给原生层落盘。
    var authKey = '';
    var fakeAndroidId = '';
    var savedAccount = '';
    var ephemerisUrl = '';
    WatchIdentity? id;
    try {
      id = await VitaloopApi.watchIdentity();
      authKey = id.authKey;
      fakeAndroidId = id.fakeAndroidId;
      savedAccount = id.account;
      ephemerisUrl = id.ephemerisUrl;
    } catch (_) {}
    // 星历地址必须在 onReady 之前落到原生层，否则握手时取不到、要等下一轮连接
    await _method.invokeMethod('set_ephemeris_url', {'url': ephemerisUrl});
    final effectiveAccount = (account ?? '').trim().isNotEmpty
        ? account!.trim()
        : savedAccount;
    try {
      await _method.invokeMethod('connect', {
        'mac': mac,
        'name': name,
        'auth_key': authKey,
        'fake_android_id': fakeAndroidId,
        'account': effectiveAccount,
        'huawei_address': id?.huaweiAddress ?? '',
      });
      // 首次配对没有旧版凭据，地址和华为账号先由 Rust 记下来，重启后 autoConnect 才能找到手表。
      await VitaloopApi.saveWatchIdentity(
        WatchIdentity(
          address: mac,
          name: name,
          account: effectiveAccount,
          authKey: authKey,
          fakeAndroidId: fakeAndroidId,
          huaweiAddress: id?.huaweiAddress ?? mac,
          lastSyncMs: id?.lastSyncMs,
          migrated: id?.migrated ?? false,
          ephemerisUrl: ephemerisUrl,
        ),
      );
    } on PlatformException catch (e) {
      state.value = 'failed:${e.message ?? e.code}';
    }
  }

  /// 星历运行态：原生下载器给出的文件年龄 / AGNSS 时间 / 是否需要刷新。
  Future<Map<String, dynamic>> ephemerisStatus() async {
    try {
      final raw = await _method.invokeMethod<String>('ephemeris_status');
      if (raw == null || raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// 立刻下载星历包；原生在后台线程跑，回话是给人看的一句话。
  Future<String> downloadEphemeris() async {
    try {
      return await _method.invokeMethod<String>('download_ephemeris') ??
          '已发起下载';
    } catch (_) {
      return '下载请求失败';
    }
  }

  /// App 启动/打开星历页时调用：原生只会在缺文件或过期时后台补下载。
  Future<void> ensureEphemeris() async {
    try {
      await _method.invokeMethod<void>('ensure_ephemeris');
    } catch (_) {}
  }

  Future<void> saveEphemerisUrl(String url) async {
    try {
      final id = await VitaloopApi.watchIdentity();
      await VitaloopApi.saveWatchIdentity(
        WatchIdentity(
          address: id.address,
          name: id.name,
          account: id.account,
          authKey: id.authKey,
          fakeAndroidId: id.fakeAndroidId,
          huaweiAddress: id.huaweiAddress,
          lastSyncMs: id.lastSyncMs,
          migrated: id.migrated,
          ephemerisUrl: url.trim(),
        ),
      );
    } catch (_) {}
    try {
      await _method.invokeMethod('set_ephemeris_url', {'url': url.trim()});
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await _method.invokeMethod('disconnect');
    } catch (_) {}
    state.value = 'disconnected';
  }

  Future<void> syncNow() async {
    try {
      await _method.invokeMethod('sync');
    } catch (_) {}
  }

  Future<void> refreshSleepNow() async {
    await _method.invokeMethod('refresh_sleep');
  }

  Future<Map<String, dynamic>> watchToolsStatus() async {
    try {
      final raw = await _method.invokeMethod<String>('watch_tools_status');
      if (raw == null || raw.isEmpty) return const {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
    }
  }

  Future<bool> cameraRemoteEnabled() async {
    try {
      return await _method.invokeMethod<bool>('camera_remote_enabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setCameraRemote(bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('camera_remote_set', {
            'enabled': enabled,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setFindPhone(bool enabled) async {
    try {
      await _method.invokeMethod('find_phone_set', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> testFindPhone() async {
    try {
      await _method.invokeMethod('find_phone_test');
    } catch (_) {}
  }

  Future<void> stopFindPhone() async {
    try {
      await _method.invokeMethod('find_phone_stop');
    } catch (_) {}
  }

  Future<bool> syncContacts() async {
    try {
      return await _method.invokeMethod<bool>('sync_contacts') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> loadApps() async {
    try {
      await _method.invokeMethod('apps_list');
    } catch (_) {}
  }

  Future<void> deleteApp(String package) async {
    try {
      await _method.invokeMethod('app_delete', {'package': package});
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> pickWatchApp() async {
    try {
      final raw = await _method.invokeMethod<dynamic>('pick_watch_app');
      if (raw is Map) return raw.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> installApp(String path, String package) async {
    try {
      await _method.invokeMethod('app_install', {
        'path': path,
        'package': package,
      });
    } catch (_) {}
  }

  Future<void> loadWatchfaces() async {
    try {
      await _method.invokeMethod('watchfaces_list');
    } catch (_) {}
  }

  Future<void> activateWatchface(String file, String version) async {
    try {
      await _method.invokeMethod('watchface_activate', {
        'file': file,
        'version': version,
      });
    } catch (_) {}
  }

  Future<void> deleteWatchface(String file, String version) async {
    try {
      await _method.invokeMethod('watchface_delete', {
        'file': file,
        'version': version,
      });
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> pickWatchface() async {
    try {
      final raw = await _method.invokeMethod<dynamic>('pick_watchface');
      if (raw is Map) return raw.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> installWatchface(
    String path,
    String name,
    String version,
    String mode,
  ) async {
    try {
      await _method.invokeMethod('watchface_install', {
        'path': path,
        'name': name,
        'version': version,
        'mode': mode,
      });
    } catch (_) {}
  }

  Future<void> loadMusicLibrary() async {
    try {
      await _method.invokeMethod('music_library');
    } catch (_) {}
  }

  Future<List<String>> pickMusicFiles() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('pick_music');
      return [for (final item in raw ?? const []) item as String];
    } catch (_) {
      return const [];
    }
  }

  Future<void> uploadMusic(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _method.invokeMethod('music_upload', {'paths': paths});
    } catch (_) {}
  }

  Future<void> cancelMusicUpload() async {
    try {
      await _method.invokeMethod('music_cancel');
    } catch (_) {}
  }

  /// 让手表立即回一次佩戴状态（0x01/0x3d），结果从 [watchToolsStatus] 读取。
  Future<void> queryWearStatus() async {
    try {
      await _method.invokeMethod('wear_query');
    } catch (_) {}
  }

  /// 打开/关闭在腕免密解锁。返回 false 表示 Settings.Secure 写入被拒，
  /// 需要一次性 `adb shell pm grant me.awen.vitaloop android.permission.WRITE_SECURE_SETTINGS`。
  Future<bool> setWristUnlock(bool enabled) async {
    try {
      return await _method.invokeMethod<bool>('wrist_unlock_set', {
            'enabled': enabled,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
