import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/ble_bridge.dart';
import '../../data/watch_bridge.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';
import 'huawei_account_dialog.dart';
import 'watch_screen.dart';

class BluetoothDevicesScreen extends StatefulWidget {
  const BluetoothDevicesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<BluetoothDevicesScreen> createState() => _BluetoothDevicesScreenState();
}

class _BluetoothDevicesScreenState extends State<BluetoothDevicesScreen> {
  final _ble = BleBridge.instance;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _ble.attach(widget.state);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
  }

  @override
  void dispose() {
    _ble.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    final granted = await _ble.requestPermissions();
    if (!mounted) return;
    setState(() => _permissionDenied = !granted);
    if (granted) await _ble.startScan();
  }

  Future<void> _connect(Map<String, dynamic> device) async {
    final name = (device['name'] as String? ?? '').trim();
    final address = device['address'] as String? ?? '';
    if (name.toUpperCase().startsWith('HUAWEI')) {
      await _ble.stopScan();
      if (!mounted) return;
      await _connectHuawei(address, name);
      return;
    }
    final ok = await _ble.connect(address, name.isEmpty ? '心率带' : name);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('连接失败：请确认蓝牙已打开并已授权')));
    }
  }

  Future<void> _connectHuawei(String address, String name) async {
    final account = await showHuaweiAccountDialog(
      context,
      initialAccount: widget.state.watchIdentity?.account ?? '',
      name: name,
      address: address,
    );
    if (account == null || account.isEmpty || !mounted) return;
    await WatchBridge.instance.connect(address, name, account: account);
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => WatchScreen(state: widget.state)));
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: Listenable.merge([_ble.devices, _ble.scanning]),
          builder: (context, _) {
            final devices = _ble.devices.value;
            final list = devices.values.toList()
              ..sort((a, b) {
                final sa = a['state'] == 'connected' ? 0 : 1;
                final sb = b['state'] == 'connected' ? 0 : 1;
                if (sa != sb) return sa - sb;
                return (b['rssi'] as int? ?? -999).compareTo(
                  a['rssi'] as int? ?? -999,
                );
              });
            final connected = list
                .where((d) => d['state'] == 'connected')
                .toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                VDetailHeader(
                  title: '蓝牙设备',
                  trailing: VIconButton(
                    icon: Icons.refresh_rounded,
                    onTap: () =>
                        _ble.scanning.value ? _ble.stopScan() : _startScan(),
                  ),
                ),
                if (connected.isNotEmpty) ...[
                  for (final device in connected)
                    _ConnectedCard(device: device),
                  const VSectionHead(title: '附近设备'),
                ],
                if (_permissionDenied)
                  VCard(
                    background: v.tintPeach,
                    foreground: v.warnInk,
                    child: Text(
                      '需要附近的设备权限才能扫描心率带。请在系统设置里允许「附近的设备」后重试。',
                      style: VText.label.copyWith(
                        color: v.warnInk,
                        height: 1.55,
                      ),
                    ),
                  )
                else if (list.isEmpty)
                  VCard(
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        Icon(
                          Icons.bluetooth_searching_rounded,
                          size: 38,
                          color: v.muted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _ble.scanning.value ? '正在扫描附近的蓝牙设备…' : '还没有发现设备',
                          style: VText.h3.copyWith(color: v.ink),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '打开心率带并靠近手机，保持蓝牙开启',
                          style: VText.label.copyWith(color: v.muted),
                        ),
                        const SizedBox(height: 12),
                        VGhostButton(
                          label: _ble.scanning.value ? '停止扫描' : '开始扫描',
                          icon: Icons.search_rounded,
                          onTap: () => _ble.scanning.value
                              ? _ble.stopScan()
                              : _startScan(),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  )
                else
                  VCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        for (final device in list)
                          _DeviceRow(
                            device: device,
                            onTap: () => _connect(device),
                          ),
                      ],
                    ),
                  ),
                if (list.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  VGhostButton(
                    label: _ble.scanning.value ? '停止扫描' : '重新扫描',
                    icon: _ble.scanning.value
                        ? Icons.stop_rounded
                        : Icons.search_rounded,
                    onTap: () =>
                        _ble.scanning.value ? _ble.stopScan() : _startScan(),
                  ),
                ],
                const VSectionHead(title: '已配对过'),
                ValueListenableBuilder<Map<String, String>>(
                  valueListenable: _ble.history,
                  builder: (context, history, _) {
                    if (history.isEmpty) {
                      return VCard(
                        background: v.tintGrey,
                        child: Text(
                          '连接成功的健康设备会保存在这里，下次进页面会自动重连。',
                          style: VText.label.copyWith(
                            color: v.muted,
                            height: 1.55,
                          ),
                        ),
                      );
                    }
                    return VCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (final entry in history.entries)
                            _HistoryRow(
                              entry: entry,
                              device: devices[entry.key],
                              v: v,
                              onTap: () => _connect({
                                'address': entry.key,
                                'name': entry.value,
                              }),
                              onForget: () => _ble.forget(entry.key),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const VSectionHead(title: '协议说明'),
                VCard(
                  background: v.tintGrey,
                  child: Text(
                    '这里直连标准 BLE 健康设备：心率带 0x180D、体重秤 0x181D、血压计 0x1810、'
                    '血糖仪 0x1808，以及蚂蚁阿福 × 沃莱体脂秤（AFU-WL，0xFFB1/0xFFB2）。'
                    '测量结果会直接写入本机对应记录。华为手表走自己的 RFCOMM 协议，'
                    '请回到「手表连接」管理；小米手环需要认证密钥，暂不在这一页抢链路。',
                    style: VText.label.copyWith(color: v.ink2, height: 1.55),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.device});

  final Map<String, dynamic> device;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final kind = device['kind'] as String? ?? 'hr';
    final (icon, background, foreground) = _kindStyle(kind, v);
    final bpm = device['heartRate'] as int? ?? 0;
    final battery = device['battery'] as int? ?? -1;
    final charging = device['charging'] == true;
    final display = device['display'] as String? ?? '';
    final batteryText = [
      if (battery >= 0) '电量 $battery%',
      if (charging) '充电中',
    ].join(' · ');
    final scaleText = [
      if (display.isNotEmpty) display,
      if (batteryText.isNotEmpty) batteryText,
    ].join(' · ');
    final subtitle = kind == 'hr'
        ? (bpm > 0
              ? '$bpm bpm${batteryText.isEmpty ? '' : ' · $batteryText'}'
              : '已连接，等待心率数据…')
        : (scaleText.isNotEmpty ? scaleText : '已连接，等待测量数据…');
    return VCard(
      background: background,
      foreground: foreground,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: foreground),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device['name'] as String? ?? '设备',
                  style: VText.value.copyWith(fontSize: 17, color: foreground),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: VText.label.copyWith(
                    fontSize: 10.5,
                    color: foreground.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => BleBridge.instance.disconnect(
              device['address'] as String? ?? '',
            ),
            child: Text('断开', style: VText.label.copyWith(color: foreground)),
          ),
        ],
      ),
    );
  }

  (IconData, Color, Color) _kindStyle(String kind, VColors v) => switch (kind) {
    'weight' => (Icons.monitor_weight_outlined, v.tintSky, v.skyInk),
    'scale' => (Icons.scale_outlined, v.tintSky, v.skyInk),
    'bp' => (Icons.monitor_heart_outlined, v.tintPeach, v.warnInk),
    'glucose' => (Icons.water_drop_outlined, v.lime, v.limeInk),
    'hr' => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
    _ => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
  };
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onTap});

  final Map<String, dynamic> device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final name = (device['name'] as String? ?? '').trim();
    final state = device['state'] as String? ?? 'disconnected';
    final isHuawei = name.toUpperCase().startsWith('HUAWEI');
    final kind = device['kind'] as String? ?? '';
    final (icon, background, foreground) = switch (kind) {
      'weight' => (Icons.monitor_weight_outlined, v.tintSky, v.skyInk),
      'scale' => (Icons.scale_outlined, v.tintSky, v.skyInk),
      'bp' => (Icons.monitor_heart_outlined, v.tintPeach, v.warnInk),
      'glucose' => (Icons.water_drop_outlined, v.lime, v.limeInk),
      'hr' => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
      _ => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
    };
    return VRowItem(
      icon: isHuawei ? Icons.watch_rounded : icon,
      iconBackground: isHuawei ? v.tintBlue : background,
      iconColor: isHuawei ? v.blueInk : foreground,
      title: name.isEmpty ? '未命名设备' : name,
      subtitle: '${device['address']} · ${device['rssi'] ?? 0} dBm',
      value: isHuawei
          ? '手表页'
          : (state == 'connecting' ? '连接中…' : _kindLabel(kind)),
      showChevron: true,
      onTap: onTap,
    );
  }

  String? _kindLabel(String kind) => switch (kind) {
    'weight' => '体重秤',
    'scale' => '体脂秤',
    'bp' => '血压计',
    'glucose' => '血糖仪',
    'hr' => '心率带',
    _ => null,
  };
}

(IconData, Color, Color) _historyStyle(String kind, VColors v) =>
    switch (kind) {
      'weight' => (Icons.monitor_weight_outlined, v.tintSky, v.skyInk),
      'scale' => (Icons.scale_outlined, v.tintSky, v.skyInk),
      'bp' => (Icons.monitor_heart_outlined, v.tintPeach, v.warnInk),
      'glucose' => (Icons.water_drop_outlined, v.lime, v.limeInk),
      'hr' => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
      _ => (Icons.bluetooth_rounded, v.tintBlue, v.blueInk),
    };

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.device,
    required this.v,
    required this.onTap,
    required this.onForget,
  });

  final MapEntry<String, String> entry;
  final Map<String, dynamic>? device;
  final VColors v;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final (icon, background, foreground) = _historyStyle(
      device?['kind'] as String? ?? '',
      v,
    );
    return VRowItem(
      icon: icon,
      iconBackground: background,
      iconColor: foreground,
      title: entry.value,
      subtitle: entry.key,
      value: device?['state'] == 'connected' ? '已连接' : null,
      trailing: IconButton(
        onPressed: onForget,
        icon: Icon(Icons.delete_outline_rounded, size: 18, color: v.muted),
      ),
      onTap: onTap,
    );
  }
}
