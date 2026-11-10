import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/permission_bridge.dart';
import '../../data/watch_bridge.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import 'ephemeris_screen.dart';
import 'huawei_account_dialog.dart';
import 'watch_alarms_screen.dart';
import 'watch_auth_key_dialog.dart';
import 'watch_logs_screen.dart';
import 'watch_tools_screen.dart';
import 'workout_live_screen.dart';
import 'training_plan_screen.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  Timer? _timer;
  String _lastLog = '';
  String _ephemerisNote = '';
  bool _charging = false;
  List<Map<String, String>> _bonded = const [];
  bool _scanningBonded = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    await state.refreshFromLegacyIfNewer();
    if (!mounted) return;
    await state.refresh();
    // 这两行点进去是独立详情页，副标题要说「里面有什么」，不能停留在静态承诺
    String lastLog = '';
    String ephemerisNote = '';
    var charging = _charging;
    try {
      charging = (await VitaloopApi.setting('watch_charging', '0')) == '1';
    } catch (_) {}
    try {
      final logs = await VitaloopApi.watchLogs(limit: 1);
      if (logs.isNotEmpty) {
        final at = DateTime.fromMillisecondsSinceEpoch(logs.first.tsMs);
        lastLog = '${monthDayShort(at)} ${clock(at)} · ${logs.first.msg}';
      }
    } catch (_) {}
    try {
      final status = await WatchBridge.instance.ephemerisStatus();
      final exists = status['exists'] == true;
      ephemerisNote = exists
          ? (status['needsRefresh'] == true ? '本机已有星历，等待刷新' : '本机已有星历，可下发给手表')
          : (status['error'] as String? ?? '').isNotEmpty
          ? '未获取到星历文件（${status['error']}）'
          : '本机暂无星历文件';
    } catch (_) {}
    final bonded = await WatchBridge.instance.bondedDevices();
    if (!mounted) return;
    setState(() {
      _lastLog = lastLog;
      _ephemerisNote = ephemerisNote;
      _charging = charging;
      _bonded = bonded;
    });
  }

  Future<void> _scanBonded() async {
    setState(() => _scanningBonded = true);
    final status = await PermissionBridge.instance.status();
    if (!status.bluetooth) {
      await PermissionBridge.instance.request();
    }
    final bonded = await WatchBridge.instance.bondedDevices();
    if (!mounted) return;
    setState(() {
      _bonded = bonded;
      _scanningBonded = false;
    });
    if (bonded.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有找到已配对的华为手表，请先在系统蓝牙或华为运动健康里完成配对')),
      );
    }
  }

  Future<void> _connectBonded(Map<String, String> device) async {
    final address = device['address'] ?? '';
    final name = device['name'] ?? 'HUAWEI WATCH';
    if (address.isEmpty) return;
    final account = await showHuaweiAccountDialog(
      context,
      name: name,
      address: address,
      initialAccount: state.watchIdentity?.account ?? '',
    );
    if (account == null || account.isEmpty || !mounted) return;
    await WatchBridge.instance.connect(address, name, account: account);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('正在连接手表...')));
  }

  static Future<({String mode, Set<String> packages})?> _pickNotificationFilter(
    BuildContext context, {
    required String mode,
    required Set<String> packages,
  }) async {
    final apps = await WatchBridge.instance.notificationApps();
    if (!context.mounted) return null;
    final v = context.v;
    final selected = {...packages};
    final search = TextEditingController();
    final manual = TextEditingController();
    var saved = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: v.bg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final query = search.text.trim().toLowerCase();
          final filtered = query.isEmpty
              ? apps
              : apps
                    .where(
                      (app) =>
                          app.name.toLowerCase().contains(query) ||
                          app.package.toLowerCase().contains(query),
                    )
                    .toList();
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: v.muted.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                      child: Row(
                        children: [
                          Text(
                            '通知转发应用',
                            style: VText.h2.copyWith(color: v.ink),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        children: [
                          for (final item in const [
                            ('all', '全部'),
                            ('whitelist', '白名单'),
                            ('blacklist', '黑名单'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(item.$2),
                                selected: mode == item.$1,
                                onSelected: (_) =>
                                    setSheet(() => mode = item.$1),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          switch (mode) {
                            'whitelist' => '只转发选中的应用；未选中的应用不会打扰手表。',
                            'blacklist' => '选中的应用不转发，其余应用照常转发。',
                            _ => '转发所有应用的通知（领克车况提醒始终不转发）。',
                          },
                          style: VText.label.copyWith(
                            color: v.muted,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                    if (mode != 'all') ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
                        child: TextField(
                          controller: search,
                          onChanged: (_) => setSheet(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: Icon(Icons.search_rounded, size: 19),
                            hintText: tr('搜索应用名称或包名'),
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  '没有匹配的应用',
                                  style: VText.label.copyWith(color: v.muted),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                itemCount: filtered.length,
                                itemBuilder: (_, index) {
                                  final app = filtered[index];
                                  final checked = selected.contains(
                                    app.package,
                                  );
                                  return CheckboxListTile(
                                    dense: true,
                                    value: checked,
                                    onChanged: (value) => setSheet(() {
                                      if (value == true) {
                                        selected.add(app.package);
                                      } else {
                                        selected.remove(app.package);
                                      }
                                    }),
                                    title: Text(
                                      app.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: VText.meta.copyWith(color: v.ink),
                                    ),
                                    subtitle: Text(
                                      app.package,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: VText.label.copyWith(
                                        fontSize: 9,
                                        color: v.muted,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 6, 18, 8),
                        child: TextField(
                          controller: manual,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: tr('手动添加包名，例如 com.example.app'),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: tr('添加'),
                              icon: const Icon(Icons.add_rounded),
                              onPressed: () {
                                final value = manual.text.trim();
                                if (value.isEmpty) return;
                                setSheet(() {
                                  selected.add(value);
                                  manual.clear();
                                });
                              },
                            ),
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () async {
                            saved = true;
                            Navigator.pop(ctx);
                          },
                          child: const Text('保存'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    manual.dispose();
    return saved ? (mode: mode, packages: selected) : null;
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final bridge = WatchBridge.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([
        bridge.state,
        bridge.lastSync,
        bridge.autoSync,
      ]),
      builder: (context, _) {
        final bridgeState = bridge.state.value;
        final liveConnected = bridgeState == 'ready';
        final liveSync = bridge.lastSync.value;
        return _buildBody(context, v, bridgeState, liveConnected, liveSync);
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    dynamic v,
    String bridgeState,
    bool liveConnected,
    DateTime? liveSync,
  ) {
    final device = state.primaryDevice;
    final connected = liveConnected;
    final lastSync = liveSync?.millisecondsSinceEpoch ?? device?.lastSyncMs;
    final identity = state.watchIdentity;
    final batteryKnown = connected && device != null && device.battery > 0;
    final bridge = WatchBridge.instance;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '手表连接'),
            if (device == null || identity == null) ...[
              _ConnectCard(
                identity: identity,
                bonded: _bonded,
                scanning: _scanningBonded,
                onScanBonded: _scanBonded,
                onConnectBonded: _connectBonded,
                onConnect: () async {
                  if (identity != null && identity.address.isNotEmpty) {
                    await WatchBridge.instance.connect(
                      identity.address,
                      identity.name,
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('正在连接手表...')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('未找到已配对的手表地址，请先在旧版完成配对')),
                    );
                  }
                },
              ),
              // 星历和连接日志与「是否已连上」无关：配对还没成功时也要能先把星历备好
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    VRowItem(
                      icon: Icons.satellite_alt_rounded,
                      iconBackground: v.tintSky,
                      iconColor: v.skyInk,
                      title: 'GPS 星历',
                      subtitle: _ephemerisNote.isEmpty
                          ? '辅助定位数据的下载与下发状态'
                          : _ephemerisNote,
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EphemerisScreen(),
                        ),
                      ),
                    ),
                    VRowItem(
                      icon: Icons.receipt_long_rounded,
                      iconBackground: v.grey,
                      iconColor: v.greyInk,
                      title: '连接日志',
                      subtitle: _lastLog.isEmpty
                          ? '暂无记录：连接与同步过程会逐条写在这里'
                          : _lastLog,
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WatchLogsScreen(state: state),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              VCard(
                background: connected ? v.green : v.sky,
                foreground: connected ? v.greenInk : v.skyInk,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(
                            Icons.watch_rounded,
                            size: 24,
                            color: connected ? v.greenInk : v.skyInk,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.name,
                                style: VText.value.copyWith(
                                  fontSize: 17,
                                  color: connected ? v.greenInk : v.skyInk,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                connected
                                    ? '健康数据同步通道已就绪'
                                    : _bridgeLabel(bridgeState),
                                style: VText.label.copyWith(
                                  fontSize: 10.5,
                                  color: (connected ? v.greenInk : v.skyInk)
                                      .withValues(alpha: 0.75),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 握手阶段下面已经写着「正在连接手表...」，角标再说「未连接」就是自己打自己
                        VChip(
                          text: switch (bridgeState) {
                            'connecting' ||
                            'authenticating' ||
                            'configuring' => '连接中',
                            _ => connected ? '已连接' : '未连接',
                          },
                          background: Colors.white.withValues(alpha: 0.45),
                          foreground: connected ? v.greenInk : v.skyInk,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          '电量',
                          style: VText.label.copyWith(
                            fontSize: 10,
                            color: (connected ? v.greenInk : v.skyInk)
                                .withValues(alpha: 0.7),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          batteryKnown
                              ? '${device.battery}%${_charging ? ' · 充电中' : ''}'
                              : '--',
                          style: VText.label.copyWith(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: connected ? v.greenInk : v.skyInk,
                          ),
                        ),
                      ],
                    ),
                    // 未知电量时不画轨道：一条满宽的空白进度条读起来就是 0%，和上面的「--」打架
                    if (batteryKnown) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: (device.battery / 100).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: Colors.white.withValues(alpha: 0.4),
                          valueColor: AlwaysStoppedAnimation(
                            connected ? v.greenInk : v.skyInk,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 2),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    VRowItem(
                      icon: Icons.sync_rounded,
                      iconBackground: v.tintBlue,
                      iconColor: v.blueInk,
                      title: connected ? '立即同步' : '手动连接',
                      subtitle: connected
                          ? (lastSync == null
                                ? '从手表拉取最新健康数据'
                                : '上次同步 ${_ago(DateTime.fromMillisecondsSinceEpoch(lastSync))} · 点击重新拉取')
                          : '重新连接手表并同步',
                      showChevron: true,
                      onTap: () => _syncNow(context),
                    ),
                    VRowItem(
                      icon: Icons.bluetooth_searching_rounded,
                      iconBackground: v.tintSky,
                      iconColor: v.skyInk,
                      title: _scanningBonded ? '正在查找…' : '查找本机已配对手表',
                      subtitle: _bonded.isEmpty
                          ? '从系统蓝牙配对列表中选择手表'
                          : '找到 ${_bonded.length} 台，点击直接连接',
                      value: _scanningBonded ? '查找中' : null,
                      onTap: _scanningBonded ? null : _scanBonded,
                    ),
                    VRowItem(
                      icon: Icons.history_rounded,
                      iconBackground: v.tintPeach,
                      iconColor: v.warnInk,
                      title: '重新拉取最近 7 天',
                      subtitle: '重置同步游标，补回睡眠、压力与 HRV',
                      showChevron: true,
                      onTap: () async {
                        try {
                          await WatchBridge.instance.resyncRecent();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已重置同步游标，连接手表后开始补拉')),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('重置失败：$e')));
                        }
                      },
                    ),
                    for (final peer in _bonded)
                      VRowItem(
                        icon: Icons.watch_rounded,
                        iconBackground: v.tintBlue,
                        iconColor: v.blueInk,
                        title: peer['name'] ?? 'HUAWEI WATCH',
                        subtitle: peer['address'] ?? '',
                        value: '连接',
                        showChevron: true,
                        onTap: () => _connectBonded(peer),
                      ),
                    VRowItem(
                      icon: Icons.bluetooth_disabled_rounded,
                      iconBackground: v.tintGrey,
                      iconColor: v.greyInk,
                      title: '断开连接',
                      subtitle: '结束与手表的蓝牙连接',
                      showChevron: true,
                      onTap: () => WatchBridge.instance.disconnect(),
                    ),
                    VRowItem(
                      icon: Icons.sync_lock_rounded,
                      iconBackground: bridge.autoSync.value
                          ? v.tintGreen
                          : v.tintGrey,
                      iconColor: bridge.autoSync.value ? v.greenInk : v.greyInk,
                      title: '后台自动同步',
                      subtitle: bridge.autoSync.value
                          ? '退出应用后仍保持连接，断线自动重连'
                          : '仅在前台连接，关闭后不会后台重连',
                      trailing: Switch(
                        value: bridge.autoSync.value,
                        onChanged: (on) => WatchBridge.instance.setAutoSync(on),
                      ),
                    ),
                    VRowItem(
                      icon: Icons.flag_rounded,
                      iconBackground: v.tintGreen,
                      iconColor: v.greenInk,
                      title: '运动目标',
                      subtitle: state.goals == null
                          ? '尚未设置，默认按步数 10,000 · 活动热量 500 kcal'
                          : '步数 ${fmtInt(state.goals!.steps)} · 活动热量 ${state.goals!.calories} kcal',
                      showChevron: true,
                      onTap: () => _goalsSheet(context),
                    ),
                    VRowItem(
                      icon: Icons.watch_rounded,
                      iconBackground: v.tintPurple,
                      iconColor: v.purpleInk,
                      title: '手表设置',
                      subtitle: '自动上传、天气同步、腕上解锁',
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              WatchSettingsScreen(state: state, device: device),
                        ),
                      ),
                    ),
                    VRowItem(
                      icon: Icons.construction_rounded,
                      iconBackground: v.tintPeach,
                      iconColor: v.warnInk,
                      title: '手表工具',
                      subtitle: '查找手机、遥控拍照、联系人、应用、表盘与音乐',
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const WatchToolsScreen(),
                        ),
                      ),
                    ),
                    VRowItem(
                      icon: Icons.satellite_alt_rounded,
                      iconBackground: v.tintSky,
                      iconColor: v.skyInk,
                      title: 'GPS 星历',
                      subtitle: _ephemerisNote.isEmpty
                          ? '辅助定位数据的下载与下发状态'
                          : _ephemerisNote,
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EphemerisScreen(),
                        ),
                      ),
                    ),
                    VRowItem(
                      icon: Icons.receipt_long_rounded,
                      iconBackground: v.grey,
                      iconColor: v.greyInk,
                      title: '连接日志',
                      subtitle: _lastLog.isEmpty
                          ? '暂无记录：连接与同步过程会逐条写在这里'
                          : _lastLog,
                      showChevron: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WatchLogsScreen(state: state),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...<Widget>[
                const VSectionHead(title: '华为账号与认证'),
                VCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      VRowItem(
                        icon: Icons.account_circle_rounded,
                        iconBackground: v.tintBlue,
                        iconColor: v.blueInk,
                        title: '华为账号',
                        subtitle: identity.account.isEmpty
                            ? '旧版未保存账号'
                            : _mask(identity.account),
                      ),
                      VRowItem(
                        icon: Icons.bluetooth_connected_rounded,
                        iconBackground: v.tintGreen,
                        iconColor: v.greenInk,
                        title: '设备地址',
                        subtitle: identity.address.isEmpty
                            ? '未找到地址'
                            : identity.address,
                        value: identity.huaweiAddress.isEmpty
                            ? null
                            : 'HiChain',
                      ),
                      VRowItem(
                        icon: Icons.vpn_key_rounded,
                        iconBackground: v.tintPeach,
                        iconColor: v.warnInk,
                        title: '认证 key',
                        subtitle: identity.authKey.isEmpty
                            ? '未找到认证信息：点击可手动录入'
                            : _mask(identity.authKey),
                        value: identity.authKey.isEmpty
                            ? '—'
                            : '${identity.authKey.length} 位',
                        showChevron: true,
                        onTap: () => _editAuthKey(identity),
                      ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.sync_rounded, size: 13, color: v.muted),
                    const SizedBox(width: 5),
                    Text(
                      '每分钟自动刷新本机数据',
                      style: VText.label.copyWith(fontSize: 10, color: v.muted),
                    ),
                  ],
                ),
              ),
              if (state.devices.any((e) => e.id != device.id))
                VCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('其他设备', style: VText.h3.copyWith(color: v.ink)),
                          const Spacer(),
                          Text(
                            '${state.devices.where((e) => e.id != device.id).length} 台',
                            style: VText.label.copyWith(color: v.muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final d in state.devices.where(
                        (e) => e.id != device.id,
                      ))
                        VRowItem(
                          icon: Icons.watch_rounded,
                          iconBackground: v.tintGrey,
                          iconColor: v.ink2,
                          title: d.name,
                          subtitle:
                              '${d.connected ? '已连接' : '未连接'} · ${d.battery > 0 ? '电量 ${d.battery}%' : '电量未知'}',
                          value: d.connected ? '在线' : '离线',
                          color: d.connected ? v.greenInk : null,
                          onTap: () => _info(
                            context,
                            d.name,
                            '${d.connected ? '已连接' : '未连接'} · ${d.battery > 0 ? '电量 ${d.battery}%' : '电量未知'}\n\n其他设备的蓝牙协议接入后会在此管理。',
                          ),
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

  String _ago(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return '$minutes 分钟前';
    final hours = minutes ~/ 60;
    if (hours < 24) return '$hours 小时前';
    return '${hours ~/ 24} 天前';
  }

  String _bridgeLabel(String s) {
    if (s.startsWith('failed:')) {
      return '连接失败：${_friendlyFailure(s.substring(7))}';
    }
    if (s.startsWith('disconnected:')) {
      return '已断开（${_friendlyFailure(s.substring(13))}）';
    }
    return switch (s) {
      'connecting' => '正在连接手表...',
      'authenticating' => '正在认证...',
      'configuring' => '正在同步配置...',
      'ready' => '已连接',
      _ => '未连接 · 离线数据',
    };
  }

  // 原生层给出的中文原因原样展示；Java 异常串翻译成人话，完整原文留在「连接日志」里
  String _friendlyFailure(String reason) {
    if (!reason.contains(RegExp(r'[A-Za-z]'))) return reason;
    if (reason.contains('read ret: -1') ||
        reason.contains('socket might closed')) {
      return '手表未响应，请确认手表在蓝牙范围内、屏幕已解锁且未被其他手机连接';
    }
    if (reason.contains('SecurityException')) return '缺少蓝牙权限，请在系统设置中授予后重试';
    if (reason.contains('already connected') ||
        reason.contains('Resource busy')) {
      return '蓝牙通道被占用，请先关闭其他占用蓝牙的应用';
    }
    if (reason.contains('timeout') || reason.contains('TIMED_OUT')) {
      return '连接超时，请靠近手表后重试';
    }
    return reason;
  }

  Future<void> _syncNow(BuildContext context) async {
    final bridge = WatchBridge.instance;
    if (bridge.state.value == 'ready') {
      await bridge.syncNow();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发起手动同步')));
    } else {
      final identity = state.watchIdentity;
      if (identity == null || identity.address.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未找到已配对的手表地址')));
        return;
      }
      await bridge.connect(identity.address, identity.name);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在连接手表...')));
    }
  }

  String _mask(String key) {
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  Future<void> _editAuthKey(WatchIdentity identity) async {
    final saved = await showWatchAuthKeyDialog(
      context,
      initialKey: identity.authKey,
    );
    if (saved == null || !mounted) return;
    await WatchBridge.instance.saveAuthKey(saved);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('认证 key 已保存，重新连接手表后生效')));
  }

  void _goalsSheet(BuildContext context) {
    final goals = state.goals;
    _info(
      context,
      '运动目标',
      goals == null
          ? '步数、活动热量、运动时长目标会保存在本机，并在同步时下发给手表。'
          : '每日步数 ${fmtInt(goals.steps)} 步\n活动热量 ${goals.calories} kcal\n活动时长 ${goals.activeMinutes} 分钟\n运动时长 ${goals.exerciseMinutes} 分钟\n\n可在「设置 → 运动目标」中修改。',
    );
  }

  void _info(BuildContext context, String title, String body) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: VText.h2.copyWith(color: ctx.v.ink)),
            const SizedBox(height: 10),
            Text(
              body,
              style: VText.body.copyWith(color: ctx.v.ink2, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({
    required this.onConnect,
    required this.identity,
    required this.bonded,
    required this.scanning,
    required this.onScanBonded,
    required this.onConnectBonded,
  });

  final VoidCallback onConnect;
  final WatchIdentity? identity;
  final List<Map<String, String>> bonded;
  final bool scanning;
  final VoidCallback onScanBonded;
  final ValueChanged<Map<String, String>> onConnectBonded;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    // 没有扫描能力，只展示真实已知的地址（旧版配对或导入带入），不伪造「附近设备」结果
    final known = identity != null && identity!.address.isNotEmpty;
    return Column(
      children: [
        VCard(
          background: v.sky,
          foreground: v.skyInk,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '连接你的手表',
                style: VText.value.copyWith(fontSize: 20, color: v.skyInk),
              ),
              const SizedBox(height: 6),
              Text(
                '先在系统蓝牙或「华为运动健康」完成配对，再回到这里选择手表。',
                style: VText.label.copyWith(
                  color: v.skyInk.withValues(alpha: 0.8),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              VPrimaryButton(
                label: known ? '连接手表' : '查找已配对手表',
                icon: known
                    ? Icons.watch_rounded
                    : Icons.bluetooth_searching_rounded,
                onTap: known ? onConnect : onScanBonded,
              ),
            ],
          ),
        ),
        const VSectionHead(title: '已保存的手表'),
        VCard(
          child: VRowItem(
            icon: Icons.watch_rounded,
            iconBackground: known ? const Color(0xFFDCF3D4) : v.tintGrey,
            iconColor: known ? const Color(0xFF2E5C2A) : v.ink2,
            title: known ? identity!.name : '未找到已配对的手表',
            subtitle: known ? identity!.address : '点击下方「查找已配对手表」，从系统蓝牙配对列表中选择',
            value: known ? '连接' : '—',
            onTap: known ? onConnect : null,
          ),
        ),
        const VSectionHead(title: '本机已配对手表'),
        if (bonded.isEmpty)
          VCard(
            child: Column(
              children: [
                Text(
                  '先在系统蓝牙或「华为运动健康」中完成配对，再从本机列表里选择。',
                  style: VText.label.copyWith(color: v.muted, height: 1.55),
                ),
                const SizedBox(height: 10),
                VGhostButton(
                  label: scanning ? '正在查找…' : '查找已配对手表',
                  icon: Icons.bluetooth_searching_rounded,
                  onTap: scanning ? null : onScanBonded,
                ),
              ],
            ),
          )
        else
          VCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final device in bonded)
                  VRowItem(
                    icon: Icons.watch_rounded,
                    iconBackground: v.tintBlue,
                    iconColor: v.blueInk,
                    title: device['name'] ?? 'HUAWEI WATCH',
                    subtitle: device['address'] ?? '',
                    value: '连接',
                    showChevron: true,
                    onTap: () => onConnectBonded(device),
                  ),
                VRowItem(
                  icon: Icons.refresh_rounded,
                  iconBackground: v.tintGrey,
                  iconColor: v.greyInk,
                  title: '重新查找',
                  subtitle: '重新读取系统蓝牙中已配对的华为设备',
                  value: scanning ? '查找中' : null,
                  onTap: scanning ? null : onScanBonded,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class WatchSettingsScreen extends StatefulWidget {
  const WatchSettingsScreen({
    super.key,
    required this.state,
    required this.device,
  });

  final AppState state;
  final DeviceInfo device;

  @override
  State<WatchSettingsScreen> createState() => _WatchSettingsScreenState();
}

class _WatchSettingsScreenState extends State<WatchSettingsScreen> {
  static const _keys = [
    ('push_workout', '运动数据推送手机', '手表开始运动时自动打开实时码表'),
    ('weather_sync', '天气同步', '把手机天气同步到手表'),
    ('wrist_unlock', '在腕免密解锁', '手表在腕上时跳过锁屏'),
  ];
  static const _watchSettingKeys = [
    ('sleep', '睡眠监测', '开启后记录睡眠分期数据', Icons.bedtime_rounded),
    ('heart_rate', '心率实时检测', '开启后手表自动检测心率', Icons.favorite_rounded),
    ('sedentary', '久坐提醒', '久坐不动时提醒活动', Icons.directions_walk_rounded),
    ('spo2', '自动血氧测量', '开启后手表自动测量血氧', Icons.bloodtype_rounded),
    ('lift_wrist', '抬腕亮屏', '抬腕时点亮屏幕', Icons.screen_rotation_alt_rounded),
    ('rotate_wrist', '翻腕切屏', '翻腕切换屏幕信息', Icons.flip_rounded),
    ('temperature', '皮肤温度测量', '开启后手表自动测量皮肤温度', Icons.thermostat_rounded),
    ('disconnect_notify', '断开提醒', '手表与手机断开连接时提醒', Icons.link_off_rounded),
    ('work_mode', '自动工作模式', '按场景自动切换手表工作模式', Icons.autorenew_rounded),
    ('music', '音乐控制', '手表显示并控制手机正在播放的音乐', Icons.music_note_rounded),
  ];
  final Map<String, bool> _values = {
    'push_workout': true,
    'weather_sync': true,
    'wrist_unlock': false,
  };
  Map<String, dynamic> _dndPlan = const {
    'mode': 'off',
    'start': '23:00',
    'end': '07:00',
    'repeatMask': 0x7f,
    'liftWrist': false,
  };
  bool _notificationAccess = false;
  bool _notificationForward = true;
  String _notificationMode = 'all';
  Set<String> _notificationPackages = const {};
  int _alarmCount = 0;
  bool _calendarEnabled = false;
  bool _calendarPermission = false;
  bool _watchReady = false;
  String _wearLabel = '未查询';
  int _wearHeartbeatMs = -1;
  bool _wearGrantMissing = false;
  Timer? _wearTimer;
  TrainingPlan? _trainingPlan;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNotifications();
    _loadAlarms();
    _loadCalendar();
    _loadTrainingPlan();
    _loadWear();
    _wearTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadWear());
  }

  @override
  void dispose() {
    _wearTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadWear() async {
    final status = await WatchBridge.instance.watchToolsStatus();
    if (!mounted || status.isEmpty) return;
    setState(() {
      _wearLabel = status['wearLabel'] as String? ?? '未查询';
      _wearHeartbeatMs = (status['wearHeartbeatAgeMs'] as num?)?.toInt() ?? -1;
      _wearGrantMissing = status['wearGrantMissing'] == true;
      _values['wrist_unlock'] = status['wristUnlock'] == true;
    });
  }

  Future<void> _load() async {
    for (final key in ['push_workout', 'weather_sync']) {
      final value = await VitaloopApi.setting(key, _values[key]! ? '1' : '0');
      if (mounted) {
        setState(() => _values[key] = value == '1');
      }
    }
    // 在腕解锁的开关实际落在 Settings.Secure，由 _loadWear 读原生真值。
    final watchSettings = await WatchBridge.instance.watchSettings();
    if (mounted && watchSettings.isNotEmpty) {
      setState(() {
        for (final entry in watchSettings.entries) {
          _values[entry.key] = entry.value;
        }
      });
    }
    await _loadDndPlan();
    // Rust 里的设置负责界面展示，原生侧负责实际下发，进入页面时对齐一次。
    await WatchBridge.instance.setWeatherSync(_values['weather_sync']!);
    final workoutLive = await WatchBridge.instance.workoutRealtimeEnabled();
    if (mounted) {
      setState(() => _values['push_workout'] = workoutLive);
    }
    await WatchBridge.instance.refreshWorkoutRealtimeStatus();
  }

  Future<void> _loadDndPlan() async {
    final plan = await WatchBridge.instance.dndPlan();
    if (!mounted || plan.isEmpty) return;
    setState(() => _dndPlan = plan);
  }

  Future<void> _setWatchSetting(String key, bool value) async {
    setState(() => _values[key] = value);
    final ok = await WatchBridge.instance.setWatchSetting(key, value);
    if (!ok && mounted) {
      setState(() => _values[key] = !value);
      _toast(context, '设置保存失败，请确认手表已连接');
    }
  }

  Future<void> _loadNotifications() async {
    final access = await WatchBridge.instance.notificationAccess();
    final forward = await WatchBridge.instance.notificationForwardEnabled();
    final filter = await WatchBridge.instance.notificationFilter();
    if (!mounted) return;
    setState(() {
      _notificationAccess = access;
      _notificationForward = forward;
      _notificationMode = filter.mode;
      _notificationPackages = filter.packages;
    });
  }

  String get _notificationFilterLabel => switch (_notificationMode) {
    'whitelist' => '仅白名单 ${_notificationPackages.length} 个应用',
    'blacklist' => '黑名单 ${_notificationPackages.length} 个应用',
    _ => '全部应用',
  };

  Future<void> _openNotificationFilter() async {
    final result = await _WatchScreenState._pickNotificationFilter(
      context,
      mode: _notificationMode,
      packages: _notificationPackages,
    );
    if (result == null || !mounted) return;
    await WatchBridge.instance.setNotificationFilter(
      result.mode,
      result.packages,
    );
    if (!mounted) return;
    setState(() {
      _notificationMode = result.mode;
      _notificationPackages = result.packages;
    });
  }

  Future<void> _loadAlarms() async {
    final alarms = await WatchBridge.instance.alarms();
    if (mounted) setState(() => _alarmCount = alarms.length);
  }

  Future<void> _loadCalendar() async {
    final status = await WatchBridge.instance.calendarStatus();
    if (!mounted) return;
    setState(() {
      _calendarEnabled = status['enabled'] == true;
      _calendarPermission = status['permission'] == true;
      _watchReady = status['ready'] == true;
    });
  }

  Future<void> _loadTrainingPlan() async {
    try {
      final raw = await VitaloopApi.setting('training_plan_v1');
      final plan = TrainingPlan.tryParse(raw);
      if (mounted) setState(() => _trainingPlan = plan);
    } catch (_) {
      if (mounted) setState(() => _trainingPlan = null);
    }
  }

  Future<void> _toggleCalendar(bool enabled) async {
    final ok = await WatchBridge.instance.setCalendarSyncEnabled(enabled);
    await _loadCalendar();
    if (!mounted) return;
    if (enabled && !ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('需要允许“元环”读取系统日历，才能同步到手表')));
    }
  }

  Future<void> _openAlarms() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const WatchAlarmsScreen()));
    final alarms = await WatchBridge.instance.alarms();
    if (mounted) setState(() => _alarmCount = alarms.length);
  }

  Future<void> _openTrainingPlan() async {
    final plan = _trainingPlan;
    if (plan == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrainingPlanScreen(state: widget.state),
        ),
      );
      await _loadTrainingPlan();
      return;
    }
    final week = plan.currentWeek;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                plan.name,
                style: VText.h3.copyWith(color: ctx.v.ink),
              ),
              subtitle: Text(
                '${plan.weeks.length} 周 · 比赛 ${monthDayShort(plan.raceDate)}'
                '${week == null ? '' : ' · 当前第 ${week.weekNum} 周'}',
                style: VText.meta.copyWith(color: ctx.v.muted),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.sync_rounded, color: ctx.v.blueInk),
              title: const Text('立即同步到手表'),
              subtitle: Text(
                _watchReady ? '下发当前周课表' : '手表未连接时会保存，连接后自动下发',
                style: VText.meta.copyWith(color: ctx.v.muted),
              ),
              onTap: () => Navigator.pop(ctx, 'sync'),
            ),
            ListTile(
              leading: Icon(Icons.tune_rounded, color: ctx.v.ink2),
              title: const Text('管理 / 重新生成计划'),
              onTap: () => Navigator.pop(ctx, 'manage'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: ctx.v.danger),
              title: Text('完结手表上的计划', style: TextStyle(color: ctx.v.danger)),
              onTap: () => Navigator.pop(ctx, 'finish'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'sync') {
      await _syncTrainingPlan(plan);
    } else if (action == 'manage') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrainingPlanScreen(state: widget.state),
        ),
      );
      await _loadTrainingPlan();
    } else if (action == 'finish') {
      await _finishTrainingPlan(plan);
    }
  }

  Future<void> _syncTrainingPlan(TrainingPlan plan) async {
    final result = await WatchBridge.instance.pushTrainingPlan(
      jsonEncode(watchPlanPayload(plan)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result['message'] as String? ?? '训练计划已保存')),
    );
  }

  Future<void> _finishTrainingPlan(TrainingPlan plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('完结手表计划', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '会删除手表上的「${plan.name}」课表，本机计划与运动记录不受影响。',
          style: VText.body.copyWith(color: ctx.v.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('完结'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final result = await WatchBridge.instance.finishTrainingPlan(plan.planId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result['message'] as String? ?? '已发送完结指令')),
    );
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
            const VDetailHeader(title: '手表设置'),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (final entry in _keys)
                    VRowItem(
                      icon: _iconFor(entry.$1),
                      iconBackground: v.tintBlue,
                      iconColor: v.blueInk,
                      title: entry.$2,
                      subtitle: entry.$3,
                      trailing: Switch.adaptive(
                        value: _values[entry.$1]!,
                        activeThumbColor: v.blue,
                        onChanged: (value) async {
                          setState(() => _values[entry.$1] = value);
                          await VitaloopApi.setSetting(
                            entry.$1,
                            value ? '1' : '0',
                          );
                          if (entry.$1 == 'wrist_unlock') {
                            final ok = await WatchBridge.instance
                                .setWristUnlock(value);
                            if (value && !ok) {
                              await VitaloopApi.setSetting('wrist_unlock', '0');
                              if (mounted) {
                                setState(() => _values['wrist_unlock'] = false);
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      '写入系统设置被拒，请先执行：adb shell pm grant me.awen.vitaloop android.permission.WRITE_SECURE_SETTINGS',
                                    ),
                                  ),
                                );
                              }
                            } else {
                              await WatchBridge.instance.queryWearStatus();
                              await _loadWear();
                            }
                          }
                          if (entry.$1 == 'weather_sync') {
                            await WatchBridge.instance.setWeatherSync(value);
                          }
                          if (entry.$1 == 'push_workout') {
                            await WatchBridge.instance
                                .setWorkoutRealtimeEnabled(value);
                          }
                        },
                      ),
                    ),
                  VRowItem(
                    icon: Icons.watch_rounded,
                    iconBackground: v.tintGreen,
                    iconColor: v.greenInk,
                    title: '佩戴状态',
                    subtitle: _wearGrantMissing
                        ? '系统设置写入被拒，需要在腕解锁先授权一次 adb'
                        : (_values['wrist_unlock'] == true
                              ? (_wearHeartbeatMs < 0
                                    ? '解锁侧还没读到心跳'
                                    : '解锁侧心跳 ${(_wearHeartbeatMs / 1000).round()} 秒前')
                              : '手表 0x01/0x3d 上报，断连按离腕处理'),
                    value: _wearLabel,
                    showChevron: true,
                    onTap: () async {
                      await WatchBridge.instance.queryWearStatus();
                      await Future<void>.delayed(
                        const Duration(milliseconds: 600),
                      );
                      await _loadWear();
                    },
                  ),
                  VRowItem(
                    icon: Icons.speed_rounded,
                    iconBackground: v.tintBlue,
                    iconColor: v.blueInk,
                    title: '实时码表',
                    subtitle: '手表运动时把距离、心率、轨迹投到手机',
                    showChevron: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WorkoutLiveScreen(state: widget.state),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VSectionHead(title: '手表功能'),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (final entry in _watchSettingKeys)
                    VRowItem(
                      icon: entry.$4,
                      iconBackground: v.tintBlue,
                      iconColor: v.blueInk,
                      title: entry.$2,
                      subtitle: entry.$3,
                      trailing: Switch.adaptive(
                        value: _values[entry.$1] ?? true,
                        activeThumbColor: v.blue,
                        onChanged: (value) => _setWatchSetting(entry.$1, value),
                      ),
                    ),
                ],
              ),
            ),
            const VSectionHead(title: '通知'),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  VRowItem(
                    icon: Icons.notifications_active_rounded,
                    iconBackground: v.tintBlue,
                    iconColor: v.blueInk,
                    title: '转发手机通知',
                    subtitle: _notificationAccess
                        ? '微信、短信、邮件等通知显示在手表上'
                        : '先授予系统“通知使用权”才能转发',
                    trailing: Switch.adaptive(
                      value: _notificationForward && _notificationAccess,
                      activeThumbColor: v.blue,
                      onChanged: (value) async {
                        if (value && !_notificationAccess) {
                          await WatchBridge.instance.openNotificationAccess();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('请在系统设置中允许“元环”读取通知，然后返回本页'),
                            ),
                          );
                          return;
                        }
                        await WatchBridge.instance.setNotificationForward(
                          value,
                        );
                        if (value) {
                          final permissions = await PermissionBridge.instance
                              .request();
                          if (!context.mounted) return;
                          if (!permissions.phone || !permissions.answerCalls) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('来电转发和手表接听需要「电话」权限，请在权限管理里允许'),
                              ),
                            );
                          }
                        }
                        if (mounted) {
                          setState(() => _notificationForward = value);
                        }
                      },
                    ),
                  ),
                  VRowItem(
                    icon: Icons.settings_applications_rounded,
                    iconBackground: _notificationAccess
                        ? v.tintGreen
                        : v.tintPeach,
                    iconColor: _notificationAccess ? v.greenInk : v.warnInk,
                    title: '系统通知使用权',
                    subtitle: _notificationAccess ? '已授权' : '未授权，点击去系统设置',
                    showChevron: true,
                    onTap: () async {
                      await WatchBridge.instance.openNotificationAccess();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('授权后回到本页，下拉刷新状态')),
                      );
                    },
                  ),
                  if (_notificationAccess && _notificationForward)
                    VRowItem(
                      icon: Icons.filter_alt_rounded,
                      iconBackground: v.tintBlue,
                      iconColor: v.blueInk,
                      title: '应用过滤',
                      subtitle: _notificationFilterLabel,
                      value: switch (_notificationMode) {
                        'whitelist' => '白名单',
                        'blacklist' => '黑名单',
                        _ => '全部',
                      },
                      showChevron: true,
                      onTap: _openNotificationFilter,
                    ),
                ],
              ),
            ),
            const VSectionHead(title: '闹钟与勿扰'),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  VRowItem(
                    icon: Icons.alarm_rounded,
                    iconBackground: v.tintPeach,
                    iconColor: v.warnInk,
                    title: '闹钟',
                    subtitle: _alarmCount == 0
                        ? '尚未设置，点此添加并同步到手表'
                        : '$_alarmCount 个闹钟，点此管理',
                    value: _alarmCount == 0 ? '—' : '$_alarmCount',
                    showChevron: true,
                    onTap: _openAlarms,
                  ),
                  VRowItem(
                    icon: Icons.do_not_disturb_on_rounded,
                    iconBackground: v.tintPurple,
                    iconColor: v.purpleInk,
                    title: '勿扰模式',
                    subtitle: _dndSummary,
                    value: switch (_dndPlan['mode']) {
                      'always' => '常开',
                      'automatic' => '定时',
                      _ => '关闭',
                    },
                    showChevron: true,
                    onTap: _openDndPlan,
                  ),
                ],
              ),
            ),
            const VSectionHead(title: '更多'),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  VRowItem(
                    icon: Icons.calendar_month_rounded,
                    iconBackground: v.tintGreen,
                    iconColor: v.greenInk,
                    title: '日历同步',
                    subtitle: !_calendarPermission
                        ? '首次开启需要允许读取系统日历'
                        : !_calendarEnabled
                        ? '把手机未来 7 天日程同步到手表'
                        : !_watchReady
                        ? '已开启，手表连接后自动同步'
                        : '已开启，日程变化会自动同步',
                    trailing: Switch.adaptive(
                      value: _calendarEnabled,
                      activeThumbColor: v.blue,
                      onChanged: _toggleCalendar,
                    ),
                  ),
                  VRowItem(
                    icon: Icons.assignment_rounded,
                    iconBackground: v.tintSky,
                    iconColor: v.skyInk,
                    title: '训练计划',
                    subtitle: _trainingPlan == null
                        ? '尚未创建，点此生成备赛课表'
                        : '${_trainingPlan!.name} · 共 ${_trainingPlan!.weeks.length} 周',
                    showChevron: true,
                    onTap: _openTrainingPlan,
                  ),
                  VRowItem(
                    icon: Icons.restart_alt_rounded,
                    iconBackground: v.tintHeart,
                    iconColor: v.heartInk,
                    title: '恢复出厂',
                    subtitle: '清除手表端设置',
                    showChevron: true,
                    color: v.heartInk,
                    onTap: () => _confirmFactoryReset(context),
                  ),
                ],
              ),
            ),
            VPrimaryButton(
              label: '同步所有设置',
              icon: Icons.sync_rounded,
              onTap: () async {
                final message = await WatchBridge.instance.syncAllSettings();
                if (context.mounted) _toast(context, message);
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String key) => switch (key) {
    'push_workout' => Icons.notifications_active_rounded,
    'weather_sync' => Icons.wb_cloudy_rounded,
    _ => Icons.lock_open_rounded,
  };

  String get _dndSummary {
    final mode = _dndPlan['mode'] as String? ?? 'off';
    if (mode == 'off') return '关闭，点此设置定时或常开';
    if (mode == 'always') return '全天不打扰通知';
    final start = _dndPlan['start'] as String? ?? '23:00';
    final end = _dndPlan['end'] as String? ?? '07:00';
    final mask = (_dndPlan['repeatMask'] as num?)?.toInt() ?? 0x7f;
    final lift = _dndPlan['liftWrist'] == true;
    return '$start-$end · ${_repeatLabel(mask)}${lift ? ' · 抬腕例外' : ''}';
  }

  String _repeatLabel(int mask) {
    if (mask == 0x7f) return '每天';
    if (mask == 0x1f) return '工作日';
    if (mask == 0x60) return '周末';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final days = [
      for (var i = 0; i < 7; i++)
        if (mask & (1 << i) != 0) '周${names[i]}',
    ];
    return days.isEmpty ? '不重复' : days.join('、');
  }

  Future<void> _openDndPlan() async {
    var mode = _dndPlan['mode'] as String? ?? 'off';
    var mask = (_dndPlan['repeatMask'] as num?)?.toInt() ?? 0x7f;
    var lift = _dndPlan['liftWrist'] == true;
    var start = _parseTime(_dndPlan['start'] as String? ?? '23:00');
    var end = _parseTime(_dndPlan['end'] as String? ?? '07:00');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          Future<void> pick(bool isStart) async {
            final picked = await showTimePicker(
              context: ctx,
              initialTime: isStart ? start : end,
              helpText: isStart ? '勿扰开始' : '勿扰结束',
            );
            if (picked == null) return;
            setDlg(() {
              if (isStart) {
                start = picked;
              } else {
                end = picked;
              }
            });
          }

          return AlertDialog(
            title: const Text('勿扰计划'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'off', label: Text('关闭')),
                      ButtonSegment(value: 'automatic', label: Text('定时')),
                      ButtonSegment(value: 'always', label: Text('常开')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (value) =>
                        setDlg(() => mode = value.first),
                  ),
                  if (mode != 'off') ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pick(true),
                            child: Text('开始 ${_fmtTime(start)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => pick(false),
                            child: Text('结束 ${_fmtTime(end)}'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < 7; i++)
                          FilterChip(
                            label: Text(
                              const ['一', '二', '三', '四', '五', '六', '日'][i],
                            ),
                            selected: mask & (1 << i) != 0,
                            onSelected: (on) => setDlg(() {
                              if (on) {
                                mask |= 1 << i;
                              } else {
                                mask &= ~(1 << i);
                              }
                            }),
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('抬腕时暂时亮屏'),
                      value: lift,
                      onChanged: (value) => setDlg(() => lift = value),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    final ok = await WatchBridge.instance.setDndPlan(
      mode: mode,
      start: _fmtTime(start),
      end: _fmtTime(end),
      repeatMask: mask,
      liftWrist: lift,
    );
    await _loadDndPlan();
    if (!mounted) return;
    _toast(context, ok ? '勿扰计划已保存' : '保存失败，请确认手表已连接');
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
  }

  String _fmtTime(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _confirmFactoryReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复出厂设置？'),
        content: const Text(
          '这会清除手表端的设置、闹钟、联系人、音乐等数据。'
          '请求发出后，手表还会再要求你确认一次。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final sent = await WatchBridge.instance.factoryReset();
    if (!context.mounted) return;
    _toast(context, sent ? '已发送恢复出厂请求，请在手表端确认' : '发送失败，请确认手表已连接');
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
