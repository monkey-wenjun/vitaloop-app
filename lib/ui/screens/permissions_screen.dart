import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/permission_bridge.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  PermissionSnapshot? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final status = await PermissionBridge.instance.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _requestAll() async {
    setState(() => _busy = true);
    var status = await PermissionBridge.instance.request();
    if (!status.backgroundLocation && status.location) {
      status = await PermissionBridge.instance.requestBackgroundLocation();
    }
    if (mounted) {
      setState(() {
        _status = status;
        _busy = false;
      });
    }
  }

  Future<void> _requestBackground() async {
    setState(() => _busy = true);
    final status = await PermissionBridge.instance.requestBackgroundLocation();
    if (mounted) {
      setState(() {
        _status = status;
        _busy = false;
      });
    }
  }

  Future<void> _requestBatteryOptimization() async {
    final status = await PermissionBridge.instance.requestBatteryOptimization();
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final status = _status;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(
              title: '权限管理',
              trailing: VIconButton(icon: Icons.refresh_rounded, onTap: _load),
            ),
            if (status == null)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              VCard(
                background: status.allGranted ? v.green : v.sky,
                foreground: status.allGranted ? v.greenInk : v.skyInk,
                child: Row(
                  children: [
                    Icon(
                      status.allGranted
                          ? Icons.verified_rounded
                          : Icons.shield_outlined,
                      size: 28,
                      color: status.allGranted ? v.greenInk : v.skyInk,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status.allGranted ? '权限已齐全' : '还有权限未开启',
                            style: VText.h3.copyWith(
                              color: status.allGranted ? v.greenInk : v.skyInk,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            status.allGranted
                                ? '运动轨迹、心率设备和后台同步可以正常工作。'
                                : '定位和蓝牙用于运动记录与手表同步；通知用于后台同步提示。',
                            style: VText.label.copyWith(
                              fontSize: 11,
                              color: (status.allGranted ? v.greenInk : v.skyInk)
                                  .withValues(alpha: 0.82),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '必要权限'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    _PermissionRow(
                      icon: Icons.my_location_rounded,
                      title: '位置权限',
                      description: '记录运动轨迹和距离',
                      granted: status.location,
                      onRequest: _requestAll,
                    ),
                    _PermissionRow(
                      icon: Icons.location_history_rounded,
                      title: '后台定位',
                      description: '锁屏或切到后台后继续记录轨迹',
                      granted: status.backgroundLocation,
                      onRequest: _requestBackground,
                    ),
                    _PermissionRow(
                      icon: Icons.bluetooth_rounded,
                      title: '附近设备',
                      description: '连接心率带、体脂秤和华为手表',
                      granted: status.bluetooth,
                      onRequest: _requestAll,
                    ),
                    _PermissionRow(
                      icon: Icons.notifications_active_rounded,
                      title: '通知',
                      description: '后台同步与正在记录运动时显示通知',
                      granted: status.notifications,
                      onRequest: _requestAll,
                      last: true,
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '后台保活'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: _PermissionRow(
                  icon: Icons.battery_saver_rounded,
                  title: '电池优化豁免',
                  description: '避免系统清理后台，保证手表连接、闹钟与同步稳定',
                  granted: status.batteryOptimization,
                  onRequest: _requestBatteryOptimization,
                  last: true,
                ),
              ),
              const VSectionHead(title: '可选'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    _PermissionRow(
                      icon: Icons.phone_in_talk_rounded,
                      title: '来电转发',
                      description: '把手机来电提醒推送到手表',
                      granted: status.phone,
                      onRequest: _requestAll,
                    ),
                    _PermissionRow(
                      icon: Icons.call_rounded,
                      title: '手表接听/挂断',
                      description: '允许手表接听或拒接手机来电',
                      granted: status.answerCalls,
                      onRequest: _requestAll,
                    ),
                    _PermissionRow(
                      icon: Icons.folder_copy_rounded,
                      title: '文件导入与导出',
                      description: '使用系统文件选择器，无需额外授权',
                      granted: true,
                      last: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              if (!status.allGranted)
                VPrimaryButton(
                  label: _busy ? '正在请求…' : '一键申请必要权限',
                  icon: Icons.lock_open_rounded,
                  onTap: _busy ? null : _requestAll,
                ),
              const SizedBox(height: 10),
              VGhostButton(
                label: '打开系统应用设置',
                icon: Icons.settings_outlined,
                onTap: () => PermissionBridge.instance.openAppSettings(),
              ),
              const SizedBox(height: 12),
              VCard(
                background: v.tintGrey,
                child: Text(
                  'Android 把定位拆成「使用应用时」和「始终允许」两档。后台定位必须在已授予前台定位后单独申请；如果系统不再弹窗，请到应用设置里选择「始终允许」。\n\n不开启蓝牙只会影响心率带、体脂秤和华为手表，不影响手机 GPS 运动记录。',
                  style: VText.label.copyWith(
                    fontSize: 10.5,
                    color: v.ink2,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    this.onRequest,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool granted;
  final VoidCallback? onRequest;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: v.line)),
      ),
      child: Row(
        children: [
          VIconBox(
            icon: icon,
            background: granted ? v.tintGreen : v.tintGrey,
            foreground: granted ? v.greenInk : v.ink2,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: VText.h3.copyWith(color: v.ink)),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: VText.label.copyWith(
                    fontSize: 10.5,
                    color: v.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (granted)
            Icon(Icons.check_circle_rounded, size: 22, color: v.greenInk)
          else
            GestureDetector(
              onTap: onRequest,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: v.blue,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  '授权',
                  style: VText.label.copyWith(
                    fontSize: 10.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
