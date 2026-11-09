import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/watch_bridge.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class WatchToolsScreen extends StatefulWidget {
  const WatchToolsScreen({super.key});

  @override
  State<WatchToolsScreen> createState() => _WatchToolsScreenState();
}

class _WatchToolsScreenState extends State<WatchToolsScreen> {
  Timer? _timer;
  bool _busy = false;

  WatchBridge get bridge => WatchBridge.instance;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await bridge.watchToolsStatus();
    if (!mounted || status.isEmpty) return;
    bridge.watchTools.value = status;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: bridge.watchTools,
          builder: (context, status, _) {
            final connected = status['connected'] == true;
            final toolBusy = status['busy'] == true;
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 32),
              children: [
                VDetailHeader(
                  title: '手表工具',
                  trailing: _busy || toolBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh_rounded, size: 20),
                        ),
                ),
                _statusCard(v, status, connected),
                const VSectionHead(title: '手机联动'),
                VCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      VRowItem(
                        icon: Icons.phonelink_ring_rounded,
                        iconBackground: v.tintPeach,
                        iconColor: v.warnInk,
                        title: '查找手机',
                        subtitle: '手表发起查找时，手机响铃并振动 30 秒',
                        trailing: Switch(
                          value: status['findPhone'] == true,
                          onChanged: (on) =>
                              _run(() => bridge.setFindPhone(on)),
                        ),
                      ),
                      VRowItem(
                        icon: Icons.notifications_active_rounded,
                        iconBackground: v.tintGreen,
                        iconColor: v.greenInk,
                        title: '测试响铃',
                        subtitle: '立即在本机响铃，确认铃声与振动正常',
                        value: '点击',
                        onTap: () => _run(bridge.testFindPhone),
                      ),
                      VRowItem(
                        icon: Icons.notifications_off_rounded,
                        iconBackground: v.tintGrey,
                        iconColor: v.greyInk,
                        title: '停止查找',
                        subtitle: '结束手机响铃，并通知手表停止',
                        onTap: () => _run(bridge.stopFindPhone),
                      ),
                      VRowItem(
                        icon: Icons.photo_camera_rounded,
                        iconBackground: v.tintPurple,
                        iconColor: v.purpleInk,
                        title: '遥控拍照',
                        subtitle: '手表打开相机、按下快门时在本机拍照',
                        trailing: Switch(
                          value: status['cameraRemote'] == true,
                          onChanged: (on) => _run(() async {
                            final ok = await bridge.setCameraRemote(on);
                            if (on && !ok) _toast('未授予相机权限');
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const VSectionHead(title: '离线地图'),
                _offlineMapCard(v, status, connected),
                const VSectionHead(title: '联系人'),
                VCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: VRowItem(
                    icon: Icons.contacts_rounded,
                    iconBackground: v.tintBlue,
                    iconColor: v.blueInk,
                    title: '同步手机联系人',
                    subtitle: '手表最多可保存 ${status['contactsMax'] ?? 20} 个联系人',
                    value: '同步',
                    showChevron: true,
                    onTap: connected
                        ? () => _run(() async {
                            final ok = await bridge.syncContacts();
                            if (!ok) _toast('未授予联系人权限');
                          })
                        : null,
                  ),
                ),
                VSectionHead(
                  title: '应用',
                  trailing: '刷新',
                  onTrailing: connected ? bridge.loadApps : null,
                ),
                _appsCard(v, status, connected),
                VSectionHead(
                  title: '表盘',
                  trailing: '刷新',
                  onTrailing: connected ? bridge.loadWatchfaces : null,
                ),
                _watchfacesCard(v, status, connected),
                const VSectionHead(title: '手表音乐'),
                _musicCard(v, status, connected),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _statusCard(VColors v, Map<String, dynamic> status, bool connected) {
    final message = status['message'] as String? ?? '';
    final busy = status['busy'] == true;
    return VCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: connected ? v.tintGreen : v.tintGrey,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              connected ? Icons.watch_rounded : Icons.watch_off_rounded,
              size: 20,
              color: connected ? v.greenInk : v.greyInk,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? '手表已连接' : '手表未连接',
                  style: VText.h3.copyWith(color: v.ink),
                ),
                const SizedBox(height: 3),
                Text(
                  message.isEmpty
                      ? (busy ? '正在等待手表响应…' : '工具操作会占用同一条蓝牙链路')
                      : message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: VText.label.copyWith(color: v.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _appsCard(VColors v, Map<String, dynamic> status, bool connected) {
    final apps = (status['apps'] as List?) ?? const [];
    return VCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          if (apps.isEmpty)
            VRowItem(
              icon: Icons.apps_rounded,
              iconBackground: v.tintGrey,
              iconColor: v.greyInk,
              title: '还没有读取应用列表',
              subtitle: connected ? '点右上角「刷新」从手表读取' : '连接手表后可读取已安装应用',
            )
          else
            for (final raw in apps)
              VRowItem(
                icon: Icons.widgets_rounded,
                iconBackground: v.tintBlue,
                iconColor: v.blueInk,
                title: (raw as Map)['name'] as String? ?? '',
                subtitle:
                    '${raw['package'] ?? ''} · ${raw['version'] ?? ''} (${raw['versionCode'] ?? ''})',
                trailing: IconButton(
                  tooltip: tr('删除'),
                  onPressed: connected
                      ? () async {
                          final ok = await _confirm(
                            title: '删除手表应用',
                            body: '确定从手表删除 ${raw['name']}？',
                          );
                          if (ok) {
                            await _run(
                              () => bridge.deleteApp(
                                raw['package'] as String? ?? '',
                              ),
                            );
                          }
                        }
                      : null,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: v.danger,
                  ),
                ),
              ),
          const Divider(height: 1),
          VRowItem(
            icon: Icons.add_box_rounded,
            iconBackground: v.tintGreen,
            iconColor: v.greenInk,
            title: '安装手表应用',
            subtitle: '从本机选择一个 APK 推到手表',
            showChevron: true,
            onTap: connected ? () => _installApp(v) : null,
          ),
          if ((status['appUploadStatus'] as String? ?? '').isNotEmpty)
            _progressBlock(
              v,
              status['appUploadStatus'] as String,
              (status['appUploadProgress'] as num?)?.toInt() ?? -1,
            ),
        ],
      ),
    );
  }

  Widget _offlineMapCard(
    VColors v,
    Map<String, dynamic> status,
    bool connected,
  ) {
    final supported = status['mapSupported'] == true;
    final pushing = status['mapPushRunning'] == true;
    final mapStatus = status['mapStatus'] as String? ?? '';
    return VCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          VRowItem(
            icon: Icons.map_rounded,
            iconBackground: supported ? v.tintGreen : v.tintGrey,
            iconColor: supported ? v.greenInk : v.greyInk,
            title: '离线地图通道',
            subtitle: mapStatus.isNotEmpty
                ? mapStatus
                : (!connected
                      ? '连接手表后可检查手表空间并下发地图包'
                      : supported
                      ? '只转发你本地的华为手表地图包，不联网下载'
                      : '这块手表不支持离线地图（能力位 201）'),
            trailing: pushing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          VRowItem(
            icon: Icons.sd_storage_rounded,
            iconBackground: v.tintBlue,
            iconColor: v.blueInk,
            title: '检查地图空间',
            subtitle: '查询手表剩余空间和已下载地图数量',
            value: '检查',
            onTap: connected && !pushing
                ? () => _run(() async {
                    final result = await bridge.probeOfflineMap();
                    _toast(result['message'] as String? ?? '探测完成');
                  })
                : null,
          ),
          VRowItem(
            icon: Icons.upload_file_rounded,
            iconBackground: v.tintPeach,
            iconColor: v.warnInk,
            title: '选择地图包并发送',
            subtitle: '单个文件上限 128 MB，传输期间请保持手表靠近手机',
            value: supported ? '发送' : null,
            showChevron: supported,
            onTap: connected && supported && !pushing
                ? _pickAndPushOfflineMap
                : null,
          ),
          if (pushing)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: v.line,
                  color: v.blue,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickAndPushOfflineMap() async {
    final picked = await bridge.pickOfflineMap();
    if (picked == null || !mounted) return;
    final name = picked['name'] as String? ?? 'map.bin';
    final size = (picked['size'] as num?)?.toInt() ?? 0;
    final sizeText = size <= 0
        ? '大小未知'
        : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    final ok = await _confirm(
      title: '发送离线地图',
      body: '$name\n$sizeText\n\n地图包会原样写入手表，传输期间请勿断开连接。确定发送？',
    );
    if (!ok) return;
    final uri = picked['uri'] as String? ?? '';
    if (uri.isEmpty) {
      _toast('没有拿到地图文件');
      return;
    }
    await _run(() async {
      final result = await bridge.pushOfflineMap(uri);
      _toast(result['message'] as String? ?? '发送完成');
    });
  }

  Widget _watchfacesCard(
    VColors v,
    Map<String, dynamic> status,
    bool connected,
  ) {
    final faces = (status['watchfaces'] as List?) ?? const [];
    final device =
        (status['watchfaceDevice'] as Map?)?.cast<String, dynamic>() ??
        const {};
    return VCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          if (device.isNotEmpty)
            VRowItem(
              icon: Icons.monitor_rounded,
              iconBackground: v.tintPurple,
              iconColor: v.purpleInk,
              title: '手表表盘能力',
              subtitle:
                  '${device['width'] ?? 0}×${device['height'] ?? 0} · 引擎 ${device['version'] ?? '-'} · 文件类型 ${device['fileType'] ?? '-'}',
            ),
          if (faces.isEmpty)
            VRowItem(
              icon: Icons.watch_later_rounded,
              iconBackground: v.tintGrey,
              iconColor: v.greyInk,
              title: '还没有读取表盘列表',
              subtitle: connected ? '点右上角「刷新」从手表读取' : '连接手表后可读取与切换表盘',
            )
          else
            for (final raw in faces)
              VRowItem(
                icon: (raw as Map)['current'] == true
                    ? Icons.check_circle_rounded
                    : Icons.watch_rounded,
                iconBackground: raw['current'] == true
                    ? v.tintGreen
                    : v.tintGrey,
                iconColor: raw['current'] == true ? v.greenInk : v.greyInk,
                title: raw['name'] as String? ?? raw['file'] as String? ?? '',
                subtitle:
                    '${raw['file']} · ${raw['version']}${raw['factory'] == true ? ' · 预置' : ''}',
                badge: raw['current'] == true ? '当前' : null,
                onTap: connected && raw['current'] != true
                    ? () => _run(
                        () => bridge.activateWatchface(
                          raw['file'] as String? ?? '',
                          raw['version'] as String? ?? '',
                        ),
                      )
                    : null,
                trailing: raw['factory'] == true
                    ? null
                    : IconButton(
                        tooltip: tr('删除'),
                        onPressed: connected
                            ? () async {
                                final ok = await _confirm(
                                  title: '删除表盘',
                                  body:
                                      '确定从手表删除 ${raw['name'] ?? raw['file']}？',
                                );
                                if (ok) {
                                  await _run(
                                    () => bridge.deleteWatchface(
                                      raw['file'] as String? ?? '',
                                      raw['version'] as String? ?? '',
                                    ),
                                  );
                                }
                              }
                            : null,
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 19,
                          color: v.danger,
                        ),
                      ),
              ),
          const Divider(height: 1),
          VRowItem(
            icon: Icons.upload_file_rounded,
            iconBackground: v.tintGreen,
            iconColor: v.greenInk,
            title: '安装表盘',
            subtitle: '选择 .hwt 表盘包，按手表引擎选择载荷模式',
            showChevron: true,
            onTap: connected ? () => _installWatchface(v) : null,
          ),
          if ((status['watchfaceUploadStatus'] as String? ?? '').isNotEmpty)
            _progressBlock(
              v,
              status['watchfaceUploadStatus'] as String,
              (status['watchfaceUploadProgress'] as num?)?.toInt() ?? -1,
            ),
        ],
      ),
    );
  }

  Widget _musicCard(VColors v, Map<String, dynamic> status, bool connected) {
    final tracks = (status['tracks'] as List?) ?? const [];
    final playlists = (status['playlists'] as List?) ?? const [];
    final remaining = (status['musicUploadRemaining'] as num?)?.toInt() ?? 0;
    return VCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VRowItem(
            icon: Icons.sd_storage_rounded,
            iconBackground: v.tintBlue,
            iconColor: v.blueInk,
            title: '容量与格式',
            subtitle: (status['musicCapacity'] as String? ?? '').isEmpty
                ? '读取音乐库后显示手表可用空间'
                : status['musicCapacity'] as String,
            value: connected ? '读取' : null,
            onTap: connected ? () => _run(bridge.loadMusicLibrary) : null,
          ),
          if (tracks.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
              child: Text(
                '歌曲 ${tracks.length} 首',
                style: VText.meta.copyWith(color: v.muted),
              ),
            ),
            for (final raw in tracks.take(100))
              VRowItem(
                icon: Icons.music_note_rounded,
                iconBackground: v.tintGrey,
                iconColor: v.greyInk,
                title: (raw as Map)['title'] as String? ?? '',
                subtitle: '${raw['artist'] ?? '未知艺术家'} · ${raw['file'] ?? ''}',
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            if (tracks.length > 100)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '仅显示前 100 首，手表内共 ${tracks.length} 首',
                  style: VText.label.copyWith(color: v.muted),
                ),
              ),
          ],
          if (playlists.isNotEmpty) ...[
            const Divider(height: 1),
            for (final raw in playlists)
              VRowItem(
                icon: Icons.queue_music_rounded,
                iconBackground: v.tintPurple,
                iconColor: v.purpleInk,
                title: (raw as Map)['name'] as String? ?? '',
                subtitle: '${raw['count'] ?? 0} 首',
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
          ],
          const Divider(height: 1),
          VRowItem(
            icon: Icons.playlist_add_rounded,
            iconBackground: v.tintGreen,
            iconColor: v.greenInk,
            title: '上传音乐',
            subtitle: remaining > 0 ? '队列中还有 $remaining 首' : '从本机选择音频，可多选',
            showChevron: true,
            onTap: connected
                ? () async {
                    final paths = await bridge.pickMusicFiles();
                    if (paths.isEmpty) return;
                    await _run(() => bridge.uploadMusic(paths));
                    _toast('已加入 ${paths.length} 首');
                  }
                : null,
          ),
          if (remaining > 0)
            VRowItem(
              icon: Icons.cancel_rounded,
              iconBackground: v.tintPeach,
              iconColor: v.warnInk,
              title: '取消上传',
              subtitle: '清空等待队列，当前这首传完后停止',
              onTap: () => _run(bridge.cancelMusicUpload),
            ),
          if ((status['musicUploadStatus'] as String? ?? '').isNotEmpty)
            _progressBlock(
              v,
              status['musicUploadStatus'] as String,
              (status['musicUploadProgress'] as num?)?.toInt() ?? -1,
            ),
        ],
      ),
    );
  }

  Widget _progressBlock(VColors v, String message, int progress) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: VText.label.copyWith(color: v.muted, height: 1.5),
          ),
          if (progress >= 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress / 100,
                minHeight: 6,
                backgroundColor: v.line,
                color: v.blue,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _installApp(VColors v) async {
    final picked = await bridge.pickWatchApp();
    if (picked == null || !mounted) return;
    final package = TextEditingController(
      text: (picked['package'] as String? ?? '').trim(),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: v.surface,
        title: Text('安装手表应用', style: VText.h2.copyWith(color: v.ink)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              picked['name'] as String? ?? 'APK',
              style: VText.body.copyWith(color: v.ink),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: package,
              decoration: InputDecoration(
                labelText: tr('包名'),
                hintText: 'com.example.app',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, package.text.trim()),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    package.dispose();
    if (result == null || result.isEmpty) {
      if ((picked['package'] as String? ?? '') == '') {
        _toast('无法识别包名，请手动填写');
      }
      return;
    }
    await _run(
      () => bridge.installApp(picked['path'] as String? ?? '', result),
    );
  }

  Future<void> _installWatchface(VColors v) async {
    final picked = await bridge.pickWatchface();
    if (picked == null || !mounted) return;
    final name = TextEditingController(text: picked['name'] as String? ?? '');
    final version = TextEditingController(
      text: picked['version'] as String? ?? '',
    );
    var mode = picked['mode'] as String? ?? 'BIN';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: v.surface,
          title: Text('安装表盘', style: VText.h2.copyWith(color: v.ink)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(labelText: tr('表盘名称')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: version,
                  decoration: InputDecoration(
                    labelText: tr('版本'),
                    hintText: tr('与手表引擎主版本一致'),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: InputDecoration(labelText: tr('载荷模式')),
                  items: const [
                    DropdownMenuItem(
                      value: 'BIN',
                      child: Text('BIN（只传 watchface.bin）'),
                    ),
                    DropdownMenuItem(
                      value: 'PACKAGE',
                      child: Text('PACKAGE（传内层整包）'),
                    ),
                    DropdownMenuItem(value: 'SYNC', child: Text('SYNC（同步容器）')),
                    DropdownMenuItem(value: 'HWT', child: Text('HWT（整个 .hwt）')),
                  ],
                  onChanged: (value) => setDialog(() => mode = value ?? 'BIN'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, {
                'name': name.text.trim(),
                'version': version.text.trim(),
                'mode': mode,
              }),
              child: const Text('上传'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    version.dispose();
    if (result == null) return;
    if ((result['name'] ?? '').isEmpty || (result['version'] ?? '').isEmpty) {
      _toast('名称和版本不能为空');
      return;
    }
    await _run(
      () => bridge.installWatchface(
        picked['path'] as String? ?? '',
        result['name']!,
        result['version']!,
        result['mode']!,
      ),
    );
  }

  Future<bool> _confirm({required String title, required String body}) async {
    final v = context.v;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: v.surface,
        title: Text(title, style: VText.h2.copyWith(color: v.ink)),
        content: Text(body, style: VText.body.copyWith(color: v.ink2)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定', style: TextStyle(color: v.danger)),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
