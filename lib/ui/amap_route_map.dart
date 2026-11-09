import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/ui_translations.dart';
import 'package:vitaloop/l10n/localized_text.dart';

import '../data/amap_tile_cache.dart';
import '../data/map_display.dart';
import '../theme/tokens.dart';
import '../util/coordinate.dart';

/// 高德栅格瓦片地图，叠加本地轨迹。
///
/// 旧版 AMap SDK 的 key 绑定在 com.awen.running 与旧签名上，无法直接复用到新包名，
/// 因此这里直接使用高德公开的栅格瓦片服务，不依赖原生 SDK 和 key。
class AmapRouteMap extends StatefulWidget {
  const AmapRouteMap({
    super.key,
    required this.points,
    this.height = 230,
    this.radius = 26,
    this.onTapPoint,
    this.fitInsets = EdgeInsets.zero,
    this.currentPoint,
    this.wgs84 = false,
    this.currentPointWgs84,
    this.recenterSignal = 0,
    this.targetPoints = const [],
    this.targetPointsWgs84 = false,
    this.targetColor = const Color(0xFF2F7CFF),
    this.supplyPoints = const [],
    this.supplyPointsWgs84 = false,
    this.followCurrentPoint = false,
    this.showEndpoints = true,
  });

  /// (lat, lon) 序列。
  final List<Offset> points;

  /// 固定高度；为 null 时铺满父级（详情页全屏地图）。
  final double? height;
  final double radius;

  /// 点地图时回传经纬度（路线规划用）；为空表示只读地图。
  final void Function(double lat, double lon)? onTapPoint;

  /// 拟合轨迹时给浮层留出的边距（例如详情页底部上拉面板）。
  final EdgeInsets fitInsets;

  /// 当前定位点（lat, lon）；没有轨迹时用来画一个蓝点。
  final Offset? currentPoint;

  /// 输入坐标是否为 WGS-84（手机 GPS / 手表轨迹）。
  /// 高德瓦片是 GCJ-02，路线规划点选结果本身已经是 GCJ-02。
  final bool wgs84;

  /// 当前定位点是否为 WGS-84；不传时跟随 [wgs84]。
  final bool? currentPointWgs84;

  /// 数值变化时重新拟合到轨迹和当前位置。
  final int recenterSignal;

  /// 目标路线；实时轨迹下面用虚线显示。
  final List<Offset> targetPoints;
  final bool targetPointsWgs84;
  final Color targetColor;

  /// 沿途补给点，绘制在目标路线和实际轨迹之上。
  final List<Offset> supplyPoints;
  final bool supplyPointsWgs84;

  /// 实时运动时固定北向上，并把最新定位放在可见地图区域中央。
  final bool followCurrentPoint;

  /// 实时轨迹的末点就是当前位置，不标成“终”。
  final bool showEndpoints;

  @override
  State<AmapRouteMap> createState() => _AmapRouteMapState();
}

class _AmapRouteMapState extends State<AmapRouteMap> {
  static const _minZoom = 3.0;
  static const _maxZoom = 17.0;

  /// 高德亮色瓦片 → 夜间蓝灰地图。只作用于底图，轨迹和起终点仍保持原色。
  /// 先把亮色反相，再压到蓝灰色；透明区域仍保持透明，露出页面底色。
  static const _nightMapFilter = ColorFilter.matrix(<double>[
    -0.1906125,
    -0.3742125,
    -0.072675,
    0,
    203.51,
    -0.1906125,
    -0.3742125,
    -0.072675,
    0,
    217.81,
    -0.1906125,
    -0.3742125,
    -0.072675,
    0,
    240.56,
    0,
    0,
    0,
    1,
    0,
  ]);

  /// 没有可用轨迹点时的默认机位。
  static const _idleZoom = 14.0;

  /// 轨迹退化（点全重合 / 小到不成一个范围）时的固定机位：
  /// 不走 log() 拟合，免得算出 ±inf 的 zoom 再靠 clamp 收场。
  static const _flatZoom = 15.0;

  /// 实时跟随使用固定层级，避免轨迹越长地图缩得越小。
  static const _followZoom = 16.0;

  /// 跨度小于它就是"一个点"（z0 像素，1e-6 ≈ 地面 0.16 米），拟合没有意义。
  static const _flatSpanPx = 1e-6;

  /// 一屏允许铺的瓦片边长上限；超过就是相机算坏了，直接不出图。
  static const _maxTileRun = 8;

  double? _zoom;
  Offset? _center;
  Size _fittedFor = Size.zero;
  int _fittedPointCount = 0;
  Offset? _fittedFirst;
  Offset? _fittedLast;
  Offset? _fittedCurrent;
  bool _userMoved = false;
  bool _fitScheduled = false;
  Offset _startCenter = Offset.zero;
  Offset _startFocal = Offset.zero;
  double _startZoom = 14;
  Offset? _doubleTapFocal;
  List<Offset>? _displayPointsCache;
  List<Offset>? _validPointsCache;
  _RouteGeometry? _routeGeometry;
  List<Offset>? _displayTargetPointsCache;
  List<Offset>? _validTargetPointsCache;
  _RouteGeometry? _targetRouteGeometry;
  List<Offset>? _displaySupplyPointsCache;
  bool _fittedTargetActive = false;
  int _fittedTargetCount = 0;
  Offset? _fittedTargetFirst;
  Offset? _fittedTargetLast;

  @override
  void initState() {
    super.initState();
    MapDisplaySettings.instance.addListener(_onDisplaySettingsChanged);
  }

  @override
  void dispose() {
    MapDisplaySettings.instance.removeListener(_onDisplaySettingsChanged);
    super.dispose();
  }

  void _onDisplaySettingsChanged() {
    if (!mounted) return;
    _displayPointsCache = null;
    _validPointsCache = null;
    _routeGeometry = null;
    _fittedPointCount = 0;
    _fittedFirst = null;
    _fittedLast = null;
    _fittedCurrent = null;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant AmapRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.points, widget.points) ||
        oldWidget.wgs84 != widget.wgs84) {
      _displayPointsCache = null;
      _validPointsCache = null;
      _routeGeometry = null;
      _fittedPointCount = 0;
      _fittedFirst = null;
      _fittedLast = null;
      _fittedCurrent = null;
    }
    if (oldWidget.currentPoint != widget.currentPoint) {
      _fittedCurrent = null;
    }
    if (!identical(oldWidget.targetPoints, widget.targetPoints) ||
        oldWidget.targetPointsWgs84 != widget.targetPointsWgs84) {
      _displayTargetPointsCache = null;
      _validTargetPointsCache = null;
      _targetRouteGeometry = null;
      _fittedTargetActive = false;
      _fittedTargetCount = 0;
      _fittedTargetFirst = null;
      _fittedTargetLast = null;
    }
    if (!identical(oldWidget.supplyPoints, widget.supplyPoints) ||
        oldWidget.supplyPointsWgs84 != widget.supplyPointsWgs84) {
      _displaySupplyPointsCache = null;
    }
    if (oldWidget.followCurrentPoint != widget.followCurrentPoint) {
      _fittedCurrent = null;
      _userMoved = false;
    }
    if (oldWidget.recenterSignal != widget.recenterSignal) {
      _zoom = null;
      _center = null;
      _fitScheduled = false;
      _userMoved = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final geometry = _geometry;
    final targetGeometry = _targetGeometry;
    final currentPoint = _displayCurrentPoint;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(
              constraints.maxWidth,
              widget.height ?? constraints.maxHeight,
            );
            if (!size.isFinite || size.isEmpty) return const SizedBox.shrink();
            // 相机不能在 build 里改：原来 _ensureCamera 直接赋 _zoom/_center/_fittedFor，
            // 等于在布局期间动状态。这帧先按现有相机画，拟合排到帧后。
            if (_needsFit(size)) _scheduleFit(size);
            final zoom = _zoom ?? _idleZoom;
            final center = _center ?? const Offset(0.5, 0.5);
            final worldSize = 256 * math.pow(2, zoom).toDouble();
            final topLeft =
                center * worldSize - Offset(size.width / 2, size.height / 2);
            final tiles = _visibleTiles(topLeft, size, worldSize);
            final tileZoom = zoom.round();
            final tileSize = 256 * math.pow(2, zoom - tileZoom).toDouble();
            final tileLayer = Stack(
              children: [
                for (final tile in tiles)
                  Positioned(
                    left: tile.dx * tileSize - topLeft.dx - 0.5,
                    top: tile.dy * tileSize - topLeft.dy - 0.5,
                    width: tileSize + 1,
                    height: tileSize + 1,
                    child: Image(
                      image: AmapTileImageProvider(
                        _tileUrl(tile.dx.toInt(), tile.dy.toInt(), tileZoom),
                      ),
                      // 没有 key 时每次重建都换一个 provider：整屏瓦片重新解析、
                      // 重新解码，配合 gaplessPlayback 就是一直在刷图。
                      key: ValueKey(
                        '${v.isDark ? 'd' : 'l'}'
                        '${MapDisplaySettings.instance.showLabels ? 'l' : 'n'}'
                        '/$tileZoom/${tile.dx.toInt()}/${tile.dy.toInt()}',
                      ),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, _, _) => ColoredBox(color: v.mapThumb),
                    ),
                  ),
              ],
            );
            return GestureDetector(
              onTapUp: widget.onTapPoint == null
                  ? null
                  : (details) {
                      final world = topLeft + details.localPosition;
                      final nx = world.dx / worldSize;
                      final ny = world.dy / worldSize;
                      final t = math.pi * (1 - 2 * ny);
                      final sinh = (math.exp(t) - math.exp(-t)) / 2;
                      final lat = math.atan(sinh) * 180 / math.pi;
                      final lon = nx * 360 - 180;
                      widget.onTapPoint!(lat, lon);
                    },
              onScaleStart: (details) {
                _userMoved = true;
                _startCenter = center;
                _startZoom = zoom;
                _startFocal = details.localFocalPoint;
              },
              onScaleUpdate: (details) {
                final focal = details.localFocalPoint;
                final viewCenter = Offset(size.width / 2, size.height / 2);
                final scale = details.scale <= 0 ? 1.0 : details.scale;
                final newZoom = (_startZoom + math.log(scale) / math.ln2).clamp(
                  _minZoom,
                  _maxZoom,
                );
                final startWorld = 256 * math.pow(2, _startZoom).toDouble();
                final newWorld = 256 * math.pow(2, newZoom).toDouble();
                // 手势开始时焦点下的归一化世界坐标，缩放/拖动后仍要跟住当前手指位置。
                final startOffset = _startFocal - viewCenter;
                final focalOffset = focal - viewCenter;
                final moved =
                    _startCenter +
                    Offset(
                      startOffset.dx / startWorld,
                      startOffset.dy / startWorld,
                    ) +
                    Offset(
                      -focalOffset.dx / newWorld,
                      -focalOffset.dy / newWorld,
                    );
                setState(() {
                  _zoom = newZoom;
                  _center = Offset(moved.dx % 1, moved.dy.clamp(0.02, 0.98));
                });
              },
              onDoubleTapDown: (details) {
                _doubleTapFocal = details.localPosition;
              },
              onLongPress: () => _showMapOptions(context),
              onDoubleTap: () {
                final viewCenter = Offset(size.width / 2, size.height / 2);
                final focal = _doubleTapFocal ?? viewCenter;
                final newZoom = (zoom + 1).clamp(_minZoom, _maxZoom);
                final startWorld = 256 * math.pow(2, zoom).toDouble();
                final newWorld = 256 * math.pow(2, newZoom).toDouble();
                final focalOffset = focal - viewCenter;
                final moved =
                    center +
                    Offset(
                      focalOffset.dx / startWorld,
                      focalOffset.dy / startWorld,
                    ) +
                    Offset(
                      -focalOffset.dx / newWorld,
                      -focalOffset.dy / newWorld,
                    );
                setState(() {
                  _userMoved = true;
                  _zoom = newZoom;
                  _center = Offset(moved.dx % 1, moved.dy.clamp(0.02, 0.98));
                });
              },
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: v.mapThumb)),
                  if (MapDisplaySettings.instance.showBaseMap)
                    Positioned.fill(
                      child: v.isDark
                          ? ColorFiltered(
                              colorFilter: _nightMapFilter,
                              child: tileLayer,
                            )
                          : tileLayer,
                    ),
                  if (!v.isDark)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(color: const Color(0x1276C893)),
                      ),
                    ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoutePainter(
                        geometry: geometry,
                        targetGeometry: targetGeometry,
                        supplyPoints: _displaySupplyPoints,
                        topLeft: topLeft,
                        worldSize: worldSize,
                        currentPoint: currentPoint,
                        routeColor: const Color(0xFFFF8A3D),
                        targetColor: widget.targetColor,
                        casingColor: Colors.white,
                        startColor: const Color(0xFF2EAD62),
                        endColor: v.danger,
                        showEndpoints: widget.showEndpoints,
                      ),
                    ),
                  ),
                  if (MapDisplaySettings.instance.showBaseMap)
                    Positioned(
                      left: 8,
                      bottom: 6,
                      child: IgnorePointer(
                        child: Text(
                          '© 高德地图',
                          style: TextStyle(
                            fontSize: 8,
                            color: v.isDark
                                ? Colors.white.withValues(alpha: 0.45)
                                : v.muted.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  bool _needsFit(Size size) {
    if (_zoom == null ||
        _center == null ||
        (_fittedFor.width - size.width).abs() > 0.5 ||
        (_fittedFor.height - size.height).abs() > 0.5) {
      return true;
    }
    final valid = _validPoints();
    final target = _validTargetPoints();
    final current = _displayCurrentPoint;
    if (valid.isEmpty && current == null && target.length < 2) return false;
    if (widget.followCurrentPoint && current != null) {
      return _fittedCurrent != current;
    }
    if (_userMoved) return false;
    if (valid.length < 2 && target.length >= 2) {
      return !_fittedTargetActive ||
          target.length != _fittedTargetCount ||
          target.first != _fittedTargetFirst ||
          target.last != _fittedTargetLast;
    }
    if (valid.isEmpty) {
      return current != _fittedCurrent || _fittedPointCount != 0;
    }
    // 实时码表打开时轨迹还是空的，机位会先落在默认点。等第一个/第一批
    // 有效坐标到齐后必须重新拟合，否则整页底图会一直停在 (0, 0) 的海面。
    if (_fittedPointCount == 0) return true;
    return valid.length != _fittedPointCount ||
        valid.first != _fittedFirst ||
        valid.last != _fittedLast;
  }

  List<Offset> get _displayPoints {
    final cached = _displayPointsCache;
    if (cached != null) return cached;
    final points = widget.wgs84
        ? [for (final p in widget.points) _toGcj(p)]
        : widget.points;
    _displayPointsCache = points;
    return points;
  }

  Offset? get _displayCurrentPoint {
    final p = widget.currentPoint;
    if (p == null || !(widget.currentPointWgs84 ?? widget.wgs84)) return p;
    return _toGcj(p);
  }

  static Offset _toGcj(Offset p) {
    final (lat, lon) = Coordinate.wgs84ToGcj02(p.dx, p.dy);
    return Offset(lat, lon);
  }

  List<Offset> _validPoints() {
    final cached = _validPointsCache;
    if (cached != null) return cached;
    final points = _displayPoints
        .where((p) => p.dx.abs() <= 85 && p.dy.abs() <= 180)
        .toList();
    _validPointsCache = points;
    return points;
  }

  List<Offset> get _displayTargetPoints {
    final cached = _displayTargetPointsCache;
    if (cached != null) return cached;
    final points = widget.targetPointsWgs84
        ? [for (final p in widget.targetPoints) _toGcj(p)]
        : widget.targetPoints;
    _displayTargetPointsCache = points;
    return points;
  }

  List<Offset> get _displaySupplyPoints {
    final cached = _displaySupplyPointsCache;
    if (cached != null) return cached;
    final points =
        (widget.supplyPointsWgs84
                ? [for (final p in widget.supplyPoints) _toGcj(p)]
                : widget.supplyPoints)
            .where((p) => p.dx.abs() <= 85 && p.dy.abs() <= 180)
            .toList();
    _displaySupplyPointsCache = points;
    return points;
  }

  List<Offset> _validTargetPoints() {
    final cached = _validTargetPointsCache;
    if (cached != null) return cached;
    final points = _displayTargetPoints
        .where((p) => p.dx.abs() <= 85 && p.dy.abs() <= 180)
        .toList();
    _validTargetPointsCache = points;
    return points;
  }

  _RouteGeometry get _geometry {
    final cached = _routeGeometry;
    if (cached != null) return cached;
    final points = _validPoints();
    final world = [for (final p in points) _project(p.dx, p.dy)];
    final markers = computeKmMarkers(
      points,
      world,
      MapDisplaySettings.instance.markerIntervalM,
    );
    final geometry = _RouteGeometry(
      points: points,
      worldPoints: world,
      kmMarkers: markers,
    );
    _routeGeometry = geometry;
    return geometry;
  }

  _RouteGeometry get _targetGeometry {
    final cached = _targetRouteGeometry;
    if (cached != null) return cached;
    final points = _validTargetPoints();
    final geometry = _RouteGeometry(
      points: points,
      worldPoints: [for (final p in points) _project(p.dx, p.dy)],
      kmMarkers: const [],
    );
    _targetRouteGeometry = geometry;
    return geometry;
  }

  /// 拟合只能排在帧后：build 里改状态 = 重新布局 = 这一帧白算，严重时就是主线程死转。
  void _scheduleFit(Size size) {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted) return;
      setState(() => _fitCamera(size));
    });
  }

  void _fitCamera(Size size) {
    // 尺寸非法（父级给 infinity）也得把机位定下来并记账，否则「没拟合好 → 再排一次」
    // 每帧都成立，就是死循环。
    if (!size.isFinite || size.isEmpty) {
      _zoom ??= _idleZoom;
      _center ??= const Offset(0.5, 0.5);
      _fittedFor = size;
      return;
    }
    final valid = _validPoints();
    final target = _validTargetPoints();
    final current = _displayCurrentPoint;
    final availCenter = _availableCenter(size);
    if (widget.followCurrentPoint && current != null) {
      _zoom = _followZoom;
      final world = 256 * math.pow(2, _zoom!).toDouble();
      final projected = _project(current.dx, current.dy);
      _center = Offset(
        projected.dx + (size.width / 2 - availCenter.dx) / world,
        projected.dy + (size.height / 2 - availCenter.dy) / world,
      );
      _fittedPointCount = valid.length;
      _fittedFirst = valid.isEmpty ? null : valid.first;
      _fittedLast = valid.isEmpty ? null : valid.last;
      _fittedTargetActive = false;
      _fittedTargetCount = target.length;
      _fittedTargetFirst = target.isEmpty ? null : target.first;
      _fittedTargetLast = target.isEmpty ? null : target.last;
      _fittedCurrent = current;
      _fittedFor = size;
      return;
    }
    // 还没开始移动时先展示整条目标路线；一旦有实际轨迹，再跟实际轨迹拟合。
    // 远端当前位置不能混进目标路线包围盒，否则路线会被缩成一个点。
    final focus = valid.length >= 2
        ? valid
        : target.length >= 2
        ? target
        : valid.isNotEmpty
        ? valid
        : [?current];
    if (focus.isEmpty) {
      // 还没定位：别抢走用户手动调过的机位。
      _zoom ??= _idleZoom;
      _center ??= const Offset(0.5, 0.5);
      _fittedFor = size;
      _fittedPointCount = 0;
      _fittedCurrent = null;
      return;
    }
    final projected = [for (final p in focus) _project(p.dx, p.dy)];
    var minX = projected.first.dx, maxX = projected.first.dx;
    var minY = projected.first.dy, maxY = projected.first.dy;
    for (final p in projected) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final spanX = (maxX - minX) * 256;
    final spanY = (maxY - minY) * 256;
    if (spanX <= _flatSpanPx || spanY <= _flatSpanPx) {
      // 退化轨迹（点全部重合，_project 出来跨度为 0）：拟合公式里 跨度→0 会让
      // log 奔着 +inf 去，clamp 到最大层级再画一张「一个点」的图。给固定层级。
      _zoom = _flatZoom;
    } else {
      final fitW = math.max(
        40.0,
        size.width - 64 - widget.fitInsets.horizontal,
      );
      final fitH = math.max(40.0, size.height - 64 - widget.fitInsets.vertical);
      final fitZoom = math.min(
        math.log(fitW / spanX) / math.ln2,
        math.log(fitH / spanY) / math.ln2,
      );
      _zoom = fitZoom.clamp(10.0, _maxZoom).roundToDouble();
    }
    final world = 256 * math.pow(2, _zoom!).toDouble();
    _center = Offset(
      (minX + maxX) / 2 + (size.width / 2 - availCenter.dx) / world,
      (minY + maxY) / 2 + (size.height / 2 - availCenter.dy) / world,
    );
    _fittedPointCount = valid.length;
    _fittedFirst = valid.isEmpty ? null : valid.first;
    _fittedLast = valid.isEmpty ? null : valid.last;
    _fittedTargetActive = valid.length < 2 && target.length >= 2;
    _fittedTargetCount = target.length;
    _fittedTargetFirst = target.isEmpty ? null : target.first;
    _fittedTargetLast = target.isEmpty ? null : target.last;
    _fittedCurrent = current;
    _fittedFor = size;
  }

  Offset _availableCenter(Size size) => Offset(
    widget.fitInsets.left + (size.width - widget.fitInsets.horizontal) / 2,
    widget.fitInsets.top + (size.height - widget.fitInsets.vertical) / 2,
  );

  List<Offset> _visibleTiles(Offset topLeft, Size size, double worldSize) {
    // 传进来的任何一个数不是有限的，(topLeft.dx / 256).floor() 就直接抛
    // (Bad state: cannot convert infinity to int)，整页 build 失败。
    if (!size.isFinite ||
        !topLeft.isFinite ||
        !worldSize.isFinite ||
        worldSize <= 0) {
      return const [];
    }
    final z = (_zoom?.round() ?? _idleZoom.round()).clamp(
      _minZoom.round(),
      _maxZoom.round(),
    );
    final count = 1 << z;
    final tileSize = worldSize / count;
    final firstX = (topLeft.dx / tileSize).floor();
    final lastX = ((topLeft.dx + size.width) / tileSize).ceil();
    final firstY = (topLeft.dy / tileSize).floor();
    final lastY = ((topLeft.dy + size.height) / tileSize).ceil();
    // 相机算歪时跨度能到几十万张，一帧贴几十万张网络图 = 主线程和内存一起没救。
    // 正常一屏最多 (393/256+2)×(230/256+2) ≈ 3×3，宁可不画也不能刷不完。
    if (lastX - firstX > _maxTileRun || lastY - firstY > _maxTileRun) {
      return const [];
    }
    final out = <Offset>[];
    for (var x = firstX; x <= lastX; x++) {
      for (var y = firstY; y <= lastY; y++) {
        if (y < 0 || y >= count) continue;
        final wrappedX = ((x % count) + count) % count;
        out.add(Offset(wrappedX.toDouble(), y.toDouble()));
      }
    }
    return out;
  }

  String _tileUrl(int x, int y, int z) {
    final server = (x + y) % 4 + 1;
    // ltype=11 是高德的无路名底图；0/缺省是带街道名称的完整底图。
    final ltype = MapDisplaySettings.instance.showLabels ? 0 : 11;
    return 'https://webrd0$server.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&ltype=$ltype&x=$x&y=$y&z=$z';
  }

  Future<void> _showMapOptions(BuildContext context) async {
    final settings = MapDisplaySettings.instance;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('显示地图底图'),
                subtitle: const Text('关闭后只保留轨迹线，适合分享时隐藏位置'),
                trailing: Switch(
                  value: settings.showBaseMap,
                  onChanged: (value) {
                    settings.setShowBaseMap(value);
                    setSheet(() {});
                  },
                ),
              ),
              ListTile(
                enabled: settings.showBaseMap,
                title: const Text('显示街道名称'),
                subtitle: const Text('关闭后不显示路名、村庄和地点文字'),
                trailing: Switch(
                  value: settings.showLabels,
                  onChanged: settings.showBaseMap
                      ? (value) {
                          settings.setShowLabels(value);
                          setSheet(() {});
                        }
                      : null,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Offset _project(double lat, double lon) {
    final x = (lon + 180) / 360;
    final clamped = lat.clamp(-85.0, 85.0);
    final sinLat = math.sin(clamped * math.pi / 180);
    final y = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
    return Offset(x, y);
  }
}

class _RouteGeometry {
  const _RouteGeometry({
    required this.points,
    required this.worldPoints,
    required this.kmMarkers,
  });

  final List<Offset> points;
  final List<Offset> worldPoints;
  final List<KmMarker> kmMarkers;
}

/// 公里标记：编号 + 投影后的位置。
class KmMarker {
  const KmMarker(this.km, this.worldPoint);

  final int km;
  final Offset worldPoint;
}

/// 计算公里标记的投影位置。
///
/// 输入：[latLonPoints] 是 Offset(lat, lon) 列表；[worldPoints] 是同一组点投影后的
/// Offset(x, y) 列表（Web Mercator）。
///
/// 一段可能跨多个公里阈值（隧道丢 GPS 时常见）：必须按段内线性插值取位置，否则
/// 整段终点会被多个标记复用，后画的圆标整个盖住先画的（看起来就是"少了 7"）。
List<KmMarker> computeKmMarkers(
  List<Offset> latLonPoints,
  List<Offset> worldPoints, [
  int intervalM = 1000,
]) {
  final stepM = intervalM < 1000 ? 1000 : intervalM;
  final markers = <KmMarker>[];
  var travelled = 0.0;
  var nextMarkM = stepM;
  for (var i = 1; i < latLonPoints.length; i++) {
    final a = latLonPoints[i - 1];
    final b = latLonPoints[i];
    final segMeters = _distanceMeters(a.dx, a.dy, b.dx, b.dy);
    final before = travelled;
    travelled += segMeters;
    while (travelled >= nextMarkM) {
      final target = nextMarkM.toDouble();
      final fraction = segMeters <= 0
          ? 1.0
          : ((target - before) / segMeters).clamp(0.0, 1.0);
      markers.add(
        KmMarker(
          nextMarkM ~/ 1000,
          Offset.lerp(worldPoints[i - 1], worldPoints[i], fraction)!,
        ),
      );
      nextMarkM += stepM;
    }
    // 轨迹异常长时别把主线程耗在画几百个圆标上。
    if (nextMarkM > 200000) break;
  }
  return markers;
}

double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earth = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earth * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.geometry,
    required this.targetGeometry,
    required this.supplyPoints,
    required this.topLeft,
    required this.worldSize,
    required this.currentPoint,
    required this.routeColor,
    required this.targetColor,
    required this.casingColor,
    required this.startColor,
    required this.endColor,
    required this.showEndpoints,
  });

  final _RouteGeometry geometry;
  final _RouteGeometry targetGeometry;
  final List<Offset> supplyPoints;
  final Offset topLeft;
  final double worldSize;
  final Offset? currentPoint;
  final Color routeColor;
  final Color targetColor;
  final Color casingColor;
  final Color startColor;
  final Color endColor;
  final bool showEndpoints;

  @override
  void paint(Canvas canvas, Size size) {
    Offset screenPoint(Offset world) => world * worldSize - topLeft;

    final targetWorldPoints = targetGeometry.worldPoints;
    if (targetWorldPoints.length >= 2) {
      final targetScreenPoints = [
        for (final point in targetWorldPoints) screenPoint(point),
      ];
      _drawDashedPolyline(
        canvas,
        targetScreenPoints,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      _drawDashedPolyline(
        canvas,
        targetScreenPoints,
        Paint()
          ..color = targetColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      _endpointMarker(
        canvas,
        screenPoint(targetWorldPoints.last),
        targetColor,
        '终',
        Offset.zero,
      );
    }

    final worldPoints = geometry.worldPoints;
    if (worldPoints.length >= 2) {
      final first = screenPoint(worldPoints.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (var i = 1; i < worldPoints.length; i++) {
        final p = screenPoint(worldPoints[i]);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = casingColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = routeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      for (final marker in geometry.kmMarkers) {
        final p = screenPoint(marker.worldPoint);
        if (p.dx > -20 &&
            p.dx < size.width + 20 &&
            p.dy > -20 &&
            p.dy < size.height + 20) {
          _kmMarker(canvas, p, marker.km);
        }
      }
      if (showEndpoints) {
        final last = screenPoint(worldPoints.last);
        final overlap = (first - last).distance < 26;
        _endpointMarker(
          canvas,
          first,
          startColor,
          tr('起'),
          overlap ? const Offset(-15, -15) : Offset.zero,
        );
        _endpointMarker(
          canvas,
          last,
          endColor,
          tr('终'),
          overlap ? const Offset(15, 15) : Offset.zero,
        );
      }
    }
    for (final point in supplyPoints) {
      final p = _screenPoint(point, topLeft, worldSize);
      if (p != null) _supplyMarker(canvas, p);
    }
    final current = currentPoint;
    if (current != null) {
      final p = _screenPoint(current, topLeft, worldSize);
      if (p != null) _currentDot(canvas, p);
    }
  }

  Offset? _screenPoint(Offset point, Offset topLeft, double worldSize) {
    if (point.dx.abs() > 85 || point.dy.abs() > 180) return null;
    final x = (point.dy + 180) / 360;
    final sinLat = math.sin(point.dx.clamp(-85.0, 85.0) * math.pi / 180);
    final y = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
    return Offset(x * worldSize - topLeft.dx, y * worldSize - topLeft.dy);
  }

  void _drawDashedPolyline(
    Canvas canvas,
    List<Offset> points,
    Paint paint, {
    double dash = 12,
    double gap = 10,
  }) {
    for (var i = 1; i < points.length; i++) {
      final start = points[i - 1];
      final end = points[i];
      final delta = end - start;
      final length = delta.distance;
      if (length <= 0) continue;
      final direction = delta / length;
      var travelled = 0.0;
      while (travelled < length) {
        final from = start + direction * travelled;
        final to = start + direction * math.min(travelled + dash, length);
        canvas.drawLine(from, to, paint);
        travelled += dash + gap;
      }
    }
  }

  void _currentDot(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 9, Paint()..color = Colors.white);
    canvas.drawCircle(center, 7, Paint()..color = routeColor);
  }

  void _kmMarker(Canvas canvas, Offset center, int km) {
    final fill = Paint()..color = const Color(0xE6000000);
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, 11, fill);
    canvas.drawCircle(center, 11, border);
    final text = TextPainter(
      text: TextSpan(
        text: '$km',
        style: TextStyle(
          color: Colors.white,
          fontSize: km >= 10 ? 10 : 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
  }

  void _endpointMarker(
    Canvas canvas,
    Offset center,
    Color color,
    String text,
    Offset offset,
  ) {
    final p = center + offset;
    canvas.drawCircle(p, 13, Paint()..color = Colors.white);
    canvas.drawCircle(p, 11, Paint()..color = color);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, p - Offset(painter.width / 2, painter.height / 2));
  }

  void _supplyMarker(Canvas canvas, Offset center) {
    const color = Color(0xFF2EAD62);
    canvas.drawCircle(center, 15, Paint()..color = Colors.white);
    canvas.drawCircle(center, 12.5, Paint()..color = color);
    final painter = TextPainter(
      text: const TextSpan(
        text: '补',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      !identical(old.geometry, geometry) ||
      !identical(old.targetGeometry, targetGeometry) ||
      !identical(old.supplyPoints, supplyPoints) ||
      old.topLeft != topLeft ||
      old.worldSize != worldSize ||
      old.routeColor != routeColor ||
      old.targetColor != targetColor ||
      old.casingColor != casingColor ||
      old.startColor != startColor ||
      old.endColor != endColor ||
      old.showEndpoints != showEndpoints;
}
