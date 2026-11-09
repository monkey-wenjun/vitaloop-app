import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/gps_bridge.dart';
import '../../data/map_display.dart';
import '../../data/navigation_reroute_policy.dart';
import '../../data/place_search.dart';
import '../../data/road_snapper.dart';
import '../../data/tts_bridge.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/coordinate.dart';
import '../../util/format.dart';
import '../amap_route_map.dart';
import '../components.dart';

/// 手表运动实时码表：手表开运动后自动弹出，数据来自 0x37 联动帧或 0x17 实时帧。
class WorkoutLiveScreen extends StatefulWidget {
  const WorkoutLiveScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WorkoutLiveScreen> createState() => _WorkoutLiveScreenState();
}

class _WorkoutLiveScreenState extends State<WorkoutLiveScreen> {
  final _bridge = WatchBridge.instance;
  final _gps = GpsBridge.instance;
  Timer? _ticker;
  int _now = DateTime.now().millisecondsSinceEpoch;
  int _endDismissedAt = 0;
  bool _phoneGpsStarted = false;
  bool _phoneGpsOneShotDone = false;
  int _phoneGpsStartedAt = 0;
  bool _stopPhoneGpsOnDispose = false;
  int _phoneGpsRetryAt = 0;
  GpsFix? _lastKnown;
  List<Offset> _targetPoints = const [];
  List<Offset> _supplyPoints = const [];
  List<RoadRouteOption> _routeOptions = const [];
  int _selectedRouteIndex = 0;
  PlaceResult? _destination;
  String _routeJson = '';
  double _targetDistanceM = 0;
  bool _routePlanning = false;
  bool _markingSupply = false;
  String _navInstruction = '';
  double _navRemainingM = 0;
  bool _navOffRoute = false;
  bool _navArrived = false;
  bool _navBusy = false;
  int _lastGuidanceTs = 0;
  int _navSpokenAt = 0;
  String _navSpokenKey = '';
  bool _canAutoReroute = false;
  int? _offRouteSinceMs;
  int _lastAutoRerouteMs = 0;

  @override
  void initState() {
    super.initState();
    unawaited(MapDisplaySettings.instance.load());
    _bridge.refreshWorkoutRealtimeStatus();
    _bridge.liveSnapshot();
    unawaited(_loadLastKnown());
    _maybeStartPhoneGps();
    unawaited(_gps.keepScreenOn(true));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now().millisecondsSinceEpoch);
      if (_phoneGpsStarted &&
          (_bridge.workoutTrack.value.isNotEmpty ||
              _gps.fixes.value.isNotEmpty ||
              _now - _phoneGpsStartedAt >= 20000)) {
        _releasePhoneGps();
        _phoneGpsOneShotDone = true;
      }
      _maybeStartPhoneGps();
      _tickNavigation();
    });
  }

  Future<void> _loadLastKnown() async {
    final fix = await _gps.lastKnown();
    if (!mounted || fix == null) return;
    setState(() => _lastKnown = fix);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _releasePhoneGps();
    unawaited(_gps.keepScreenOn(false));
    super.dispose();
  }

  void _maybeStartPhoneGps() {
    if (_phoneGpsStarted) return;
    if (_phoneGpsOneShotDone) return;
    if (_bridge.workoutTrack.value.isNotEmpty) return;
    if (DateTime.now().millisecondsSinceEpoch < _phoneGpsRetryAt) return;
    // 旧版实时页一打开就有地图：先让手机定位兜底，不等手表第一帧。
    // 手表轨迹一旦出现就停掉手机 GPS，避免两路轨迹混在一起。
    final wasActive = _gps.active.value;
    if (!wasActive) _gps.reset();
    _phoneGpsStarted = true;
    _phoneGpsStartedAt = DateTime.now().millisecondsSinceEpoch;
    _stopPhoneGpsOnDispose = !wasActive;
    unawaited(
      _gps.start().then((ok) {
        if (ok || !mounted) return;
        _phoneGpsStarted = false;
        _stopPhoneGpsOnDispose = false;
        _phoneGpsRetryAt = DateTime.now().millisecondsSinceEpoch + 10000;
      }),
    );
  }

  void _releasePhoneGps() {
    if (!_phoneGpsStarted) return;
    _phoneGpsStarted = false;
    _phoneGpsStartedAt = 0;
    if (!_stopPhoneGpsOnDispose) return;
    _stopPhoneGpsOnDispose = false;
    unawaited(_gps.stop());
  }

  String _sportName(int code) => switch (code) {
    1 => '跑步',
    2 => '步行',
    3 => '骑行',
    4 => '徒步',
    5 => '室内跑步',
    6 => '泳池游泳',
    7 => '室内骑行',
    8 => '公开水域游泳',
    9 => '登山',
    10 => '越野跑',
    11 => '椭圆机',
    12 => '划船机',
    13 => '跳绳',
    14 || -116 => '力量训练',
    15 => '拉伸',
    16 => '瑜伽',
    17 => '普拉提',
    18 => '舞蹈',
    19 => '动感单车',
    20 => '自由训练',
    21 => '核心训练',
    22 => 'HIIT',
    23 => '踏步机',
    24 => '漫步机',
    _ => '手表运动',
  };

  static bool _isCyclingSport(int? code) =>
      code == 3 || code == 7 || code == 19;

  ({Offset point, bool wgs84, int ts})? _latestPosition() {
    final watch = _bridge.workoutTrack.value;
    if (watch.isNotEmpty) {
      final p = watch.last;
      return (point: Offset(p.lat, p.lon), wgs84: false, ts: p.ts);
    }
    final phone = _gps.fixes.value;
    if (phone.isNotEmpty) {
      final p = phone.last;
      return (point: Offset(p.lat, p.lon), wgs84: true, ts: p.ts);
    }
    final known = _lastKnown;
    if (known != null) {
      return (point: Offset(known.lat, known.lon), wgs84: true, ts: known.ts);
    }
    return null;
  }

  static Offset _gcj(Offset point, bool wgs84) {
    if (!wgs84) return point;
    final (lat, lon) = Coordinate.wgs84ToGcj02(point.dx, point.dy);
    return Offset(lat, lon);
  }

  static double _distanceMeters(Offset a, Offset b) {
    const r = 6371000.0;
    final lat1 = a.dx * 0.017453292519943295;
    final lat2 = b.dx * 0.017453292519943295;
    final dLat = (b.dx - a.dx) * 0.017453292519943295;
    final dLon = (b.dy - a.dy) * 0.017453292519943295;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  static double _pathDistanceMeters(List<Offset> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _distanceMeters(points[i - 1], points[i]);
    }
    return total;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _searchDestination() async {
    if (_routePlanning) return;
    final picked = await showModalBottomSheet<PlaceResult>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _DestinationPicker(),
    );
    if (picked == null || !mounted) return;
    await _planRoute(picked);
  }

  Future<void> _importPlannedRoute() async {
    if (_routePlanning) return;
    final route = await showModalBottomSheet<SavedRoute>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _SavedRoutePicker(),
    );
    if (route == null || !mounted) return;
    if (route.points.length < 2) {
      _showMessage('这条路线没有足够的轨迹点');
      return;
    }
    _setTargetRoute(route.name, [
      for (final p in route.points) Offset(p.lat, p.lon),
    ]);
    _showMessage('已导入路线「${route.name}」');
    _tickNavigation(force: true);
  }

  void _setTargetRoute(
    String name,
    List<Offset> points, {
    bool canAutoReroute = false,
    List<RoadRouteOption> options = const [],
    int selectedRouteIndex = 0,
  }) {
    final end = points.last;
    setState(() {
      _destination = PlaceResult(
        name: name,
        address: '',
        lat: end.dx,
        lon: end.dy,
      );
      _targetPoints = points;
      _targetDistanceM = _pathDistanceMeters(points);
      _routeOptions = options;
      _selectedRouteIndex = selectedRouteIndex;
      _canAutoReroute = canAutoReroute;
      _supplyPoints = const [];
      _routeJson = jsonEncode([
        for (final p in points) {'lat': p.dx, 'lon': p.dy},
      ]);
      _navInstruction = '';
      _navRemainingM = 0;
      _navOffRoute = false;
      _navArrived = false;
      _navBusy = false;
      _lastGuidanceTs = 0;
      _navSpokenKey = '';
      _offRouteSinceMs = null;
    });
  }

  Future<void> _planRoute(
    PlaceResult destination, {
    bool automatic = false,
  }) async {
    if (_routePlanning) return;
    final position = _latestPosition();
    if (position == null) {
      if (!automatic) _showMessage('定位中，请稍候再规划路线');
      return;
    }
    setState(() {
      _routePlanning = true;
      _markingSupply = false;
    });
    try {
      final start = _gcj(position.point, position.wgs84);
      final result = await RoadSnapper.snap(
        [
          GeoPoint(lat: start.dx, lon: start.dy),
          GeoPoint(lat: destination.lat, lon: destination.lon),
        ],
        ride: _isCyclingSport(_bridge.workoutLive.value?.sport),
        alternativeCount: automatic ? 1 : 3,
      );
      if (!mounted) return;
      // 单段路线吸附失败时 RoadSnapper 只返回起点和终点。不要把这条直线
      // 当成“已沿道路规划”，否则导航距离和转向全是错的。
      if (result.points.length < 3 && result.straightLegs > 0) {
        if (!automatic) {
          _showMessage('路线服务没有找到道路，请检查网络后重试');
        }
        return;
      }
      var options = result.options;
      if (options.isEmpty) {
        options = [
          RoadRouteOption(
            points: result.points,
            distanceM: _pathDistanceMeters([
              for (final p in result.points) Offset(p.lat, p.lon),
            ]),
            durationS: 0,
          ),
        ];
      }
      var selectedIndex = 0;
      if (!automatic && options.length > 1) {
        final picked = await _pickRouteOption(options);
        if (!mounted || picked == null) return;
        selectedIndex = picked;
      }
      final selected = options[selectedIndex];
      final points = [for (final p in selected.points) Offset(p.lat, p.lon)];
      _setTargetRoute(
        destination.name,
        points,
        canAutoReroute: true,
        options: options,
        selectedRouteIndex: selectedIndex,
      );
      _showMessage(
        automatic
            ? '已根据当前位置重新规划路线'
            : result.straightLegs == 0
            ? '已按道路规划到 ${destination.name}'
            : '路线已生成，有 ${result.straightLegs} 段未找到路网',
      );
      _tickNavigation(force: true);
    } catch (_) {
      if (!automatic) _showMessage('路线规划失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _routePlanning = false);
    }
  }

  Future<int?> _pickRouteOption(List<RoadRouteOption> options) {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final v = sheetContext.v;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Text('选择路线', style: VText.h2.copyWith(color: v.ink)),
              const SizedBox(height: 6),
              Text(
                '优先选择更接近你常走路线的方案',
                style: VText.label.copyWith(color: v.muted),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < options.length; i++)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(
                    i == 0 ? Icons.recommend_rounded : Icons.alt_route_rounded,
                    color: i == _selectedRouteIndex ? v.blueInk : v.muted,
                  ),
                  title: Text(
                    i == 0 ? '推荐路线' : '备选路线 $i',
                    style: VText.body.copyWith(
                      color: v.ink,
                      fontWeight: i == _selectedRouteIndex
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    _routeOptionLabel(options[i]),
                    style: VText.label.copyWith(color: v.muted),
                  ),
                  trailing: i == _selectedRouteIndex
                      ? Icon(Icons.check_rounded, color: v.blueInk)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, i),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _routeOptionLabel(RoadRouteOption option) {
    final distance = option.distanceM > 0
        ? '${(option.distanceM / 1000).toStringAsFixed(1)} km'
        : '距离未知';
    if (option.durationS <= 0) return distance;
    final minutes = (option.durationS / 60).round();
    final duration = minutes >= 60
        ? '${minutes ~/ 60} 小时 ${minutes % 60} 分'
        : '$minutes 分钟';
    return '$distance · $duration';
  }

  Future<void> _switchRoute() async {
    if (_routeOptions.length < 2 || _routePlanning) return;
    final picked = await _pickRouteOption(_routeOptions);
    final destination = _destination;
    if (!mounted || picked == null || destination == null) return;
    final selected = _routeOptions[picked];
    _setTargetRoute(
      destination.name,
      [for (final p in selected.points) Offset(p.lat, p.lon)],
      canAutoReroute: true,
      options: _routeOptions,
      selectedRouteIndex: picked,
    );
    _showMessage('已切换路线');
    _tickNavigation(force: true);
  }

  void _stopNavigation() {
    unawaited(TtsBridge.instance.stop());
    setState(() {
      _destination = null;
      _targetPoints = const [];
      _supplyPoints = const [];
      _routeOptions = const [];
      _selectedRouteIndex = 0;
      _routeJson = '';
      _targetDistanceM = 0;
      _markingSupply = false;
      _navInstruction = '';
      _navRemainingM = 0;
      _navOffRoute = false;
      _navArrived = false;
      _lastGuidanceTs = 0;
      _navSpokenKey = '';
      _canAutoReroute = false;
      _offRouteSinceMs = null;
      _lastAutoRerouteMs = 0;
    });
  }

  void _toggleMarkerInterval() {
    final settings = MapDisplaySettings.instance;
    unawaited(
      settings.setMarkerIntervalM(
        settings.markerIntervalM == 1000 ? 5000 : 1000,
      ),
    );
  }

  void _onMapTap(double lat, double lon) {
    if (!_markingSupply) return;
    setState(() {
      _supplyPoints = [..._supplyPoints, Offset(lat, lon)];
      _markingSupply = false;
    });
    _showMessage('已标记补给点');
  }

  void _tickNavigation({bool force = false}) {
    if (_routeJson.isEmpty || _navBusy || _navArrived || _routePlanning) {
      return;
    }
    if (_bridge.workoutTrack.value.length < 2 && _gps.fixes.value.length < 2) {
      return;
    }
    final position = _latestPosition();
    if (position == null) return;
    if (!force && position.ts <= _lastGuidanceTs) return;
    _lastGuidanceTs = position.ts;
    final point = _gcj(position.point, position.wgs84);
    final routeJson = _routeJson;
    var autoReroute = false;
    _navBusy = true;
    unawaited(() async {
      try {
        final raw = await VitaloopApi.routeGuidance(
          routeJson: routeJson,
          lat: point.dx,
          lon: point.dy,
        );
        final data = jsonDecode(raw);
        if (!mounted || data is! Map || routeJson != _routeJson) return;
        final instruction = data['instruction'] as String? ?? '';
        final remaining = (data['remaining_m'] as num?)?.toDouble() ?? 0;
        final offRoute = data['off_route'] == true;
        final offRouteM = (data['off_route_m'] as num?)?.toDouble() ?? 0;
        final arrived = data['arrived'] == true;
        final turn = data['turn'] as String? ?? 'straight';
        final toTurn = (data['to_turn_m'] as num?)?.toDouble() ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (!_canAutoReroute ||
            !offRoute ||
            offRouteM < autoRerouteMinDistanceM) {
          _offRouteSinceMs = null;
        } else {
          _offRouteSinceMs ??= now;
          autoReroute = shouldAutoReroute(
            enabled: _canAutoReroute && _destination != null,
            offRoute: offRoute,
            offRouteM: offRouteM,
            offRouteSinceMs: _offRouteSinceMs,
            nowMs: now,
            lastRerouteMs: _lastAutoRerouteMs,
          );
          if (autoReroute) {
            _lastAutoRerouteMs = now;
            _offRouteSinceMs = null;
          }
        }
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
        // 单次导航计算失败不能影响运动记录，下一秒继续试。
      } finally {
        _navBusy = false;
        final destination = _destination;
        if (autoReroute && mounted && destination != null) {
          unawaited(_planRoute(destination, automatic: true));
        }
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

  // 实时指标统一按三列网格铺开：配速/平均配速/最大心率对跑步和骑行都展示，
  // 其余（热量/踏频/功率…）只在有值时出现，避免 0 值噪声。
  Widget _liveMetrics(
    WatchLiveFrame? frame,
    double speed,
    String pace,
    String avgPace,
  ) {
    List<String>? cell(String label, String value, String unit) => <String>[
      label,
      value,
      unit,
    ];
    final cells = <List<String>?>[
      cell('速度', speed.toStringAsFixed(1), 'km/h'),
      cell('配速', pace, '/km'),
      cell('平均配速', avgPace, '/km'),
      cell('心率', '${frame?.heartRate ?? 0}', 'bpm'),
      if ((frame?.maxHeartRate ?? 0) > 0)
        cell('最大心率', '${frame!.maxHeartRate}', 'bpm'),
      if ((frame?.averageHeartRate ?? 0) > 0)
        cell('均心', '${frame!.averageHeartRate}', 'bpm'),
      cell('热量', '${frame?.calories ?? 0}', 'kcal'),
      if ((frame?.altitude ?? 0) > 0) cell('海拔', '${frame!.altitude}', 'm'),
      if ((frame?.climb ?? 0) > 0) cell('爬升', '${frame!.climb}', 'm'),
      if ((frame?.cadence ?? 0) > 0) cell('踏频', '${frame!.cadence}', 'rpm'),
      if ((frame?.power ?? 0) > 0) cell('功率', '${frame!.power}', 'W'),
    ];
    while (cells.length % 3 != 0) {
      cells.add(null);
    }
    Widget tile(List<String>? c) => c == null
        ? const Expanded(child: SizedBox(height: 38))
        : Expanded(
            child: VStat(label: c[0], value: c[1], unit: c[2]),
          );
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 3) {
      if (i > 0) rows.add(const SizedBox(height: 8));
      rows.add(
        Row(
          children: [
            tile(cells[i]),
            const SizedBox(width: 8),
            tile(cells[i + 1]),
            const SizedBox(width: 8),
            tile(cells[i + 2]),
          ],
        ),
      );
    }
    return Column(children: rows);
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final safeTop = MediaQuery.paddingOf(context).top;
    final mapInsets = EdgeInsets.fromLTRB(
      24,
      safeTop + 84,
      24,
      screenHeight * 0.46,
    );
    return Scaffold(
      backgroundColor: v.bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          _bridge.workoutLive,
          _bridge.workoutTrack,
          _bridge.workoutEnded,
          _gps.fixes,
          MapDisplaySettings.instance,
        ]),
        builder: (context, _) {
          final frame = _bridge.workoutLive.value;
          final watchPoints = _bridge.workoutTrack.value;
          final phonePoints = _gps.fixes.value;
          final points = watchPoints.isNotEmpty
              ? [for (final p in watchPoints) Offset(p.lat, p.lon)]
              : [for (final p in phonePoints) Offset(p.lat, p.lon)];
          final cycling = _isCyclingSport(frame?.sport);
          final known = _lastKnown;
          final mapPoints = points.isNotEmpty || known == null
              ? points
              : [Offset(known.lat, known.lon)];
          final currentPoint = mapPoints.isEmpty ? null : mapPoints.last;
          final ended = _bridge.workoutEnded.value;
          final waiting = ended == null && frame == null;
          final hasActualTrack =
              watchPoints.length >= 2 || phonePoints.length >= 2;
          final routePreview = _targetPoints.isNotEmpty && !hasActualTrack;
          final stale =
              ended == null &&
              frame != null &&
              _now - frame.lastFrameAt > (frame.pulled ? 75000 : 15000);
          final startedAt = frame?.startedAt ?? 0;
          final seconds = startedAt <= 0
              ? 0
              : ((_now - startedAt) / 1000).round().clamp(0, 24 * 3600);
          final distance = frame?.distanceM ?? 0;
          final speed = frame?.speedKmh ?? 0;
          final pace = speed > 0 ? fmtPace(1000, (3600 / speed).round()) : '--';
          final avgPace = fmtPace(distance, seconds);
          final source = waiting
              ? '等待手表'
              : watchPoints.isNotEmpty
              ? '手表轨迹'
              : (phonePoints.isNotEmpty ? '本机定位' : '等待定位');

          if (ended != null && ended.at != _endDismissedAt) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || ended.at == _endDismissedAt) return;
              _showEnded(ended);
            });
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                // 骑行实时页之前固定用渐变背景，手表把轨迹投过来后也看不到地图。
                // 有定位/轨迹就铺高德地图；还没拿到任何点时再用等待背景，避免停在海上。
                child: cycling && mapPoints.isEmpty
                    ? _CyclingBackdrop(
                        speed: speed,
                        waiting: waiting,
                        stale: stale,
                        ended: ended != null,
                      )
                    : AmapRouteMap(
                        points: mapPoints,
                        height: null,
                        radius: 0,
                        fitInsets: mapInsets,
                        // 手表联动帧在 Android 侧已转成 GCJ-02；只有手机定位兜底
                        // 还是 WGS-84。
                        wgs84: watchPoints.isEmpty,
                        currentPoint: currentPoint,
                        targetPoints: _targetPoints,
                        supplyPoints: _supplyPoints,
                        followCurrentPoint:
                            _targetPoints.isEmpty || hasActualTrack,
                        showEndpoints: false,
                        onTapPoint: _onMapTap,
                      ),
              ),
              if (waiting && _targetPoints.isEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: MediaQuery.paddingOf(context).top + 78,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: v.surface.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.watch_rounded,
                                size: 18,
                                color: v.muted,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '等待手表开始运动',
                                style: VText.label.copyWith(
                                  color: v.ink,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                points.isEmpty
                                    ? (cycling ? '· 等待码表数据' : '· 定位中')
                                    : (cycling ? '· 码表已就绪' : '· 地图已就绪'),
                                style: VText.label.copyWith(
                                  fontSize: 10.5,
                                  color: v.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.26),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.2),
                        ],
                        stops: const [0, 0.42, 1],
                      ),
                    ),
                  ),
                ),
              ),
              if (_targetPoints.isNotEmpty || _routePlanning)
                Positioned(
                  left: 12,
                  right: 72,
                  top: safeTop + 72,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
                    decoration: BoxDecoration(
                      color: v.glass,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: v.line),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          routePreview
                              ? Icons.alt_route_rounded
                              : _navArrived
                              ? Icons.flag_rounded
                              : (_navOffRoute
                                    ? Icons.wrong_location_rounded
                                    : Icons.navigation_rounded),
                          size: 22,
                          color: routePreview
                              ? v.blueInk
                              : _navArrived
                              ? v.greenInk
                              : (_navOffRoute ? v.warnInk : v.blueInk),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _routePlanning
                                    ? '正在沿道路规划…'
                                    : routePreview
                                    ? '路线已导入，准备前往起点'
                                    : _navArrived
                                    ? '已到达目的地'
                                    : _navOffRoute
                                    ? (_canAutoReroute
                                          ? '已偏航，将自动重新规划'
                                          : '已偏航，请返回路线')
                                    : (_navInstruction.isEmpty
                                          ? '沿蓝色虚线路线前进'
                                          : _navInstruction),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: VText.label.copyWith(
                                  color: !routePreview && _navOffRoute
                                      ? v.warnInk
                                      : v.ink,
                                  fontWeight: FontWeight.w800,
                                  height: 1.3,
                                ),
                              ),
                              if (!_routePlanning) ...[
                                const SizedBox(height: 2),
                                Text(
                                  routePreview
                                      ? '全程 ${(_targetDistanceM / 1000).toStringAsFixed(2)} km · ${_destination?.name ?? "规划路线"}'
                                      : '${(_navRemainingM / 1000).toStringAsFixed(2)} km · ${_destination?.name ?? "目的地"}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: VText.label.copyWith(
                                    fontSize: 9.5,
                                    color: v.muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _stopNavigation,
                          tooltip: '结束导航',
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.close_rounded, color: v.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                right: 12,
                top: safeTop + 72,
                child: Column(
                  children: [
                    _MapAction(
                      icon: Icons.search_rounded,
                      tooltip: '搜索目的地',
                      busy: _routePlanning,
                      onTap: _routePlanning ? null : _searchDestination,
                    ),
                    if (_routeOptions.length > 1) ...[
                      const SizedBox(height: 8),
                      _MapAction(
                        icon: Icons.fork_right_rounded,
                        tooltip: '切换路线',
                        onTap: _routePlanning ? null : _switchRoute,
                      ),
                    ],
                    const SizedBox(height: 8),
                    _MapAction(
                      icon: Icons.alt_route_rounded,
                      tooltip: '导入规划路线',
                      onTap: _routePlanning ? null : _importPlannedRoute,
                    ),
                    const SizedBox(height: 8),
                    _MapAction(
                      label:
                          '${MapDisplaySettings.instance.markerIntervalM ~/ 1000}km',
                      tooltip:
                          '每 ${MapDisplaySettings.instance.markerIntervalM ~/ 1000} 公里标记（点击切换）',
                      onTap: _toggleMarkerInterval,
                    ),
                    if (_targetPoints.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _MapAction(
                        icon: Icons.add_location_alt_rounded,
                        tooltip: '标记补给点',
                        active: _markingSupply,
                        onTap: () {
                          setState(() => _markingSupply = !_markingSupply);
                          _showMessage(
                            _markingSupply ? '点击地图标记补给点' : '已取消标记补给点',
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: v.glass,
                            foregroundColor: v.ink,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: v.glass,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _sportName(frame?.sport ?? 0),
                                        style: VText.h3.copyWith(color: v.ink),
                                      ),
                                      Text(
                                        waiting
                                            ? '$source · 实时码表'
                                            : '$source · ${frame?.pulled == true ? "定时拉取" : "手表实时"}',
                                        style: VText.label.copyWith(
                                          fontSize: 9.5,
                                          color: v.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  ended != null
                                      ? '已结束'
                                      : waiting
                                      ? '等待手表'
                                      : (stale ? '数据中断' : '运动中'),
                                  style: VText.label.copyWith(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: ended != null
                                        ? v.muted
                                        : (stale ? v.danger : v.greenInk),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: SafeArea(
                  top: false,
                  child: VCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              (distance / 1000).toStringAsFixed(2),
                              style: VText.value.copyWith(
                                fontSize: cycling ? 34 : 44,
                                height: 0.95,
                                color: v.ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                'km',
                                style: VText.label.copyWith(color: v.muted),
                              ),
                            ),
                            const Spacer(),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '用时',
                                  style: VText.label.copyWith(
                                    fontSize: 10,
                                    color: v.muted,
                                  ),
                                ),
                                Text(
                                  fmtDuration(seconds),
                                  style: VText.value.copyWith(
                                    fontSize: 25,
                                    color: v.ink,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _liveMetrics(frame, speed, pace, avgPace),
                        if (stale && ended == null) ...[
                          const SizedBox(height: 10),
                          Text(
                            '手表暂时没有推数据。确认手表端「运动数据推送手机」已打开，并保持手表与 App 连接。',
                            style: VText.label.copyWith(
                              fontSize: 10.5,
                              color: v.danger,
                              height: 1.45,
                            ),
                          ),
                        ],
                        if (waiting) ...[
                          const SizedBox(height: 10),
                          Text(
                            '在手表上开始运动后，这里会自动同步距离、心率与轨迹。',
                            style: VText.label.copyWith(
                              fontSize: 10.5,
                              color: v.muted,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showEnded(WatchLiveEnd ended) async {
    if (_endDismissedAt == ended.at) return;
    _endDismissedAt = ended.at;
    final frame = _bridge.workoutLive.value;
    final close = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.v.surface,
        icon: Icon(Icons.check_circle_rounded, color: ctx.v.greenInk, size: 34),
        title: Text('手表已结束运动', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '距离 ${((frame?.distanceM ?? 0) / 1000).toStringAsFixed(2)} km · '
          '热量 ${frame?.calories ?? 0} kcal\n${ended.reason}',
          style: VText.body.copyWith(color: ctx.v.ink2, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续查看'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (close == true && mounted) Navigator.of(context).maybePop();
  }
}

class _MapAction extends StatelessWidget {
  const _MapAction({
    this.icon,
    this.label,
    required this.tooltip,
    this.onTap,
    this.busy = false,
    this.active = false,
  });

  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool busy;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: active ? v.tintGreen : v.glass,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: v.blueInk,
                          ),
                        )
                      : icon != null
                      ? Icon(icon, size: 21, color: active ? v.greenInk : v.ink)
                      : Text(
                          label ?? '',
                          style: VText.label.copyWith(
                            color: v.ink,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SavedRoutePicker extends StatefulWidget {
  const _SavedRoutePicker();

  @override
  State<_SavedRoutePicker> createState() => _SavedRoutePickerState();
}

class _SavedRoutePickerState extends State<_SavedRoutePicker> {
  List<SavedRoute> _routes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final routes = await VitaloopApi.savedRoutes();
      if (!mounted) return;
      setState(() {
        _routes = routes;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导入规划路线', style: VText.h2.copyWith(color: v.ink)),
              const SizedBox(height: 4),
              Text(
                '直接作为蓝色目标路线，沿保存时的方向导航',
                style: VText.label.copyWith(color: v.muted),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _routes.isEmpty
                    ? Center(
                        child: Text(
                          '还没有保存路线，请先在「运动 → 已保存路线」中规划',
                          textAlign: TextAlign.center,
                          style: VText.body.copyWith(color: v.muted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _routes.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: v.line),
                        itemBuilder: (_, i) {
                          final route = _routes[i];
                          final date = DateTime.fromMillisecondsSinceEpoch(
                            route.createdMs,
                          );
                          return ListTile(
                            minVerticalPadding: 12,
                            leading: Icon(
                              Icons.alt_route_rounded,
                              color: v.greenInk,
                            ),
                            title: Text(
                              route.name,
                              style: VText.body.copyWith(color: v.ink),
                            ),
                            subtitle: Text(
                              '${(route.distanceM / 1000).toStringAsFixed(2)} km · '
                              '${route.points.length} 个点 · ${relativeDay(date)}',
                              style: VText.label.copyWith(color: v.muted),
                            ),
                            trailing: Icon(
                              Icons.chevron_right_rounded,
                              color: v.muted,
                            ),
                            onTap: () => Navigator.pop(context, route),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DestinationPicker extends StatefulWidget {
  const _DestinationPicker();

  @override
  State<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<_DestinationPicker> {
  final _input = TextEditingController();
  List<PlaceResult> _results = const [];
  bool _searching = false;
  bool _searched = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _input.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searched = false;
    });
    final results = await PlaceSearch.search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final height = (screenHeight * 0.72 - bottom).clamp(
      240.0,
      screenHeight * 0.72,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('搜索目的地', style: VText.h2.copyWith(color: v.ink)),
                const SizedBox(height: 10),
                TextField(
                  controller: _input,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    labelText: '地点或地址',
                    hintText: '例如：南湖天地',
                    prefixIcon: const Icon(Icons.place_rounded),
                    filled: true,
                    fillColor: v.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _searching ? null : _search,
                    icon: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search_rounded),
                    label: Text(_searching ? '正在搜索' : '搜索'),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: !_searched
                      ? Center(
                          child: Text(
                            '路线会从当前位置沿道路规划',
                            style: VText.body.copyWith(color: v.muted),
                          ),
                        )
                      : _results.isEmpty
                      ? Center(
                          child: Text(
                            '没有找到这个目的地，换个关键词试试',
                            style: VText.body.copyWith(color: v.muted),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: v.line),
                          itemBuilder: (_, i) {
                            final place = _results[i];
                            return ListTile(
                              minVerticalPadding: 12,
                              leading: Icon(
                                Icons.place_rounded,
                                color: v.greenInk,
                              ),
                              title: Text(
                                place.name,
                                style: VText.body.copyWith(color: v.ink),
                              ),
                              subtitle: place.address.isEmpty
                                  ? null
                                  : Text(
                                      place.address,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: VText.label.copyWith(
                                        color: v.muted,
                                      ),
                                    ),
                              onTap: () => Navigator.pop(context, place),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 骑行还没拿到定位时的等待背景；一旦有轨迹点就换成高德地图。
class _CyclingBackdrop extends StatelessWidget {
  const _CyclingBackdrop({
    required this.speed,
    required this.waiting,
    required this.stale,
    required this.ended,
  });

  final double speed;
  final bool waiting;
  final bool stale;
  final bool ended;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final accent = v.blue.withValues(alpha: v.isDark ? 0.30 : 0.18);
    final accent2 = v.greenInk.withValues(alpha: v.isDark ? 0.18 : 0.12);
    final stateText = ended
        ? '已结束'
        : waiting
        ? '等待手表'
        : stale
        ? '数据中断'
        : '骑行中';

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent, v.bg, accent2],
          stops: const [0, 0.52, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _SpeedRingPainter(
              color: v.ink.withValues(alpha: v.isDark ? 0.05 : 0.055),
              accent: v.blue.withValues(alpha: v.isDark ? 0.20 : 0.12),
            ),
          ),
          Align(
            alignment: const Alignment(0, -0.22),
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.directions_bike_rounded,
                        size: 17,
                        color: v.muted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        stateText,
                        style: VText.label.copyWith(
                          color: v.muted,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.8,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 230,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        speed.toStringAsFixed(1),
                        style: VText.num.copyWith(
                          fontSize: 92,
                          height: 0.95,
                          color: v.ink,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -5,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    'km/h',
                    style: VText.label.copyWith(
                      color: v.muted,
                      fontSize: 12,
                      letterSpacing: 2.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedRingPainter extends CustomPainter {
  const _SpeedRingPainter({required this.color, required this.accent});

  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.36);
    final radius = size.shortestSide * 0.36;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < 4; i++) {
      line.color = i == 1 ? accent : color;
      canvas.drawCircle(center, radius * (0.52 + i * 0.17), line);
    }

    final ticks = Paint()
      ..color = accent
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    for (var i = 0; i < 48; i++) {
      final angle = (i / 48) * 3.141592653589793 * 2 - 1.5707963267948966;
      final inner = radius * 0.87;
      final outer = radius * (i % 4 == 0 ? 0.96 : 0.92);
      canvas.drawLine(
        center + Offset.fromDirection(angle, inner),
        center + Offset.fromDirection(angle, outer),
        ticks,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedRingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.accent != accent;
}
