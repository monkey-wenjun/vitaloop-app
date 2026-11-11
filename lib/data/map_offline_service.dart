import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../util/coordinate.dart';
import 'amap_tile_cache.dart';
import 'amap_tiles.dart';
import 'api.dart';
import 'map_display.dart';

const _pmtilesOfflineStyleRevision = 6;

class CityMapDownloadState {
  const CityMapDownloadState({
    this.active = false,
    this.complete = false,
    this.progress = 0,
    this.message = '',
    this.regionId,
  });

  final bool active;
  final bool complete;
  final double progress;
  final String message;
  final int? regionId;
}

class MapOfflineService {
  MapOfflineService._();

  static final instance = MapOfflineService._();
  final state = ValueNotifier(const CityMapDownloadState());

  bool _busy = false;
  String? _lastCell;
  String? _failedKey;
  DateTime? _failedAt;

  /// 下载当前位置所在城市的离线地图。
  ///
  /// 高德底图把瓦片落到 [AmapTileCache]，PMTiles 底图用 maplibre 的离线区域。
  /// 默认传入 WGS-84 坐标（手机 GPS / 手表轨迹）；[gcj02] 为 true 时表示
  /// 传入的已经是高德/腾讯坐标，避免重复偏移。设置页手动下载传 [force]
  /// 可以绕过「自动下载」开关。
  Future<void> ensureCity(
    double lat,
    double lon, {
    bool gcj02 = false,
    bool force = false,
  }) async {
    if (_busy || !lat.isFinite || !lon.isFinite) return;
    final settings = MapDisplaySettings.instance;
    await settings.load();
    if (!force && !settings.offlineCityEnabled) return;
    final (wgsLat, wgsLon) = gcj02
        ? Coordinate.gcj02ToWgs84(lat, lon)
        : (lat, lon);
    if (settings.provider == MapBaseProvider.amap) {
      await _ensureAmapCity(lat, lon, gcj02: gcj02, force: force);
      return;
    }
    if (settings.provider != MapBaseProvider.pmtiles ||
        settings.pmtilesUrl.trim().isEmpty) {
      return;
    }
    if (settings.pmtilesUrl.contains('.pmtiles')) {
      state.value = const CityMapDownloadState(
        message: '城市离线下载需要配置 PMTiles XYZ 瓦片服务',
      );
      return;
    }

    final cell = _cell(wgsLat, wgsLon);
    if (_lastCell == cell) return;
    _lastCell = cell;
    _busy = true;
    try {
      final regions = await ml.getListOfRegions();
      final existing = regions.where(
        (region) => region.metadata['vitaloop_city_cell'] == cell,
      );
      if (existing.isNotEmpty) {
        final region = existing.first;
        final status = await ml.getOfflineRegionStatus(region.id);
        final revision = region.metadata['style_revision'];
        if (status.isComplete && revision == _pmtilesOfflineStyleRevision) {
          state.value = CityMapDownloadState(
            complete: true,
            progress: 1,
            message: '当前城市离线地图已下载',
            regionId: region.id,
          );
          return;
        }
        await ml.deleteOfflineRegion(region.id);
      }

      final bounds = ml.LatLngBounds(
        southwest: ml.LatLng((wgsLat - 0.22).clamp(-85.0, 85.0), wgsLon - 0.22),
        northeast: ml.LatLng((wgsLat + 0.22).clamp(-85.0, 85.0), wgsLon + 0.22),
      );
      await ml.setOfflineTileCountLimit(30000);
      await ml.setOfflineMaxConcurrentRequests(
        maxRequests: 4,
        maxRequestsPerHost: 2,
      );
      final styleUrl =
          '${settings.pmtilesUrl.replaceFirst(RegExp(r'/+$'), '')}/style.json';
      state.value = const CityMapDownloadState(
        active: true,
        message: '准备下载当前城市地图…',
      );
      int? downloadedRegionId;
      final region = await ml.downloadOfflineRegion(
        ml.OfflineRegionDefinition(
          bounds: bounds,
          mapStyleUrl: styleUrl,
          minZoom: 10,
          maxZoom: 15,
        ),
        metadata: {
          'source': 'vitaloop-city',
          'vitaloop_city_cell': cell,
          'style_revision': _pmtilesOfflineStyleRevision,
          'center_lat': wgsLat,
          'center_lon': wgsLon,
        },
        onEvent: (event) {
          switch (event) {
            case ml.InProgress():
              state.value = CityMapDownloadState(
                active: true,
                progress: event.progress / 100,
                message: '下载当前城市地图 ${event.progress.toStringAsFixed(0)}%',
                regionId: downloadedRegionId,
              );
            case ml.Success():
              state.value = CityMapDownloadState(
                complete: true,
                progress: 1,
                message: '当前城市离线地图已下载',
                regionId: downloadedRegionId,
              );
            case ml.Error(:final cause):
              state.value = CityMapDownloadState(
                message: '城市地图下载失败：${cause.message ?? cause.code}',
                regionId: downloadedRegionId,
              );
          }
        },
      );
      downloadedRegionId = region.id;
      state.value = CityMapDownloadState(
        active: true,
        progress: state.value.progress,
        message: state.value.message.isEmpty
            ? '正在下载当前城市地图…'
            : state.value.message,
        regionId: downloadedRegionId,
      );
    } catch (error) {
      _lastCell = null;
      state.value = CityMapDownloadState(message: '城市地图下载失败：$error');
    } finally {
      _busy = false;
    }
  }

  /// 高德底图：把城市范围的栅格瓦片预取进 [AmapTileCache]。
  ///
  /// 高德瓦片是 GCJ-02，传入 WGS-84 时先换算中心点；缓存按 z/x/y 落盘，
  /// 之后离线打开同一区域会直接读盘。带路名 / 无路名是两套瓦片，
  /// 完成标记里带上当前标签模式，切换「显示街道名称」后会重新补一份。
  Future<void> _ensureAmapCity(
    double lat,
    double lon, {
    required bool gcj02,
    bool force = false,
  }) async {
    final settings = MapDisplaySettings.instance;
    final (wgsLat, wgsLon) = gcj02
        ? Coordinate.gcj02ToWgs84(lat, lon)
        : (lat, lon);
    final key = '${_cell(wgsLat, wgsLon)}/${settings.showLabels ? 'l' : 'n'}';
    // 自动触发时定位每秒都会来一次；同一城市刚失败过就等 10 分钟再重试，
    // 避免网络不通时每秒重发上千个瓦片请求。
    final failedAt = _failedAt;
    if (!force &&
        _failedKey == key &&
        failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(minutes: 10)) {
      return;
    }
    if (!force && _lastCell == key) return;
    _lastCell = key;
    _busy = true;
    try {
      final doneCell = await VitaloopApi.setting('amap_offline_city_cell', '');
      if (!force && doneCell == key) {
        state.value = const CityMapDownloadState(
          complete: true,
          progress: 1,
          message: '当前城市离线地图已下载',
        );
        return;
      }
      final (gcjLat, gcjLon) = gcj02
          ? (lat, lon)
          : Coordinate.wgs84ToGcj02(lat, lon);
      final urls = amapCityTileUrls(
        lat: gcjLat,
        lon: gcjLon,
        labels: settings.showLabels,
      );
      state.value = const CityMapDownloadState(
        active: true,
        message: '准备下载当前城市地图…',
      );
      var finished = 0;
      var failed = 0;
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final index = next++;
          if (index >= urls.length) return;
          final bytes = await AmapTileCache.instance.load(urls[index]);
          if (bytes == null || bytes.isEmpty) failed++;
          finished++;
          if (finished % 16 == 0 || finished == urls.length) {
            state.value = CityMapDownloadState(
              active: true,
              progress: finished / urls.length,
              message:
                  '下载当前城市地图 ${(finished / urls.length * 100).toStringAsFixed(0)}%',
            );
          }
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      if (failed > urls.length ~/ 10) {
        _lastCell = null;
        _failedKey = key;
        _failedAt = DateTime.now();
        state.value = CityMapDownloadState(
          message: '城市地图下载不完整（$failed/${urls.length} 失败），可稍后重试',
        );
        return;
      }
      await VitaloopApi.setSetting('amap_offline_city_cell', key);
      _failedKey = null;
      _failedAt = null;
      state.value = const CityMapDownloadState(
        complete: true,
        progress: 1,
        message: '当前城市离线地图已下载',
      );
    } catch (error) {
      _lastCell = null;
      _failedKey = key;
      _failedAt = DateTime.now();
      state.value = CityMapDownloadState(message: '城市地图下载失败：$error');
    } finally {
      _busy = false;
    }
  }

  static String _cell(double lat, double lon) =>
      '${(lat / 0.5).floor()}:${(lon / 0.5).floor()}';
}
