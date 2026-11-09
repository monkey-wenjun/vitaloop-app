import 'package:flutter/material.dart' hide Text;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/gps_bridge.dart';
import '../../data/map_display.dart';
import '../../data/map_offline_service.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

class MapSettingsScreen extends StatefulWidget {
  const MapSettingsScreen({super.key});

  @override
  State<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends State<MapSettingsScreen> {
  late final TextEditingController _source;
  bool _loading = true;
  bool _downloading = false;

  MapDisplaySettings get settings => MapDisplaySettings.instance;

  @override
  void initState() {
    super.initState();
    _source = TextEditingController(text: settings.pmtilesUrl);
    settings.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    settings.removeListener(_changed);
    _source.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await settings.load();
    if (!mounted) return;
    _source.text = settings.pmtilesUrl;
    setState(() => _loading = false);
  }

  Future<void> _downloadCity() async {
    if (_downloading) return;
    final fix = await GpsBridge.instance.lastKnown();
    if (!mounted) return;
    if (fix == null) {
      _toast('没有可用定位，请先打开定位或开始一次运动');
      return;
    }
    setState(() => _downloading = true);
    try {
      await MapOfflineService.instance.ensureCity(ml.LatLng(fix.lat, fix.lon));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '地图与离线'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              const VSectionHead(title: '底图'),
              for (final provider in MapBaseProvider.values)
                _providerCard(v, provider),
              const VSectionHead(title: 'PMTiles'),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Liberty / Dark · PMTiles',
                      style: VText.h3.copyWith(color: v.ink),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '亮色使用 Liberty 风格的浅色陆地、蓝色水域和白色道路；暗色使用深海军蓝底图。两种主题都由 Protomaps PMTiles 数据提供。',
                      style: VText.label.copyWith(color: v.muted, height: 1.55),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _source,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'PMTiles 瓦片服务',
                        hintText: 'https://example.com',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '可直接填写 PMTiles 文件或 XYZ 瓦片服务；城市离线下载需要后者。',
                            style: VText.label.copyWith(
                              fontSize: 10,
                              color: v.muted,
                              height: 1.45,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonal(
                          onPressed: () async {
                            await settings.setPmtilesUrl(_source.text);
                            if (mounted) _toast('PMTiles 地址已保存');
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '当前城市离线地图'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    VRowItem(
                      icon: Icons.download_for_offline_rounded,
                      iconBackground: v.tintGreen,
                      iconColor: v.greenInk,
                      title: '自动下载当前城市',
                      subtitle: '首次看到 GPS 位置后，下载当前位置约 40 公里范围、缩放 10–15 的瓦片',
                      trailing: Switch(
                        value: settings.offlineCityEnabled,
                        activeThumbColor: v.blue,
                        onChanged: settings.setOfflineCityEnabled,
                      ),
                    ),
                    ValueListenableBuilder<CityMapDownloadState>(
                      valueListenable: MapOfflineService.instance.state,
                      builder: (context, state, _) {
                        return VRowItem(
                          icon: state.complete
                              ? Icons.offline_pin_rounded
                              : Icons.map_rounded,
                          iconBackground: state.complete
                              ? v.tintGreen
                              : v.tintBlue,
                          iconColor: state.complete ? v.greenInk : v.blueInk,
                          title: state.message.isEmpty ? '离线状态' : state.message,
                          subtitle: state.active && !state.complete
                              ? '${(state.progress * 100).round()}%'
                              : '只在默认 PMTiles 底图下生效',
                          value: _downloading ? '下载中' : '立即下载',
                          onTap: _downloading ? null : _downloadCity,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _providerCard(VColors v, MapBaseProvider provider) {
    final selected = settings.provider == provider;
    final description = switch (provider) {
      MapBaseProvider.pmtiles => '默认。自托管矢量地图，支持城市离线缓存。',
      MapBaseProvider.amap => '沿用现有高德 GCJ-02 栅格底图。',
      MapBaseProvider.tencent => '需要配置腾讯地图官方 SDK Key；当前显示轨迹叠加。',
      MapBaseProvider.baidu => '需要配置百度地图官方 SDK Key；BD-09 坐标单独适配。',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: VCard(
        onTap: () => settings.setProvider(provider),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? v.tintBlue : v.tintGrey,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                provider == MapBaseProvider.pmtiles
                    ? Icons.public_rounded
                    : Icons.map_rounded,
                color: selected ? v.blueInk : v.greyInk,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        provider.label,
                        style: VText.h3.copyWith(color: v.ink),
                      ),
                      if (provider == MapBaseProvider.pmtiles) ...[
                        const SizedBox(width: 7),
                        const VChip(text: '默认'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: VText.label.copyWith(
                      fontSize: 10.5,
                      color: v.muted,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? v.blueInk : v.muted,
            ),
          ],
        ),
      ),
    );
  }
}
