import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';

enum MapBaseProvider {
  pmtiles('OpenStreetMap · PMTiles'),
  opentopo('等高线地形 · OpenTopoMap'),
  amap('高德地图'),
  tencent('腾讯地图'),
  baidu('百度地图');

  const MapBaseProvider(this.label);

  final String label;
}

/// 地图展示偏好。运动详情、实时码表和分享截图共用同一份设置。
class MapDisplaySettings extends ChangeNotifier {
  MapDisplaySettings._();

  static final MapDisplaySettings instance = MapDisplaySettings._();

  bool showBaseMap = true;
  bool showLabels = true;
  /// 山体阴影 + 海拔分层着色。默认开，山区徒步一眼能看出山脊和沟谷。
  bool showTerrain = true;
  /// 等高线。和 [showTerrain] 分开：有人只想看立体阴影，不想被线铺满。
  bool showContours = true;
  /// 立体视角的俯仰角度。0 为正俯视，45 接近高驰那种斜看山体。
  double pitch = 45;
  int markerIntervalM = 1000;

  /// 默认走自托管 PMTiles；用户可以在设置里切到高德。
  MapBaseProvider provider = MapBaseProvider.pmtiles;
  String pmtilesUrl = defaultPmtilesUrl;
  /// DEM 瓦片服务。空字符串时从 [pmtilesUrl] 推导 `https://host/dem`。
  String demUrl = '';
  /// 等高线瓦片服务。空字符串时从 DEM 地址推导。
  String contourUrl = '';
  bool offlineCityEnabled = false;
  bool _loaded = false;
  bool _defaultsLoaded = false;

  /// 公共构建不内置任何私有域名；由用户在设置里填写或构建时注入。
  static const defaultPmtilesUrl = String.fromEnvironment('PMTILES_URL');

  Future<void> load() async {
    if (_loaded) return;
    await _loadDefaults();
    try {
      showBaseMap = await VitaloopApi.setting('map_show_base', '1') != '0';
      showLabels = await VitaloopApi.setting('map_show_labels', '1') != '0';
      showTerrain = await VitaloopApi.setting('map_show_terrain', '1') != '0';
      showContours = await VitaloopApi.setting('map_show_contours', '1') != '0';
      pitch = (await VitaloopApi.setting('map_pitch', '45')) == '0' ? 0 : 45;
      markerIntervalM = switch (await VitaloopApi.setting(
        'map_marker_interval_m',
        '1000',
      )) {
        '5000' => 5000,
        _ => 1000,
      };
      final providerName = await VitaloopApi.setting(
        'map_base_provider',
        MapBaseProvider.pmtiles.name,
      );
      provider = MapBaseProvider.values.firstWhere(
        (item) => item.name == providerName,
        orElse: () => MapBaseProvider.pmtiles,
      );
      // 只做默认值：用户已经在设置里选过底图时，不能被默认值覆盖。
      pmtilesUrl = await VitaloopApi.setting('map_pmtiles_url', pmtilesUrl);
      demUrl = await VitaloopApi.setting('map_dem_url', demUrl);
      contourUrl = await VitaloopApi.setting('map_contour_url', contourUrl);
      offlineCityEnabled =
          await VitaloopApi.setting(
            'map_offline_city',
            offlineCityEnabled ? '1' : '0',
          ) !=
          '0';
    } catch (_) {
      // 设置读不到时用默认值，不能因为地图偏好把页面拦住。
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _loadDefaults() async {
    if (_defaultsLoaded) return;
    try {
      final raw = await rootBundle.loadString(
        'assets/config/map_defaults.json',
      );
      final data = jsonDecode(raw);
      if (data is Map) {
        final url = data['tileServerUrl'];
        if (url is String && url.trim().isNotEmpty) {
          pmtilesUrl = url.trim();
        }
        offlineCityEnabled = data['offlineCityEnabled'] == true;
      }
    } catch (_) {}
    _defaultsLoaded = true;
  }

  Future<void> setShowBaseMap(bool value) async {
    if (showBaseMap == value) return;
    showBaseMap = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_show_base', value ? '1' : '0');
    } catch (_) {}
  }

  Future<void> setShowLabels(bool value) async {
    if (showLabels == value) return;
    showLabels = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_show_labels', value ? '1' : '0');
    } catch (_) {}
  }

  Future<void> setShowTerrain(bool value) async {
    if (showTerrain == value) return;
    showTerrain = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_show_terrain', value ? '1' : '0');
    } catch (_) {}
  }

  Future<void> setShowContours(bool value) async {
    if (showContours == value) return;
    showContours = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_show_contours', value ? '1' : '0');
    } catch (_) {}
  }

  /// 只在「正俯视」和「立体 45°」之间切，避免出现一堆没意义的中间值。
  Future<void> setPitch(double value) async {
    final next = value >= 30 ? 45.0 : 0.0;
    if (pitch == next) return;
    pitch = next;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_pitch', '${next.round()}');
    } catch (_) {}
  }

  /// 真正给地图样式用的 DEM 地址：显式配置优先，否则跟 PMTiles 同源。
  String get effectiveDemUrl {
    final explicit = demUrl.trim();
    if (explicit.isNotEmpty) return explicit;
    final base = pmtilesUrl.trim();
    if (base.isEmpty) return '';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.host}/dem';
  }

  /// 等高线瓦片地址：显式配置优先，否则和 DEM 同源。
  String get effectiveContourUrl {
    final explicit = contourUrl.trim();
    if (explicit.isNotEmpty) return explicit;
    final base = effectiveDemUrl;
    if (base.isEmpty) return '';
    return base.endsWith('/dem')
        ? '${base.substring(0, base.length - 4)}/contours'
        : '$base/contours';
  }

  Future<void> setMarkerIntervalM(int value) async {
    final next = value == 5000 ? 5000 : 1000;
    if (markerIntervalM == next) return;
    markerIntervalM = next;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_marker_interval_m', '$next');
    } catch (_) {}
  }

  Future<void> setProvider(MapBaseProvider value) async {
    if (provider == value) return;
    provider = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_base_provider', value.name);
    } catch (_) {}
  }

  Future<void> setPmtilesUrl(String value) async {
    final next = value.trim();
    if (next.isEmpty || pmtilesUrl == next) return;
    pmtilesUrl = next;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_pmtiles_url', next);
    } catch (_) {}
  }

  Future<void> setOfflineCityEnabled(bool value) async {
    if (offlineCityEnabled == value) return;
    offlineCityEnabled = value;
    notifyListeners();
    try {
      await VitaloopApi.setSetting('map_offline_city', value ? '1' : '0');
    } catch (_) {}
  }
}
