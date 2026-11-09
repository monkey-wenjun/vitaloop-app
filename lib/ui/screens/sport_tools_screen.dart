import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/gps_bridge.dart';
import '../../data/place_search.dart';
import '../../data/road_snapper.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/coordinate.dart';
import '../amap_route_map.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class RoutePlannerScreen extends StatefulWidget {
  const RoutePlannerScreen({super.key, this.route});

  /// 传入表示编辑已保存路线，为空则新建。
  final SavedRoute? route;

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  late final TextEditingController _name;
  late final TextEditingController _search;
  late final List<Offset> _points;
  Timer? _snapTimer;
  Offset? _currentPoint;
  bool _locating = false;
  int _recenterSignal = 0;
  bool _saving = false;
  bool _snapping = false;
  bool _searching = false;
  List<GeoPoint>? _snappedPoints;
  int _straightLegs = 0;
  int _snapRevision = 0;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.route?.name ?? '');
    _search = TextEditingController();
    _points = [
      for (final p in widget.route?.points ?? const <GeoPoint>[])
        Offset(p.lat, p.lon),
    ];
    unawaited(_locateCurrent());
    if (_points.length >= 2) unawaited(_snap());
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    _snapTimer?.cancel();
    super.dispose();
  }

  Future<GpsFix?> _waitForFirstFix() async {
    final existing = GpsBridge.instance.fixes.value;
    if (existing.isNotEmpty) return existing.last;
    final done = Completer<GpsFix?>();
    Timer? timeout;
    void listener() {
      final fixes = GpsBridge.instance.fixes.value;
      if (fixes.isNotEmpty && !done.isCompleted) {
        done.complete(fixes.last);
      }
    }

    GpsBridge.instance.fixes.addListener(listener);
    timeout = Timer(const Duration(seconds: 6), () {
      if (!done.isCompleted) done.complete(null);
    });
    try {
      return await done.future;
    } finally {
      timeout.cancel();
      GpsBridge.instance.fixes.removeListener(listener);
    }
  }

  Future<void> _locateCurrent({bool recenter = false}) async {
    if (_locating && !recenter) return;
    if (mounted) setState(() => _locating = true);
    var fix = await GpsBridge.instance.lastKnown();
    var started = false;
    if (fix == null && !GpsBridge.instance.active.value) {
      if (await GpsBridge.instance.requestPermissions()) {
        started = await GpsBridge.instance.start();
      }
    }
    if (fix == null && (started || GpsBridge.instance.active.value)) {
      fix = await _waitForFirstFix();
    }
    if (started) await GpsBridge.instance.stop();
    if (!mounted) return;
    if (fix != null) {
      final (lat, lon) = Coordinate.wgs84ToGcj02(fix.lat, fix.lon);
      setState(() {
        _currentPoint = Offset(lat, lon);
        _locating = false;
        if (recenter) _recenterSignal++;
      });
      _scheduleSnap();
      return;
    }
    setState(() => _locating = false);
    if (recenter) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法获取当前位置，请检查定位权限')));
    }
  }

  double get _distanceM {
    var sum = 0.0;
    final points = _routePoints;
    for (var i = 1; i < points.length; i++) {
      sum += _haversine(
        Offset(points[i - 1].lat, points[i - 1].lon),
        Offset(points[i].lat, points[i].lon),
      );
    }
    return sum;
  }

  List<GeoPoint> get _routePoints =>
      _snappedPoints ??
      [for (final p in _points) GeoPoint(lat: p.dx, lon: p.dy)];

  static double _haversine(Offset a, Offset b) {
    const r = 6371000.0;
    final lat1 = a.dx * math.pi / 180;
    final lat2 = b.dx * math.pi / 180;
    final dLat = lat2 - lat1;
    final dLon = (b.dy - a.dy) * math.pi / 180;
    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  void _addPoint(double lat, double lon) {
    setState(() {
      if (_points.isEmpty && _currentPoint != null) {
        _points.add(_currentPoint!);
      }
      _points.add(Offset(lat, lon));
      _snappedPoints = null;
      _snapRevision++;
    });
    _scheduleSnap();
  }

  void _undo() {
    if (_points.isEmpty) return;
    setState(() {
      _points.removeLast();
      _snappedPoints = null;
      _snapRevision++;
    });
    _scheduleSnap();
  }

  void _clearPoints() {
    setState(() {
      _points.clear();
      _snappedPoints = null;
      _straightLegs = 0;
      _snapRevision++;
    });
  }

  Future<RoadSnapResult?> _snap() async {
    if (_points.length < 2 || _snapping) return null;
    final revision = _snapRevision;
    setState(() => _snapping = true);
    try {
      final result = await RoadSnapper.snap(_routePoints, ride: false);
      if (!mounted || revision != _snapRevision) return null;
      setState(() {
        _snappedPoints = result.points;
        _straightLegs = result.straightLegs;
      });
      return result;
    } finally {
      if (mounted) setState(() => _snapping = false);
    }
  }

  void _scheduleSnap() {
    _snapTimer?.cancel();
    if (_points.length < 2) return;
    _snapTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(_snap());
    });
  }

  Future<void> _searchDestination() async {
    final query = _search.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() => _searching = true);
    final results = await PlaceSearch.search(query);
    if (!mounted) return;
    setState(() => _searching = false);
    if (results.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有找到这个目的地，换个关键词试试')));
      return;
    }
    final picked = await showModalBottomSheet<PlaceResult>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final v = ctx.v;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Text('选择目的地', style: VText.h2.copyWith(color: v.ink)),
              const SizedBox(height: 6),
              for (final place in results)
                ListTile(
                  leading: Icon(Icons.place_rounded, color: v.greenInk),
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
                          style: VText.label.copyWith(color: v.muted),
                        ),
                  onTap: () => Navigator.pop(ctx, place),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    if (_currentPoint == null) await _locateCurrent();
    if (!mounted) return;
    final start = _currentPoint;
    if (start == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先允许定位，才能从当前位置规划路线')));
      return;
    }
    setState(() {
      _points
        ..clear()
        ..add(start)
        ..add(Offset(picked.lat, picked.lon));
      _snappedPoints = null;
      _straightLegs = 0;
      _snapRevision++;
    });
    await _snap();
  }

  Future<void> _save({bool pushToWatch = false}) async {
    if (_points.length < 2) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少点出起点和终点')));
      return;
    }
    if (_snappedPoints == null) {
      while (_snapping) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await _snap();
      if (!mounted) return;
    }
    final ok = await _askName();
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final routePoints = _routePoints;
      await VitaloopApi.saveRoute(
        id: widget.route?.id ?? '',
        name: _name.text.trim(),
        points: routePoints,
      );
      if (!mounted) return;
      if (pushToWatch) {
        final result = await WatchBridge.instance.pushRoute(
          name: _name.text.trim(),
          distanceMeters: _distanceM,
          points: routePoints,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message'] as String? ?? '路线发送完成')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _straightLegs == 0
                  ? '路线已保存到本机'
                  : '路线已保存 · $_straightLegs 段没找到路网，按直线连接',
            ),
          ),
        );
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<bool?> _askName() {
    final v = context.v;
    if (_name.text.trim().isEmpty) _name.text = '路线 ${_points.length} 点';
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          20 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('保存路线', style: VText.h2.copyWith(color: v.ink)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('路线名称'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            VPrimaryButton(
              label: '保存',
              icon: Icons.bookmark_add_rounded,
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final distance = _distanceM / 1000;
    final mapHeight = (MediaQuery.sizeOf(context).height * 0.55).clamp(
      380.0,
      620.0,
    );
    final hasRoute = _points.length >= 2;
    final status = _locating && _currentPoint == null
        ? '正在获取当前位置…'
        : !hasRoute
        ? (_points.isEmpty ? '当前位置会自动作为起点，点地图选择终点' : '再选择一个位置作为终点')
        : null;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(
              title: widget.route == null ? '规划路线' : '编辑路线',
              trailing: TextButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ),
            SizedBox(
              height: mapHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AmapRouteMap(
                      points: [
                        for (final p in _routePoints) Offset(p.lat, p.lon),
                      ],
                      height: null,
                      radius: 28,
                      currentPoint: _currentPoint,
                      onTapPoint: _addPoint,
                      recenterSignal: _recenterSignal,
                      fitInsets: const EdgeInsets.fromLTRB(24, 92, 24, 76),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: Material(
                      color: v.surface.withValues(alpha: 0.96),
                      elevation: 3,
                      borderRadius: BorderRadius.circular(18),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          Icon(Icons.search_rounded, color: v.muted, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) => _searchDestination(),
                              decoration: InputDecoration(
                                hintText: tr('搜索目的地'),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          if (_searching)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          else
                            IconButton(
                              onPressed: _searchDestination,
                              icon: const Icon(Icons.arrow_forward_rounded),
                              tooltip: tr('搜索目的地'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Material(
                      color: v.surface,
                      elevation: 3,
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: _locating
                            ? null
                            : () => _locateCurrent(recenter: true),
                        tooltip: '定位到当前位置',
                        icon: Icon(Icons.my_location_rounded, color: v.blueInk),
                      ),
                    ),
                  ),
                  if (status != null)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      right: 68,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: v.surface.withValues(alpha: 0.90),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: VText.label.copyWith(
                                fontSize: 9.5,
                                color: v.ink2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            VCard(
              child: Row(
                children: [
                  Expanded(
                    child: VStat(
                      label: '路线距离',
                      value: distance.toStringAsFixed(2),
                      unit: ' km',
                    ),
                  ),
                  IconButton(
                    onPressed: _points.isEmpty ? null : _undo,
                    tooltip: '撤销上一个点',
                    icon: const Icon(Icons.undo_rounded),
                  ),
                  TextButton(
                    onPressed: _points.isEmpty ? null : _clearPoints,
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: VPrimaryButton(
                    label: _saving ? '保存中…' : '保存路线',
                    icon: Icons.bookmark_add_rounded,
                    onTap: _saving ? null : _save,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: VGhostButton(
                    label: _saving ? '处理中…' : '保存并发手表',
                    icon: Icons.watch_rounded,
                    onTap: _saving ? null : () => _save(pushToWatch: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
