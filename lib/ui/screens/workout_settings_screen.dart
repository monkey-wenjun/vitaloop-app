import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

class WorkoutSettingsScreen extends StatefulWidget {
  const WorkoutSettingsScreen({super.key});

  @override
  State<WorkoutSettingsScreen> createState() => _WorkoutSettingsScreenState();
}

class _WorkoutSettingsScreenState extends State<WorkoutSettingsScreen> {
  bool _autoPause = true;
  bool _autoResume = true;
  bool _recoveryHr = true;
  bool _keepScreenOn = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      VitaloopApi.setting('record_auto_pause', '1'),
      VitaloopApi.setting('record_auto_resume', '1'),
      VitaloopApi.setting('record_recovery_hr', '1'),
      VitaloopApi.setting('record_keep_screen_on', '1'),
    ]);
    if (!mounted) return;
    setState(() {
      _autoPause = values[0] == '1';
      _autoResume = values[1] == '1';
      _recoveryHr = values[2] == '1';
      _keepScreenOn = values[3] == '1';
      _loading = false;
    });
  }

  Future<void> _save(String key, bool value) async {
    await VitaloopApi.setSetting(key, value ? '1' : '0');
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '运动设置', icon: Icons.tune_rounded),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    _SwitchRow(
                      title: '自动暂停',
                      subtitle: '手机 GPS 速度低于 0.5 m/s 持续 5 秒时暂停计时',
                      icon: Icons.pause_circle_outline_rounded,
                      value: _autoPause,
                      onChanged: (on) {
                        setState(() => _autoPause = on);
                        _save('record_auto_pause', on);
                      },
                    ),
                    _SwitchRow(
                      title: '自动恢复',
                      subtitle: '速度超过 0.5 m/s 持续 3 秒后继续计时',
                      icon: Icons.play_circle_outline_rounded,
                      value: _autoResume,
                      onChanged: (on) {
                        setState(() => _autoResume = on);
                        _save('record_auto_resume', on);
                      },
                    ),
                    _SwitchRow(
                      title: '恢复心率检测',
                      subtitle: '运动结束后用已连接的心率带记录 2 分钟恢复心率',
                      icon: Icons.favorite_border_rounded,
                      value: _recoveryHr,
                      onChanged: (on) {
                        setState(() => _recoveryHr = on);
                        _save('record_recovery_hr', on);
                      },
                    ),
                    _SwitchRow(
                      title: '运动中屏幕常亮',
                      subtitle: '户外运动记录期间保持屏幕常亮',
                      icon: Icons.phone_android_rounded,
                      value: _keepScreenOn,
                      onChanged: (on) {
                        setState(() => _keepScreenOn = on);
                        _save('record_keep_screen_on', on);
                      },
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '说明'),
              VCard(
                background: v.tintGrey,
                child: Text(
                  '自动暂停/恢复使用手机 GPS 速度判断，室内或隧道里没有定位时不会误暂停。'
                  '恢复心率需要连接标准 BLE 心率带；没有心率数据时只保存运动本身。',
                  style: VText.label.copyWith(color: v.ink2, height: 1.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: v.tintBlue,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 19, color: v.blueInk),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: VText.h3.copyWith(fontSize: 13.5, color: v.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: VText.label.copyWith(
                    fontSize: 9.5,
                    color: v.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
