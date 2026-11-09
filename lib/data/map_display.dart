import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';

enum MapBaseProvider {
  pmtiles('OpenStreetMap · PMTiles'),
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
  int markerIntervalM = 1000;
  MapBaseProvider provider = MapBaseProvider.pmtiles;
  String pmtilesUrl = defaultPmtilesUrl;
  bool offlineCityEnabled = false;
  bool _loaded = false;
  bool _defaultsLoaded = false;

  static const defaultPmtilesUrl =
      'https://build.protomaps.com/20261109.pmtiles';

  Future<void> load() async {
    if (_loaded) return;
    await _loadDefaults();
    try {
      showBaseMap = await VitaloopApi.setting('map_show_base', '1') != '0';
      showLabels = await VitaloopApi.setting('map_show_labels', '1') != '0';
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
      pmtilesUrl = await VitaloopApi.setting(
        'map_pmtiles_url',
        pmtilesUrl,
      );
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
