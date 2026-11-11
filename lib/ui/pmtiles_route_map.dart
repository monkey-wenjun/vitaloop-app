import 'package:flutter/material.dart' hide Text;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:vitaloop/l10n/localized_text.dart';

import '../data/map_display.dart';
import '../data/map_offline_service.dart';
import '../data/pmtiles_map_style.dart';
import '../theme/tokens.dart';
import '../util/coordinate.dart';
import '../util/km_markers.dart';
import '../util/map_bearing.dart';

class PmtilesRouteMap extends StatefulWidget {
  const PmtilesRouteMap({
    super.key,
    required this.points,
    this.height,
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
    this.showBaseMap = true,
  });

  final List<Offset> points;
  final double? height;
  final double radius;
  final void Function(double lat, double lon)? onTapPoint;
  final EdgeInsets fitInsets;
  final Offset? currentPoint;
  final bool wgs84;
  final bool? currentPointWgs84;
  final int recenterSignal;
  final List<Offset> targetPoints;
  final bool targetPointsWgs84;
  final Color targetColor;
  final List<Offset> supplyPoints;
  final bool supplyPointsWgs84;
  final bool followCurrentPoint;
  final bool showEndpoints;
  final bool showBaseMap;

  @override
  State<PmtilesRouteMap> createState() => _PmtilesRouteMapState();
}

class _PmtilesRouteMapState extends State<PmtilesRouteMap> {
  ml.MapLibreMapController? _controller;
  bool _syncing = false;
  bool _syncPending = false;
  bool _styleReady = false;

  /// 前进方向（正北 0°，顺时针）。跟随时让车头朝上。
  double _bearing = 0;

  /// 已经画在图上的标注。实时页每秒都会重建地图组件，如果每次都
  /// clearLines / clearCircles / clearSymbols 再重新添加，线会消失一帧，
  /// 看起来就是「一闪一闪」。这里保留引用，内容变化时原地 update。
  ml.Line? _targetLine;
  ml.Line? _trackLine;
  List<ml.Circle> _kmCircles = <ml.Circle>[];
  List<ml.Symbol> _kmSymbols = <ml.Symbol>[];
  List<ml.Circle> _supplyCircles = <ml.Circle>[];
  String _supplyKey = '';
  ml.Circle? _startCircle;
  ml.Circle? _endCircle;
  ml.Circle? _currentCircle;

  /// 公里标记只随轨迹增长追加；轨迹被替换（首点/长度变化）时才整体重建。
  int _markerTrackLength = 0;
  Offset? _markerTrackFirst;

  /// 上一次真正画到图上的内容摘要。轨迹列表每秒都是新对象，只有内容
  /// 变了才需要碰原生地图。
  String _appliedSignature = '';
  bool _needsInitialFit = true;
  bool _forceFit = false;

  @override
  void didUpdateWidget(covariant PmtilesRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetChanged =
        !identical(oldWidget.targetPoints, widget.targetPoints) ||
        oldWidget.targetPointsWgs84 != widget.targetPointsWgs84;
    final recentered = oldWidget.recenterSignal != widget.recenterSignal;
    final followChanged =
        oldWidget.followCurrentPoint != widget.followCurrentPoint;
    final dataChanged =
        !identical(oldWidget.points, widget.points) ||
        oldWidget.currentPoint != widget.currentPoint ||
        targetChanged ||
        !identical(oldWidget.supplyPoints, widget.supplyPoints) ||
        oldWidget.wgs84 != widget.wgs84 ||
        oldWidget.currentPointWgs84 != widget.currentPointWgs84 ||
        oldWidget.supplyPointsWgs84 != widget.supplyPointsWgs84 ||
        oldWidget.showEndpoints != widget.showEndpoints ||
        oldWidget.targetColor != widget.targetColor;
    if (!dataChanged && !recentered) return;

    // 只有「换了一条路线 / 手动回中 / 进入或退出跟随」才需要重新拟合机位。
    // 轨迹每增长一个点就重新拟合会把地图一直来回拉。
    if (targetChanged || recentered || followChanged) _forceFit = true;
    if (recentered) _needsInitialFit = true;
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final settings = MapDisplaySettings.instance;
    final night = Theme.of(context).brightness == Brightness.dark;
    final sourceUrl = settings.pmtilesUrl.trim().isEmpty
        ? MapDisplaySettings.defaultPmtilesUrl
        : settings.pmtilesUrl.trim();
    final material = Theme.of(context);
    final map = ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: ml.MapLibreMap(
          key: ValueKey('${settings.pmtilesUrl}|$night|${widget.showBaseMap}'),
          styleString: pmtilesMapStyleJson(
            sourceUrl: sourceUrl,
            night: night,
            showBaseMap: widget.showBaseMap,
          ),
          initialCameraPosition: const ml.CameraPosition(
            target: ml.LatLng(30.2741, 120.1551),
            zoom: 10.5,
          ),
          compassEnabled: false,
          scaleControlEnabled: true,
          logoEnabled: false,
          attributionEnabled: true,
          foregroundLoadColor: material.scaffoldBackgroundColor,
          minMaxZoomPreference: const ml.MinMaxZoomPreference(2, 18),
          annotationOrder: const [
            ml.AnnotationType.line,
            ml.AnnotationType.circle,
            ml.AnnotationType.symbol,
            ml.AnnotationType.fill,
          ],
          onMapCreated: (controller) {
            _controller = controller;
            _styleReady = false;
            // 新地图实例上旧的标注引用全部失效。
            _resetAnnotations();
          },
          onStyleLoadedCallback: () {
            _styleReady = true;
            _resetAnnotations();
            _needsInitialFit = true;
            _sync();
          },
          onMapClick: (_, latLng) {
            final (lat, lon) = Coordinate.wgs84ToGcj02(
              latLng.latitude,
              latLng.longitude,
            );
            widget.onTapPoint?.call(lat, lon);
          },
        ),
      ),
    );
    return Stack(
      children: [
        map,
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: IgnorePointer(
            child: ValueListenableBuilder<CityMapDownloadState>(
              valueListenable: MapOfflineService.instance.state,
              builder: (context, state, _) {
                if (state.message.isEmpty ||
                    (!state.active && !state.complete)) {
                  return const SizedBox.shrink();
                }
                final v = context.v;
                return Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: v.glass,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: v.line),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.active && !state.complete)
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: state.progress > 0
                                  ? state.progress.clamp(0, 1)
                                  : null,
                            ),
                          )
                        else
                          Icon(
                            Icons.offline_pin_rounded,
                            size: 15,
                            color: v.greenInk,
                          ),
                        const SizedBox(width: 7),
                        Text(
                          state.message,
                          style: VText.label.copyWith(
                            fontSize: 10,
                            color: v.ink2,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 清空标注引用（不调用 clear*，调用方负责新地图上的重建）。
  void _resetAnnotations() {
    _targetLine = null;
    _trackLine = null;
    _kmCircles = <ml.Circle>[];
    _kmSymbols = <ml.Symbol>[];
    _supplyCircles = <ml.Circle>[];
    _supplyKey = '';
    _startCircle = null;
    _endCircle = null;
    _currentCircle = null;
    _markerTrackLength = 0;
    _markerTrackFirst = null;
    _appliedSignature = '';
  }

  Future<void> _sync() async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    if (_syncing) {
      // 同步过程中又有新数据：跑完当前一轮再按最新值补一轮。
      _syncPending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncPending = false;
        await _apply(controller);
      } while (_syncPending && mounted);
    } catch (_) {
      // 地图资源失败不能影响运动记录和导航本身。
    } finally {
      _syncing = false;
    }
  }

  Future<void> _apply(ml.MapLibreMapController controller) async {
    final target = _convert(widget.targetPoints, widget.targetPointsWgs84);
    final track = _convert(widget.points, widget.wgs84);
    final supplies = _convert(widget.supplyPoints, widget.supplyPointsWgs84);
    final current = _currentWgs84;
    final signature = _signature(track, target, supplies, current);
    final contentChanged = signature != _appliedSignature;

    if (contentChanged) {
      await _syncTargetLine(controller, target);
      await _syncTrackLine(controller, track);
      await _syncKmMarkers(controller, track);
      await _syncSupplies(controller, supplies);
      await _syncEndpoints(controller, track);
      _currentCircle = await _upsertCircle(
        controller,
        _currentCircle,
        current == null
            ? null
            : ml.CircleOptions(
                geometry: ml.LatLng(current.dx, current.dy),
                circleColor: '#2F7CFF',
                circleRadius: 8,
                circleStrokeColor: '#FFFFFF',
                circleStrokeWidth: 3,
              ),
      );
      _appliedSignature = signature;
    }

    final hasContent = track.isNotEmpty || target.isNotEmpty || current != null;
    final shouldFit =
        _forceFit ||
        (contentChanged && widget.followCurrentPoint && current != null) ||
        (contentChanged && _needsInitialFit && hasContent);
    if (shouldFit) {
      await _fitCamera(controller, track, target, current);
      _forceFit = false;
      if (hasContent) _needsInitialFit = false;
    }
  }

  Future<void> _syncTargetLine(
    ml.MapLibreMapController controller,
    List<Offset> target,
  ) async {
    if (target.length >= 2) {
      final options = ml.LineOptions(
        lineColor: _hex(widget.targetColor, alpha: 0.62),
        lineWidth: 4,
        lineJoin: 'round',
        geometry: [for (final p in target) ml.LatLng(p.dx, p.dy)],
      );
      final line = _targetLine;
      if (line == null) {
        _targetLine = await controller.addLine(options);
      } else {
        await controller.updateLine(line, options);
      }
    } else if (_targetLine != null) {
      await controller.removeLine(_targetLine!);
      _targetLine = null;
    }
  }

  Future<void> _syncTrackLine(
    ml.MapLibreMapController controller,
    List<Offset> track,
  ) async {
    if (track.length >= 2) {
      final options = ml.LineOptions(
        lineColor: '#F97316',
        lineWidth: 5,
        lineJoin: 'round',
        geometry: [for (final p in track) ml.LatLng(p.dx, p.dy)],
      );
      final line = _trackLine;
      if (line == null) {
        _trackLine = await controller.addLine(options);
      } else {
        await controller.updateLine(line, options);
      }
    } else if (_trackLine != null) {
      await controller.removeLine(_trackLine!);
      _trackLine = null;
    }
  }

  Future<void> _syncKmMarkers(
    ml.MapLibreMapController controller,
    List<Offset> track,
  ) async {
    final markers = computeKmGeoMarkers(
      track,
      MapDisplaySettings.instance.markerIntervalM,
    );
    // 轨迹被替换或回退时，旧公里标位置不再有效，整体重建。
    final reset =
        track.length < _markerTrackLength ||
        (track.isNotEmpty &&
            _markerTrackFirst != null &&
            track.first != _markerTrackFirst) ||
        (track.isEmpty && _markerTrackLength > 0);
    if (reset) {
      if (_kmCircles.isNotEmpty) await controller.removeCircles(_kmCircles);
      if (_kmSymbols.isNotEmpty) await controller.removeSymbols(_kmSymbols);
      _kmCircles = <ml.Circle>[];
      _kmSymbols = <ml.Symbol>[];
    }
    _markerTrackLength = track.length;
    _markerTrackFirst = track.isEmpty ? null : track.first;

    // 公里标按里程固定，轨迹继续增长只会追加新的标，不会挪动旧标。
    if (markers.length < _kmCircles.length) {
      await controller.removeCircles(_kmCircles.sublist(markers.length));
      _kmCircles = _kmCircles.sublist(0, markers.length);
    }
    if (markers.length < _kmSymbols.length) {
      await controller.removeSymbols(_kmSymbols.sublist(markers.length));
      _kmSymbols = _kmSymbols.sublist(0, markers.length);
    }
    if (markers.length > _kmCircles.length) {
      final circles = await controller.addCircles([
        for (final marker in markers.sublist(_kmCircles.length))
          ml.CircleOptions(
            geometry: ml.LatLng(marker.point.dx, marker.point.dy),
            circleColor: '#111827',
            circleRadius: 11,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2,
          ),
      ]);
      _kmCircles = [..._kmCircles, ...circles];
    }
    if (markers.length > _kmSymbols.length) {
      final symbols = await controller.addSymbols([
        for (final marker in markers.sublist(_kmSymbols.length))
          ml.SymbolOptions(
            geometry: ml.LatLng(marker.point.dx, marker.point.dy),
            textField: '${marker.km}',
            fontNames: const ['Noto Sans Regular'],
            textSize: 11,
            textColor: '#FFFFFF',
            textHaloColor: '#111827',
            textHaloWidth: 1,
          ),
      ]);
      _kmSymbols = [..._kmSymbols, ...symbols];
    }
  }

  Future<void> _syncSupplies(
    ml.MapLibreMapController controller,
    List<Offset> supplies,
  ) async {
    final key = [for (final p in supplies) '${p.dx},${p.dy}'].join(';');
    if (key == _supplyKey) return;
    if (_supplyCircles.isNotEmpty) {
      await controller.removeCircles(_supplyCircles);
    }
    _supplyCircles = supplies.isEmpty
        ? <ml.Circle>[]
        : await controller.addCircles([
            for (final p in supplies)
              ml.CircleOptions(
                geometry: ml.LatLng(p.dx, p.dy),
                circleColor: '#F97316',
                circleRadius: 5,
                circleStrokeColor: '#FFFFFF',
                circleStrokeWidth: 2,
              ),
          ]);
    _supplyKey = key;
  }

  Future<void> _syncEndpoints(
    ml.MapLibreMapController controller,
    List<Offset> track,
  ) async {
    final show = widget.showEndpoints && track.length >= 2;
    _startCircle = await _upsertCircle(
      controller,
      _startCircle,
      show
          ? ml.CircleOptions(
              geometry: ml.LatLng(track.first.dx, track.first.dy),
              circleColor: '#22C55E',
              circleRadius: 6,
              circleStrokeColor: '#FFFFFF',
              circleStrokeWidth: 2,
            )
          : null,
    );
    _endCircle = await _upsertCircle(
      controller,
      _endCircle,
      show
          ? ml.CircleOptions(
              geometry: ml.LatLng(track.last.dx, track.last.dy),
              circleColor: '#EF4444',
              circleRadius: 6,
              circleStrokeColor: '#FFFFFF',
              circleStrokeWidth: 2,
            )
          : null,
    );
  }

  Future<ml.Circle?> _upsertCircle(
    ml.MapLibreMapController controller,
    ml.Circle? circle,
    ml.CircleOptions? options,
  ) async {
    if (options == null) {
      if (circle != null) await controller.removeCircle(circle);
      return null;
    }
    if (circle == null) return controller.addCircle(options);
    await controller.updateCircle(circle, options);
    return circle;
  }

  String _signature(
    List<Offset> track,
    List<Offset> target,
    List<Offset> supplies,
    Offset? current,
  ) {
    String firstLast(List<Offset> points) =>
        points.isEmpty ? '' : '${points.first}/${points.last}';
    return '${track.length}:${firstLast(track)}'
        '|${target.length}:${firstLast(target)}'
        '|${supplies.length}:${firstLast(supplies)}'
        '|${current ?? ''}'
        '|${widget.showEndpoints}'
        '|${MapDisplaySettings.instance.markerIntervalM}';
  }

  Future<void> _fitCamera(
    ml.MapLibreMapController controller,
    List<Offset> track,
    List<Offset> target,
    Offset? current,
  ) async {
    if (widget.followCurrentPoint && current != null) {
      final heading = travelBearingDegrees(track);
      if (heading != null) _bearing = blendBearingDegrees(_bearing, heading);
      await controller.animateCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(current.dx, current.dy),
            zoom: 16,
            bearing: _bearing,
          ),
        ),
        duration: const Duration(milliseconds: 250),
      );
      return;
    }
    // 从跟随退出时恢复北向上，避免路线总览还保持车头方向。
    if (_bearing != 0) {
      _bearing = 0;
      await controller.animateCamera(
        ml.CameraUpdate.bearingTo(0),
        duration: const Duration(milliseconds: 200),
      );
    }
    final fit = track.length >= 2
        ? track
        : target.isNotEmpty
        ? target
        : current == null
        ? const <Offset>[]
        : <Offset>[current];
    if (fit.isEmpty) return;
    if (fit.length == 1) {
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(fit.first.dx, fit.first.dy),
          15,
        ),
        duration: const Duration(milliseconds: 250),
      );
      return;
    }
    var south = fit.first.dx;
    var north = fit.first.dx;
    var west = fit.first.dy;
    var east = fit.first.dy;
    for (final point in fit.skip(1)) {
      south = point.dx < south ? point.dx : south;
      north = point.dx > north ? point.dx : north;
      west = point.dy < west ? point.dy : west;
      east = point.dy > east ? point.dy : east;
    }
    final bounds = ml.LatLngBounds(
      southwest: ml.LatLng(south, west),
      northeast: ml.LatLng(north, east),
    );
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        bounds,
        left: widget.fitInsets.left + 30,
        top: widget.fitInsets.top + 30,
        right: widget.fitInsets.right + 30,
        bottom: widget.fitInsets.bottom + 30,
      ),
      duration: const Duration(milliseconds: 300),
    );
  }

  Offset? get _currentWgs84 {
    final point = widget.currentPoint;
    if (point == null) return null;
    final isWgs84 = widget.currentPointWgs84 ?? widget.wgs84;
    if (isWgs84) return point;
    final (lat, lon) = Coordinate.gcj02ToWgs84(point.dx, point.dy);
    return Offset(lat, lon);
  }

  static List<Offset> _convert(List<Offset> points, bool wgs84) {
    if (wgs84) return points;
    return [
      for (final point in points)
        if (point.dx.isFinite &&
            point.dy.isFinite &&
            point.dx.abs() <= 85 &&
            point.dy.abs() <= 180)
          () {
            final (lat, lon) = Coordinate.gcj02ToWgs84(point.dx, point.dy);
            return Offset(lat, lon);
          }(),
    ];
  }

  static String _hex(Color color, {double alpha = 1}) {
    int channel(double value) => (value.clamp(0, 1) * 255).round();
    final r = channel(color.r).toRadixString(16).padLeft(2, '0');
    final g = channel(color.g).toRadixString(16).padLeft(2, '0');
    final b = channel(color.b).toRadixString(16).padLeft(2, '0');
    final a = channel(alpha * color.a).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b$a';
  }
}
