import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

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

  Future<void> ensureCity(ml.LatLng center) async {
    if (_busy || !center.latitude.isFinite || !center.longitude.isFinite) {
      return;
    }
    final settings = MapDisplaySettings.instance;
    await settings.load();
    if (settings.provider != MapBaseProvider.pmtiles ||
        !settings.offlineCityEnabled ||
        settings.pmtilesUrl.trim().isEmpty) {
      return;
    }
    if (settings.pmtilesUrl.contains('.pmtiles')) {
      state.value = const CityMapDownloadState(
        message: '城市离线下载需要配置 PMTiles XYZ 瓦片服务',
      );
      return;
    }

    final cell =
        '${(center.latitude / 0.5).floor()}:${(center.longitude / 0.5).floor()}';
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
        southwest: ml.LatLng(
          (center.latitude - 0.22).clamp(-85.0, 85.0),
          center.longitude - 0.22,
        ),
        northeast: ml.LatLng(
          (center.latitude + 0.22).clamp(-85.0, 85.0),
          center.longitude + 0.22,
        ),
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
          'center_lat': center.latitude,
          'center_lon': center.longitude,
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
}
