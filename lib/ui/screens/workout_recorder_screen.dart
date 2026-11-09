import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/ble_bridge.dart';
import '../../data/gps_bridge.dart';
import '../../data/tts_bridge.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/coordinate.dart';
import '../../util/format.dart';
import '../amap_route_map.dart';
import '../components.dart';
import 'recovery_hr_screen.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

/// 手机端运动记录：计时、暂停、保存成一条运动记录。
///
/// 旧版跑步页会同时采 GPS；新版还没接定位插件，所以户外项目允许在保存时
/// 手动填距离，先把「开始一次运动」这条路打通。
class WorkoutRecorderScreen extends StatefulWidget {
  const WorkoutRecorderScreen({
    super.key,
    required this.state,
    required this.sport,
    required this.title,
    required this.icon,
    this.route,
  });

  final AppState state;
  final String sport;
  final String title;
  final IconData icon;
  final SavedRoute? route;

  @override
  State<WorkoutRecorderScreen> createState() => _WorkoutRecorderScreenState();
}

class _WorkoutRecorderScreenState extends State<WorkoutRecorderScreen> {
  final Stopwatch _watch = Stopwatch();
  final _gps = GpsBridge.instance;
  final _ble = BleBridge.instance;
  Timer? _ticker;
  DateTime? _startedAt;
  bool _saving = false;
  double _distanceKm = 0;
  bool _autoPause = true;
  bool _autoResume = true;
  bool _recoveryHr = true;
  bool _keepScreenOn = true;
  bool _autoPaused = false;
  int _slowSeconds = 0;
  int _fastSeconds = 0;
  int _hrSum = 0;
  int _hrCount = 0;
  int _hrMax = 0;
  int _elevationIndex = 0;
  double _ascentM = 0;
  double _lastAltitude = double.nan;
  double _gradientPercent = 0;
  double _powerWatts = 0;
  double _powerSum = 0;
  double _powerMax = 0;
  int _powerCount = 0;
  String? _routeJson;
  String _navInstruction = '';
  double _navRemainingM = 0;
  bool _navOffRoute = false;
  bool _navArrived = false;
  bool _navBusy = false;
  int _lastGuidanceTs = 0;
  int _navSpokenAt = 0;
  String _navSpokenKey = '';

  bool get _running => _watch.isRunning;
  bool get _started => _startedAt != null;
  int get _seconds => _watch.elapsed.inSeconds;

  double get _met => switch (widget.sport) {
    '户外跑步' => 9.8,
    '骑行' => 7.5,
    '徒步' => 6.0,
    _ => 5.0,
  };

  double get _weightKg {
    final w = widget.state.profile?.weightKg ?? 0;
    return w > 0 ? w : 70;
  }

  int get _calories => (_met * _weightKg * (_seconds / 3600)).round();

  bool get _outdoor => widget.sport != '力量训练';
  double get _liveDistanceKm =>
      _outdoor ? _gps.distanceM.value / 1000.0 : _distanceKm;
  int get _currentHr {
    final ble = _ble.latestHeartRate.value;
    if (ble > 0) return ble;
    return WatchBridge.instance.workoutLive.value?.heartRate ?? 0;
  }

  int get _avgHr => _hrCount == 0 ? 0 : (_hrSum / _hrCount).round();
  double get _altitude =>
      _gps.fixes.value.isEmpty ? 0 : _gps.fixes.value.last.alt;

  bool get _cycling => widget.sport == '骑行';
  int get _avgPower => _powerCount == 0 ? 0 : (_powerSum / _powerCount).round();
  List<Offset> get _routeMapPoints => [
    for (final p in widget.route?.points ?? const <GeoPoint>[])
      Offset(p.lat, p.lon),
  ];

  @override
  void initState() {
    super.initState();
    final route = widget.route;
    if (route != null) {
      _routeJson = jsonEncode([
        for (final p in route.points) {'lat': p.lat, 'lon': p.lon},
      ]);
    }
    _loadSettings();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _watch.stop();
    _gps.stop();
    unawaited(TtsBridge.instance.stop());
    _gps.keepScreenOn(false);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final values = await Future.wait([
        VitaloopApi.setting('record_auto_pause', '1'),
        VitaloopApi.setting('record_auto_resume', '1'),
        VitaloopApi.setting('record_recovery_hr', '1'),
        VitaloopApi.setting('record_keep_screen_on', '1'),
      ]);
      if (!mounted) return;
      setState(() {
        _autoPause = values[0] == '1';
        _autoResume = values[1] == '1';
        _recoveryHr = values[2] == '1';
        _keepScreenOn = values[3] == '1';
      });
    } catch (_) {}
  }

  void _start() {
    final firstStart = _startedAt == null;
    _startedAt ??= DateTime.now();
    if (firstStart) {
      _gps.reset();
      _elevationIndex = 0;
      _ascentM = 0;
      _lastAltitude = double.nan;
      _hrSum = 0;
      _hrCount = 0;
      _hrMax = 0;
      _gradientPercent = 0;
      _powerWatts = 0;
      _powerSum = 0;
      _powerMax = 0;
      _powerCount = 0;
    }
    _watch.start();
    _autoPaused = false;
    _slowSeconds = 0;
    _fastSeconds = 0;
    if (_outdoor) {
      _gps.start();
      if (_keepScreenOn) _gps.keepScreenOn(true);
    }
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_watch.isRunning) _tickHeartRate();
      _tickElevation();
      _tickCyclingPower();
      _tickNavigation();
      _tickAutoPause();
      setState(() {});
    });
    setState(() {});
  }

  void _pause() {
    _watch.stop();
    unawaited(TtsBridge.instance.stop());
    _autoPaused = false;
    setState(() {});
  }

  void _tickHeartRate() {
    final bpm = _ble.latestHeartRate.value;
    if (bpm <= 0) return;
    _hrSum += bpm;
    _hrCount++;
    if (bpm > _hrMax) _hrMax = bpm;
  }

  void _tickElevation() {
    final fixes = _gps.fixes.value;
    if (fixes.length <= _elevationIndex) return;
    for (var i = _elevationIndex; i < fixes.length; i++) {
      final altitude = fixes[i].alt;
      if (altitude <= 0) continue;
      if (_lastAltitude.isFinite) {
        final delta = altitude - _lastAltitude;
        // GPS 高程本身有 1–2 米抖动，小起伏不计入爬升。
        if (delta > 1) _ascentM += delta;
      }
      _lastAltitude = altitude;
    }
    _elevationIndex = fixes.length;
  }

  void _tickCyclingPower() {
    if (!_cycling || !_watch.isRunning) return;
    final fixes = _gps.fixes.value;
    if (fixes.length < 2) return;
    final last = fixes[fixes.length - 1];
    final prev = fixes[fixes.length - 2];
    final dt = (last.ts - prev.ts) / 1000.0;
    if (dt <= 0) return;
    final meters = _distanceMeters(prev.lat, prev.lon, last.lat, last.lon);
    // 高程抖动大，短距离不更新坡度，沿用上一段的坡度。
    if (meters >= 3 && prev.alt.abs() >= 0.1 && last.alt.abs() >= 0.1) {
      _gradientPercent = ((last.alt - prev.alt) / meters * 100).clamp(
        -25.0,
        25.0,
      );
    }
    final speedKmh = _gps.speedMps.value > 0.2
        ? _gps.speedMps.value * 3.6
        : (meters / dt * 3.6).clamp(0.0, 120.0);
    final watts = speedKmh < 0.5
        ? 0.0
        : VitaloopApi.cyclingPowerWatts(
            speedKmh: speedKmh,
            gradientPercent: _gradientPercent,
            riderWeightKg: _weightKg,
          );
    _powerWatts = watts;
    _powerSum += watts;
    _powerCount++;
    if (watts > _powerMax) _powerMax = watts;
  }

  static double _distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    const rad = 0.017453292519943295;
    final p1 = lat1 * rad;
    final p2 = lat2 * rad;
    final dp = (lat2 - lat1) * rad;
    final dl = (lon2 - lon1) * rad;
    final a =
        math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.sqrt(a <= 0 ? 0 : a));
  }

  void _tickNavigation() {
    final routeJson = _routeJson;
    if (routeJson == null || _navBusy || _navArrived) return;
    if (!_started || !_watch.isRunning) return;
    final fixes = _gps.fixes.value;
    if (fixes.isEmpty) return;
    final fix = fixes.last;
    if (fix.ts == _lastGuidanceTs) return;
    _lastGuidanceTs = fix.ts;
    _navBusy = true;
    final (lat, lon) = Coordinate.wgs84ToGcj02(fix.lat, fix.lon);
    unawaited(() async {
      try {
        final raw = await VitaloopApi.routeGuidance(
          routeJson: routeJson,
          lat: lat,
          lon: lon,
        );
        final data = jsonDecode(raw);
        if (!mounted || data is! Map) return;
        final instruction = data['instruction'] as String? ?? '';
        final remaining = (data['remaining_m'] as num?)?.toDouble() ?? 0;
        final offRoute = data['off_route'] == true;
        final arrived = data['arrived'] == true;
        final turn = data['turn'] as String? ?? 'straight';
        final toTurn = (data['to_turn_m'] as num?)?.toDouble() ?? 0;
        setState(() {
          _navInstruction = instruction;
          _navRemainingM = remaining;
          _navOffRoute = offRoute;
          _navArrived = arrived;
        });
        _speakGuidance(
          instruction,
          turn: turn,
          toTurn: toTurn,
          arrived: arrived,
          offRoute: offRoute,
        );
      } catch (_) {
        // 导航失败不影响记录，下一帧继续试。
      } finally {
        _navBusy = false;
      }
    }());
  }

  void _speakGuidance(
    String instruction, {
    required String turn,
    required double toTurn,
    required bool arrived,
    required bool offRoute,
  }) {
    if (instruction.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final bucket = toTurn >= 1000
        ? (toTurn / 500).floor()
        : toTurn >= 200
        ? (toTurn / 100).floor()
        : toTurn >= 50
        ? (toTurn / 50).floor()
        : (toTurn / 10).floor();
    final key = arrived
        ? 'arrived'
        : offRoute
        ? 'off_route'
        : '$turn:$bucket';
    if (key == _navSpokenKey) return;
    final cooldown = arrived ? 1000 : 6000;
    if (now - _navSpokenAt < cooldown) return;
    _navSpokenKey = key;
    _navSpokenAt = now;
    unawaited(TtsBridge.instance.speak(instruction));
  }

  void _tickAutoPause() {
    if (!_outdoor) return;
    // 刚开表 / 还没拿到两个点时速度不可信，别把人直接按在暂停上
    if (_seconds < 10 || _gps.fixes.value.length < 2) return;
    final speed = _gps.speedMps.value;
    if (speed < 0.5) {
      _slowSeconds++;
      _fastSeconds = 0;
    } else {
      _fastSeconds++;
      _slowSeconds = 0;
    }
    if (_watch.isRunning && _autoPause && _slowSeconds >= 5) {
      _watch.stop();
      _autoPaused = true;
    } else if (!_watch.isRunning &&
        _autoPaused &&
        _autoResume &&
        _fastSeconds >= 3) {
      _watch.start();
      _autoPaused = false;
    }
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _finish() async {
    final elapsed = _seconds;
    if (!_started || elapsed < 1) {
      Navigator.of(context).pop();
      return;
    }
    _pause();
    await TtsBridge.instance.stop();
    await _gps.stop();
    await _gps.keepScreenOn(false);
    final gpsKm = _gps.distanceM.value / 1000.0;
    final distance = await _askDistance(elapsed, initialKm: gpsKm);
    if (distance == null) {
      if (mounted) _start();
      return;
    }
    setState(() => _saving = true);
    try {
      final track = jsonEncode([
        for (final fix in _gps.fixes.value) fix.toJson(),
      ]);
      final workoutId = await VitaloopApi.saveManualWorkout(
        sport: widget.sport,
        startMs: _startedAt!.millisecondsSinceEpoch,
        durationSec: elapsed,
        distanceM: distance * 1000,
        calories: _calories,
        avgHr: _hrCount == 0 ? 0 : (_hrSum / _hrCount).round(),
        maxHr: _hrMax,
        trackJson: track,
      );
      if (_cycling) {
        try {
          await VitaloopApi.analyzeCyclingWorkout(
            workoutId,
            riderWeightKg: _weightKg,
          );
        } catch (_) {
          // 功率只是补充统计，失败不能影响这次运动保存。
        }
      }
      if (_recoveryHr && mounted && _ble.latestHeartRate.value > 0) {
        final samples = await Navigator.of(context).push<List<int>>(
          MaterialPageRoute(builder: (_) => const RecoveryHrScreen()),
        );
        if (samples != null && samples.isNotEmpty) {
          await VitaloopApi.saveWorkoutRecovery(workoutId, jsonEncode(samples));
        }
      }
      _distanceKm = distance;
      await widget.state.refresh();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 ${widget.title} · ${_fmt(elapsed)}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      _start();
    }
  }

  Future<double?> _askDistance(int elapsed, {double initialKm = 0}) {
    final v = context.v;
    final controller = TextEditingController(
      text: initialKm >= 0.01 ? initialKm.toStringAsFixed(2) : '',
    );
    double parsedKm() {
      final text = controller.text.trim();
      if (text.isEmpty) return 0;
      final km = double.tryParse(text) ?? 0;
      return km < 0 ? 0 : km;
    }

    return showModalBottomSheet<double>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            2,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '保存这次${widget.title}',
                style: VText.h2.copyWith(color: v.ink),
              ),
              const SizedBox(height: 6),
              Text(
                '时长 ${_fmt(elapsed)} · 约 $_calories 千卡'
                '${_outdoor && parsedKm() > 0 ? ' · ${fmtPace(parsedKm() * 1000, elapsed)}/km' : ''}',
                style: VText.meta.copyWith(color: v.muted),
              ),
              if (_outdoor) ...[
                const SizedBox(height: 18),
                TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  autofocus: true,
                  onChanged: (_) => setSheetState(() {}),
                  decoration: InputDecoration(
                    labelText: tr('距离（公里，可选）'),
                    hintText: '0',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              VPrimaryButton(
                label: _saving ? '正在保存…' : '保存运动',
                icon: Icons.check_rounded,
                onTap: _saving ? null : () => Navigator.pop(ctx, parsedKm()),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(ctx),
                  child: const Text('继续运动'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () async {
                      final quit = await _confirmQuit();
                      if (quit == true && context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const Spacer(),
                  Text(
                    widget.title,
                    style: VText.meta.copyWith(color: v.muted),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
              const Spacer(),
              if (!_started) ...[
                Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    color: v.tintBlue,
                    borderRadius: BorderRadius.circular(36),
                  ),
                  child: Icon(widget.icon, size: 54, color: v.blueInk),
                ),
                const SizedBox(height: 26),
              ],
              Text(
                _fmt(_seconds),
                style: VText.h1.copyWith(
                  fontSize: 72,
                  color: v.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                !_started
                    ? '准备开始'
                    : (_running
                          ? '正在记录'
                          : (_autoPaused ? '自动暂停 · 检测到移动后恢复' : '已暂停')),
                style: VText.meta.copyWith(
                  color: _running
                      ? v.greenInk
                      : (_autoPaused ? v.warnInk : v.muted),
                ),
              ),
              if (_outdoor) ...[
                const SizedBox(height: 6),
                Text(
                  !_started
                      ? '点击开始后开启 GPS'
                      : (_gps.active.value
                            ? (_gps.fixes.value.isEmpty
                                  ? 'GPS 定位中…'
                                  : 'GPS 已定位 · ${_gps.fixes.value.length} 个轨迹点')
                            : (_gps.state.value.startsWith('failed')
                                  ? _gps.state.value.replaceFirst('failed:', '')
                                  : 'GPS 未开启')),
                  style: VText.label.copyWith(color: v.muted),
                ),
                if (widget.route != null) ...[
                  const SizedBox(height: 12),
                  AmapRouteMap(
                    points: _routeMapPoints,
                    height: 190,
                    currentPoint: _gps.fixes.value.isEmpty
                        ? null
                        : Offset(
                            _gps.fixes.value.last.lat,
                            _gps.fixes.value.last.lon,
                          ),
                    currentPointWgs84: true,
                  ),
                  const SizedBox(height: 10),
                  VCard(
                    background: _navOffRoute ? v.tintPeach : v.tintGreen,
                    child: Row(
                      children: [
                        Icon(
                          _navArrived
                              ? Icons.flag_rounded
                              : (_navOffRoute
                                    ? Icons.wrong_location_rounded
                                    : Icons.navigation_rounded),
                          color: _navOffRoute ? v.warnInk : v.greenInk,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _navInstruction.isEmpty
                                    ? '等待定位后开始路线引导'
                                    : _navInstruction,
                                style: VText.h3.copyWith(
                                  fontSize: 15,
                                  color: _navOffRoute ? v.warnInk : v.ink,
                                ),
                              ),
                              if (_navRemainingM > 0) ...[
                                const SizedBox(height: 3),
                                Text(
                                  '距终点 ${(_navRemainingM / 1000).toStringAsFixed(2)} km',
                                  style: VText.label.copyWith(color: v.muted),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (_gps.fixes.value.length >= 2) ...[
                  const SizedBox(height: 12),
                  AmapRouteMap(
                    points: [
                      for (final fix in _gps.fixes.value)
                        Offset(fix.lat, fix.lon),
                    ],
                    height: 190,
                    wgs84: true,
                  ),
                ],
              ],
              if (_outdoor) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: VStat(
                        label: '距离',
                        value: _liveDistanceKm.toStringAsFixed(2),
                        unit: 'km',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: '实时速度',
                        value: (_gps.speedMps.value * 3.6).toStringAsFixed(1),
                        unit: 'km/h',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: '当前心率',
                        value: _currentHr > 0 ? '$_currentHr' : '--',
                        unit: 'bpm',
                      ),
                    ),
                  ],
                ),
                if (_cycling) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: VStat(
                          label: '当前功率',
                          value: _powerWatts > 0
                              ? _powerWatts.round().toString()
                              : '--',
                          unit: 'W',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VStat(
                          label: '平均功率',
                          value: _avgPower > 0 ? '$_avgPower' : '--',
                          unit: 'W',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VStat(
                          label: '最大功率',
                          value: _powerMax > 0
                              ? _powerMax.round().toString()
                              : '--',
                          unit: 'W',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: VStat(
                        label: '平均配速',
                        value: _liveDistanceKm >= 0.01
                            ? fmtPace(_liveDistanceKm * 1000, _seconds)
                            : '--',
                        unit: '/km',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: '热量',
                        value: '$_calories',
                        unit: '千卡',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: '海拔',
                        value: _altitude > 0
                            ? _altitude.toStringAsFixed(0)
                            : '--',
                        unit: 'm',
                      ),
                    ),
                  ],
                ),
                if (_avgHr > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: VStat(
                          label: '爬升',
                          value: _ascentM > 0
                              ? _ascentM.toStringAsFixed(0)
                              : '0',
                          unit: 'm',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VStat(
                          label: '平均心率',
                          value: '$_avgHr',
                          unit: 'bpm',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VStat(
                          label: '最大心率',
                          value: '$_hrMax',
                          unit: 'bpm',
                        ),
                      ),
                    ],
                  ),
                ],
              ] else ...[
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: '热量',
                        value: '$_calories',
                        unit: '千卡',
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: '时长',
                        value: _fmt(_seconds),
                        unit: '',
                      ),
                    ),
                  ],
                ),
              ],
              const Spacer(),
              if (!_started)
                VPrimaryButton(
                  label: '开始${widget.title}',
                  icon: Icons.play_arrow_rounded,
                  onTap: _saving ? null : _start,
                )
              else ...[
                VPrimaryButton(
                  label: '结束并保存',
                  icon: Icons.stop_rounded,
                  onTap: _saving ? null : _finish,
                ),
                const SizedBox(height: 10),
                VGhostButton(
                  label: _running ? '暂停' : '继续',
                  icon: _running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onTap: _saving ? null : (_running ? _pause : _start),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmQuit() {
    if (!_started) return Future.value(true);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃这次运动？'),
        content: const Text('放弃后不会留下记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续运动'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Column(
      children: [
        Text(label, style: VText.label.copyWith(color: v.muted)),
        const SizedBox(height: 4),
        Text.rich(
          TextSpan(
            text: value,
            style: VText.value.copyWith(fontSize: 24, color: v.ink),
            children: [
              TextSpan(
                text: ' $unit',
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
