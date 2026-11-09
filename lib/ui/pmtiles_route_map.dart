import 'package:flutter/material.dart' hide Text;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:vitaloop/l10n/localized_text.dart';

import '../data/map_display.dart';
import '../data/map_offline_service.dart';
import '../data/pmtiles_map_style.dart';
import '../theme/tokens.dart';
import '../util/coordinate.dart';
import '../util/km_markers.dart';

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
  int _revision = 0;

  @override
  void didUpdateWidget(covariant PmtilesRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.points, widget.points) ||
        oldWidget.currentPoint != widget.currentPoint ||
        oldWidget.recenterSignal != widget.recenterSignal ||
        !identical(oldWidget.targetPoints, widget.targetPoints) ||
        !identical(oldWidget.supplyPoints, widget.supplyPoints) ||
        oldWidget.followCurrentPoint != widget.followCurrentPoint ||
        oldWidget.wgs84 != widget.wgs84 ||
        oldWidget.currentPointWgs84 != widget.currentPointWgs84 ||
        oldWidget.targetPointsWgs84 != widget.targetPointsWgs84 ||
        oldWidget.supplyPointsWgs84 != widget.supplyPointsWgs84) {
      _revision++;
      _sync();
    }
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
          key: ValueKey('${settings.pmtilesUrl}|$night'),
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
            _sync();
          },
          onStyleLoadedCallback: _sync,
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

  Future<void> _sync() async {
    final controller = _controller;
    if (controller == null || _syncing) return;
    _syncing = true;
    final revision = _revision;
    try {
      final current = _currentWgs84;
      if (widget.showBaseMap &&
          current != null &&
          MapDisplaySettings.instance.offlineCityEnabled) {
        await MapOfflineService.instance.ensureCity(
          ml.LatLng(current.dx, current.dy),
        );
      }
      if (revision != _revision) return;

      await controller.clearLines();
      await controller.clearCircles();
      await controller.clearSymbols();

      final target = _convert(widget.targetPoints, widget.targetPointsWgs84);
      if (target.length >= 2) {
        await controller.addLine(
          ml.LineOptions(
            lineColor: _hex(widget.targetColor, alpha: 0.62),
            lineWidth: 4,
            lineJoin: 'round',
            geometry: target.map((p) => ml.LatLng(p.dx, p.dy)).toList(),
          ),
        );
      }

      final track = _convert(widget.points, widget.wgs84);
      if (track.length >= 2) {
        await controller.addLine(
          ml.LineOptions(
            lineColor: '#F97316',
            lineWidth: 5,
            lineJoin: 'round',
            geometry: track.map((p) => ml.LatLng(p.dx, p.dy)).toList(),
          ),
        );
        final markers = computeKmGeoMarkers(
          track,
          MapDisplaySettings.instance.markerIntervalM,
        );
        if (markers.isNotEmpty) {
          await controller.addCircles([
            for (final marker in markers)
              ml.CircleOptions(
                geometry: ml.LatLng(marker.point.dx, marker.point.dy),
                circleColor: '#111827',
                circleRadius: 11,
                circleStrokeColor: '#FFFFFF',
                circleStrokeWidth: 2,
              ),
          ]);
          await controller.addSymbols([
            for (final marker in markers)
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
        }
      }

      final supplies = _convert(widget.supplyPoints, widget.supplyPointsWgs84);
      if (supplies.isNotEmpty) {
        await controller.addCircles([
          for (final p in supplies)
            ml.CircleOptions(
              geometry: ml.LatLng(p.dx, p.dy),
              circleColor: '#F97316',
              circleRadius: 5,
              circleStrokeColor: '#FFFFFF',
              circleStrokeWidth: 2,
            ),
        ]);
      }

      if (widget.showEndpoints && track.length >= 2) {
        await controller.addCircle(
          ml.CircleOptions(
            geometry: ml.LatLng(track.first.dx, track.first.dy),
            circleColor: '#22C55E',
            circleRadius: 6,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2,
          ),
        );
        await controller.addCircle(
          ml.CircleOptions(
            geometry: ml.LatLng(track.last.dx, track.last.dy),
            circleColor: '#EF4444',
            circleRadius: 6,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 2,
          ),
        );
      }
      if (current != null) {
        await controller.addCircle(
          ml.CircleOptions(
            geometry: ml.LatLng(current.dx, current.dy),
            circleColor: '#2F7CFF',
            circleRadius: 8,
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 3,
          ),
        );
      }

      await _fitCamera(controller, track, target, current);
    } catch (_) {
      // 地图资源失败不能影响运动记录和导航本身。
    } finally {
      _syncing = false;
    }
  }

  Future<void> _fitCamera(
    ml.MapLibreMapController controller,
    List<Offset> track,
    List<Offset> target,
    Offset? current,
  ) async {
    if (widget.followCurrentPoint && current != null) {
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(ml.LatLng(current.dx, current.dy), 16),
        duration: const Duration(milliseconds: 250),
      );
      return;
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
