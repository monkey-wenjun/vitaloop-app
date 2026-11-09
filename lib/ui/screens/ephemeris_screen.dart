import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/watch_bridge.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

/// GPS 星历（AGNSS）详情页：手机侧自托管一份 ephemeris.zip，
/// 手表连上后通过 EphemerisFileUpload 协议主动问手机要，省掉手表自己联网搜星冷启动。
class EphemerisScreen extends StatefulWidget {
  const EphemerisScreen({super.key});

  @override
  State<EphemerisScreen> createState() => _EphemerisScreenState();
}

class _EphemerisScreenState extends State<EphemerisScreen> {
  final _urlController = TextEditingController();
  Map<String, dynamic> _status = {};
  bool _loading = true;
  bool _saving = false;
  String _hint = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(WatchBridge.instance.ensureEphemeris());
    // 下载在原生线程里跑，页面开着就该看到进度变化
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final status = await WatchBridge.instance.ephemerisStatus();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
      if (_urlController.text.isEmpty) {
        _urlController.text = (status['url'] as String? ?? '');
      }
    });
  }

  Future<void> _saveUrl() async {
    final url = _urlController.text.trim();
    setState(() => _saving = true);
    // 地址同时写进库：换设备或重装后由这里回填，不用用户填第二遍
    await WatchBridge.instance.saveEphemerisUrl(url);
    if (mounted) {
      setState(() {
        _saving = false;
        _hint = url.isEmpty ? '已清空地址：星历只由手表自行更新' : '地址已保存，下次连接即生效';
      });
    }
    await _load();
  }

  Future<void> _downloadNow() async {
    setState(() => _hint = '正在下载星历包...');
    final msg = await WatchBridge.instance.downloadEphemeris();
    if (!mounted) return;
    setState(() => _hint = msg);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final exists = _status['exists'] == true;
    final needsRefresh = _status['needsRefresh'] == true;
    final downloading = _status['downloading'] == true;
    final ageMs = (_status['ageMs'] as num?)?.toInt() ?? -1;
    final agnssMs = (_status['agnssTime'] as num?)?.toInt() ?? 0;
    final size = (_status['size'] as num?)?.toInt() ?? 0;
    final error = _status['error'] as String? ?? '';
    final connected = WatchBridge.instance.state.value == 'ready';
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(
              title: 'GPS 星历',
              trailing: VIconButton(
                icon: Icons.refresh_rounded,
                onTap: () => _load(),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 140),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              VCard(
                background: exists && !needsRefresh ? v.green : v.sky,
                foreground: exists && !needsRefresh ? v.greenInk : v.skyInk,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.satellite_alt_rounded,
                          size: 20,
                          color: (exists && !needsRefresh
                              ? v.greenInk
                              : v.skyInk),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          downloading
                              ? '正在下载星历包'
                              : (exists
                                    ? (needsRefresh ? '星历已过期，等待刷新' : '星历可用')
                                    : '本机还没有星历文件'),
                          style: VText.value.copyWith(
                            fontSize: 17,
                            color: exists && !needsRefresh
                                ? v.greenInk
                                : v.skyInk,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      exists
                          ? '文件 ${_fmtSize(size)}　·　生成于 ${_ago(ageMs)}\n星历数据时间：${agnssMs > 0 ? _full(DateTime.fromMillisecondsSinceEpoch(agnssMs)) : '未能从包内解析'}\n手表连接后会自动向手机索要这份星历。'
                          : '手表在没拿到手机星历时要自己搜星，冷启动定位通常慢 30 秒以上。\n填一个自托管的 ephemeris.zip 地址，手机就会代手表下载并下发。',
                      style: VText.label.copyWith(
                        fontSize: 11,
                        color: (exists && !needsRefresh ? v.greenInk : v.skyInk)
                            .withValues(alpha: 0.82),
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '下载地址'),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _urlController,
                      minLines: 2,
                      maxLines: 3,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      style: VText.body.copyWith(fontSize: 12, color: v.ink),
                      decoration: InputDecoration(
                        hintText: tr('https://你的服务器/ephemeris.zip'),
                        hintStyle: VText.body.copyWith(
                          fontSize: 12,
                          color: v.muted,
                        ),
                        filled: true,
                        fillColor: v.tintGrey,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: VPrimaryButton(
                            label: _saving ? '保存中...' : '保存地址',
                            icon: Icons.save_rounded,
                            onTap: _saving ? null : _saveUrl,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: VGhostButton(
                            label: downloading ? '下载中...' : '立即下载',
                            icon: Icons.download_rounded,
                            onTap: downloading ? null : _downloadNow,
                          ),
                        ),
                      ],
                    ),
                    if (_hint.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _hint,
                        style: VText.label.copyWith(
                          fontSize: 11,
                          color: v.ink2,
                          height: 1.5,
                        ),
                      ),
                    ],
                    if (error.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '上次错误：$error',
                        style: VText.label.copyWith(
                          fontSize: 11,
                          color: v.heartInk,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const VSectionHead(title: '文件与下发状态'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    VRowItem(
                      icon: Icons.description_rounded,
                      iconBackground: exists ? v.tintGreen : v.tintGrey,
                      iconColor: exists ? v.greenInk : v.ink2,
                      title: '星历文件',
                      subtitle: exists
                          ? '${_fmtSize(size)} · 生成于 ${_ago(ageMs)}'
                          : '尚未下载到本机',
                      value: exists ? '已就绪' : '缺失',
                      color: exists ? v.greenInk : v.muted,
                    ),
                    VRowItem(
                      icon: Icons.schedule_rounded,
                      iconBackground: needsRefresh ? v.tintPeach : v.tintGreen,
                      iconColor: needsRefresh ? v.warnInk : v.greenInk,
                      title: '是否需要刷新',
                      subtitle: '手机每 10 分钟检查一次，过期会自动重下',
                      value: needsRefresh ? '需要' : '不需要',
                      color: needsRefresh ? v.warnInk : v.greenInk,
                    ),
                    VRowItem(
                      icon: Icons.tag_rounded,
                      iconBackground: v.tintBlue,
                      iconColor: v.blueInk,
                      title: '手表应答记录',
                      subtitle: (_status['consultMs'] as num? ?? 0).toInt() > 0
                          ? '${_full(DateTime.fromMillisecondsSinceEpoch((_status['consultMs'] as num).toInt()))} 应答 tag=${_status['consultTag']}，版本 ${_status['consultVer']}'
                          : '手表还没向手机索要过星历',
                      value: (_status['consultMs'] as num? ?? 0).toInt() > 0
                          ? '已下发'
                          : '—',
                    ),
                    VRowItem(
                      icon: Icons.bluetooth_connected_rounded,
                      iconBackground: connected ? v.tintGreen : v.tintGrey,
                      iconColor: connected ? v.greenInk : v.ink2,
                      title: '当前链路',
                      subtitle: connected
                          ? '手表已连接，可随时索要星历'
                          : '未连接；连上后手机会立刻补一次下载',
                      value: connected ? '在线' : '离线',
                      color: connected ? v.greenInk : v.muted,
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '工作方式'),
              VCard(
                child: Text(
                  '1. 手机从你填的地址下载 ephemeris.zip（内含 AGNSS/RTCM 1019 星历），按包内数据时间判断是否过期，过期才重下。\n'
                  '2. 手表连接后走华为 EphemerisFileUpload 协议：先问手机有没有文件，再按 2KB 分包上传到手表。\n'
                  '3. 若手表主动来要而本地还没文件，手机会阻塞补下载约 6 秒，拿到就当场应答；下载中也会把已有旧文件先给手表，不空手等。\n'
                  '4. 公开构建不内置星历源；填写自己的 ephemeris.zip 地址后才会下载。',
                  style: VText.body.copyWith(
                    fontSize: 12,
                    color: v.ink2,
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String _ago(int ms) {
    if (ms < 0) return '未知';
    final minutes = ms ~/ 60000;
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return '$minutes 分钟前';
    final hours = minutes ~/ 60;
    if (hours < 24) return '$hours 小时前';
    return '${hours ~/ 24} 天前';
  }

  String _full(DateTime d) =>
      '${d.month}月${d.day}日 ${clock(d)}:${two(d.second)}';
}
