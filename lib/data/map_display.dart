import 'package:flutter/foundation.dart';

import 'api.dart';

/// 地图展示偏好。运动详情、实时码表和分享截图共用同一份设置。
class MapDisplaySettings extends ChangeNotifier {
  MapDisplaySettings._();

  static final MapDisplaySettings instance = MapDisplaySettings._();

  bool showBaseMap = true;
  bool showLabels = true;
  int markerIntervalM = 1000;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
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
    } catch (_) {
      // 设置读不到时用默认值，不能因为地图偏好把页面拦住。
    }
    _loaded = true;
    notifyListeners();
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
}
