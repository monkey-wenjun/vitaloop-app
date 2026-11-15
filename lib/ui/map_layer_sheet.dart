import 'package:flutter/material.dart';

import '../data/map_display.dart';

/// 长按地图弹出的图层菜单。高德底图和 PMTiles 底图共用一份，
/// 免得两边开关各写一遍、慢慢长歪。
Future<void> showMapLayerSheet(
  BuildContext context, {
  required VoidCallback onChanged,
}) {
  final settings = MapDisplaySettings.instance;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        void apply(VoidCallback change) {
          change();
          setSheet(() {});
          onChanged();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('显示地图底图'),
                subtitle: const Text('关闭后只保留轨迹线，适合分享时隐藏位置'),
                trailing: Switch(
                  value: settings.showBaseMap,
                  onChanged: (value) => apply(
                    () => settings.setShowBaseMap(value),
                  ),
                ),
              ),
              ListTile(
                enabled: settings.showBaseMap,
                title: const Text('显示街道名称'),
                subtitle: const Text('关闭后不显示路名、村庄和地点文字'),
                trailing: Switch(
                  value: settings.showLabels,
                  onChanged: settings.showBaseMap
                      ? (value) => apply(() => settings.setShowLabels(value))
                      : null,
                ),
              ),
              if (settings.provider == MapBaseProvider.pmtiles)
                ListTile(
                  enabled: settings.showBaseMap,
                  leading: Icon(
                    Icons.landscape_rounded,
                    color: settings.showTerrain
                        ? const Color(0xFF2EAD62)
                        : null,
                  ),
                  title: const Text('山体阴影'),
                  subtitle: const Text('用 DEM 海拔勾出山脊沟谷，并按海拔分层着色'),
                  trailing: Switch(
                    value: settings.showTerrain,
                    onChanged: settings.showBaseMap
                        ? (value) => apply(() => settings.setShowTerrain(value))
                        : null,
                  ),
                ),
              if (settings.provider == MapBaseProvider.pmtiles) ...[
                ListTile(
                  enabled: settings.showBaseMap,
                  leading: Icon(
                    Icons.line_weight_rounded,
                    color: settings.showContours
                        ? const Color(0xFF2EAD62)
                        : null,
                  ),
                  title: const Text('等高线'),
                  subtitle: const Text('每 20–50 米一条线，粗线为整百米'),
                  trailing: Switch(
                    value: settings.showContours,
                    onChanged: settings.showBaseMap
                        ? (value) => apply(
                            () => settings.setShowContours(value),
                          )
                        : null,
                  ),
                ),
                ListTile(
                  enabled: settings.showBaseMap,
                  leading: Icon(
                    Icons.threed_rotation_rounded,
                    color: settings.pitch > 0
                        ? const Color(0xFF2EAD62)
                        : null,
                  ),
                  title: const Text('立体视角'),
                  subtitle: Text(
                    settings.pitch > 0
                        ? '斜看山体（45°），接近高驰的运动地图'
                        : '正俯视，方便看轨迹走向',
                  ),
                  trailing: Switch(
                    value: settings.pitch > 0,
                    onChanged: settings.showBaseMap
                        ? (value) => apply(
                            () => settings.setPitch(value ? 45 : 0),
                          )
                        : null,
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}
