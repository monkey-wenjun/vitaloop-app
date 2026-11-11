import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/app_update.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/language_options.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import 'auth_screen.dart';
import 'bluetooth_devices_screen.dart';
import 'equipment_screen.dart';
import 'map_settings_screen.dart';
import 'permissions_screen.dart';
import 'watch_screen.dart';
import 'workout_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final l10n = AppLocalizations.of(context);
    final profile = state.profile;
    final age = _age(profile?.birthDate ?? '');
    // 档案里的手填体重很容易过期，体脂秤的最近一次读数才是「现在的体重」；
    // 两处各取一个，设置页 65.0 kg、首页 69.4 kg，看着就像数据坏了。
    final weightKg = state.home?.weightKg ?? profile?.weightKg;
    final themeLabel = switch (state.themeMode) {
      ThemeMode.light => l10n.themeLight,
      ThemeMode.dark => l10n.themeDark,
      _ => l10n.themeSystem,
    };
    final languageLabel = state.language == 'system'
        ? l10n.languageSystem
        : languageOptionByCode(state.language)?.nativeName ?? state.language;
    final connectedDevices = state.devices.where((d) => d.connected).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsTitle,
                      style: VText.h1.copyWith(color: v.ink),
                    ),
                  ],
                ),
              ),
              VAvatar(
                initial: (profile?.nickname.isNotEmpty ?? false)
                    ? profile!.nickname.substring(0, 1)
                    : '元',
              ),
            ],
          ),
        ),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ProfileEditScreen(state: state)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF2549B8),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  (profile?.nickname.isNotEmpty ?? false)
                      ? profile!.nickname[0].toUpperCase()
                      : 'V',
                  style: VText.h3.copyWith(color: Colors.white, fontSize: 19),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile?.nickname.isNotEmpty == true
                              ? profile!.nickname
                              : l10n.notSetNickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: VText.h3.copyWith(fontSize: 16, color: v.ink),
                        ),
                        const SizedBox(height: 5),
                        VChip(
                          icon: state.signedIn
                              ? Icons.cloud_done_rounded
                              : Icons.phone_android_rounded,
                          text: state.signedIn
                              ? l10n.cloudAccount
                              : l10n.localProfileOffline,
                          background: state.signedIn ? v.tintGreen : v.tintGrey,
                          foreground: state.signedIn ? v.greenInk : v.ink2,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${age > 0 ? '$age${l10n.yearsShort} · ' : ''}${profile?.heightCm.round() ?? '--'} cm · ${weightKg?.toStringAsFixed(1) ?? '--'} kg',
                      style: VText.label.copyWith(
                        fontSize: 10.5,
                        color: v.muted,
                      ),
                    ),
                  ],
                ),
              ),
              VChip(text: l10n.editProfile),
            ],
          ),
        ),
        VSectionHead(title: l10n.trainingAndBody),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              VRowItem(
                icon: Icons.person_rounded,
                iconBackground: v.tintBlue,
                iconColor: v.blueInk,
                title: l10n.profileTitle,
                subtitle: l10n.profileSubtitle,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProfileEditScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.flag_rounded,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: l10n.workoutGoals,
                subtitle: l10n.workoutGoalsSubtitle,
                value: state.goals == null ? '--' : fmtInt(state.goals!.steps),
                valueSub: l10n.stepsPerDay,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => GoalsScreen(state: state)),
                ),
              ),
              VRowItem(
                icon: Icons.favorite_rounded,
                iconBackground: v.tintHeart,
                iconColor: v.heartInk,
                title: l10n.heartRateSettings,
                subtitle: l10n.heartRateSettingsSubtitle,
                value:
                    '${state.maxHrAuto || state.maxHr <= 0 ? _maxHr(profile) : state.maxHr}',
                valueSub: l10n.maxHeartRate,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => HeartRateSettingsScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.directions_run_rounded,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: l10n.workoutSettings,
                subtitle: l10n.workoutSettingsSubtitle,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const WorkoutSettingsScreen(),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.public_rounded,
                iconBackground: v.tintSky,
                iconColor: v.skyInk,
                title: '地图与离线',
                subtitle: '高德 / PMTiles 一键切换 · 当前城市离线缓存',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MapSettingsScreen()),
                ),
              ),
              VRowItem(
                icon: Icons.fitness_center_rounded,
                iconBackground: v.tintPurple,
                iconColor: v.purpleInk,
                title: l10n.myEquipment,
                subtitle: l10n.myEquipmentSubtitle,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EquipmentScreen()),
                ),
              ),
            ],
          ),
        ),
        VSectionHead(title: l10n.devicesAndSync),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              VRowItem(
                icon: Icons.bluetooth_rounded,
                iconBackground: v.tintBlue,
                iconColor: v.blueInk,
                title: l10n.bluetoothDevices,
                subtitle: l10n.bluetoothDevicesSubtitle,
                value: connectedDevices > 0
                    ? '$connectedDevices'
                    : l10n.notConnected,
                valueSub: connectedDevices > 0 ? l10n.connected : null,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BluetoothDevicesScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.watch_rounded,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: l10n.watchTitle,
                subtitle: l10n.watchSubtitle,
                value: state.watchIdentity?.address.isNotEmpty == true
                    ? l10n.bound
                    : l10n.unbound,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => WatchScreen(state: state)),
                ),
              ),
            ],
          ),
        ),
        VSectionHead(title: l10n.general),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              VRowItem(
                icon: Icons.account_circle_rounded,
                iconBackground: v.tintBlue,
                iconColor: v.blueInk,
                title: state.signedIn ? l10n.account : l10n.signInOrRegister,
                subtitle: state.signedIn
                    ? (state.accountEmail?.isNotEmpty == true
                          ? state.accountEmail!
                          : l10n.cloudAccountLabel)
                    : l10n.offlineOnly,
                value: state.signedIn ? l10n.signedIn : '',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => state.signedIn
                        ? AccountCenterScreen(state: state)
                        : AuthScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.auto_awesome_rounded,
                iconBackground: v.tintPurple,
                iconColor: v.purpleInk,
                title: l10n.appearance,
                subtitle: l10n.appearanceSubtitle,
                value: themeLabel,
                showChevron: true,
                onTap: () => _pickTheme(context),
              ),
              VRowItem(
                icon: Icons.translate_rounded,
                iconBackground: v.tintSky,
                iconColor: v.skyInk,
                title: l10n.language,
                subtitle: l10n.languageSubtitle,
                value: languageLabel,
                showChevron: true,
                onTap: () => _pickLanguage(context),
              ),
              VRowItem(
                icon: Icons.shield_outlined,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: l10n.permissions,
                subtitle: l10n.permissionsSubtitle,
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PermissionsScreen()),
                ),
              ),
              VRowItem(
                icon: Icons.info_rounded,
                iconBackground: v.grey,
                iconColor: v.greyInk,
                title: l10n.about,
                subtitle:
                    '${state.appVersion.versionName} · ${l10n.openSourceLicense}',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => AboutScreen(state: state)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        if (state.signedIn)
          VGhostButton(
            label: l10n.signOut,
            icon: Icons.logout_rounded,
            onTap: () async {
              await state.signOut();
            },
          ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            l10n.settingsFooter,
            style: VText.label.copyWith(fontSize: 10, color: v.muted),
          ),
        ),
      ],
    );
  }

  int _age(String birth) {
    final d = DateTime.tryParse(birth);
    if (d == null) return 0;
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) age--;
    return age;
  }

  int _maxHr(Profile? p) {
    return estimatedMaxHr(p?.birthDate);
  }

  void _pickTheme(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in [
              (ThemeMode.system, l10n.themeSystem),
              (ThemeMode.light, l10n.themeLight),
              (ThemeMode.dark, l10n.themeDark),
            ])
              ListTile(
                title: Text(
                  entry.$2,
                  style: VText.body.copyWith(color: ctx.v.ink),
                ),
                trailing: state.themeMode == entry.$1
                    ? Icon(Icons.check_rounded, color: ctx.v.blue)
                    : null,
                onTap: () {
                  state.setTheme(entry.$1);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _pickLanguage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.selectLanguage,
                  style: VText.h2.copyWith(color: ctx.v.ink),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in appLanguageOptions)
                    ListTile(
                      title: Text(
                        option.code == 'system'
                            ? l10n.languageSystem
                            : option.nativeName,
                        style: VText.body.copyWith(color: ctx.v.ink),
                      ),
                      trailing: state.language == option.code
                          ? Icon(Icons.check_rounded, color: ctx.v.blue)
                          : null,
                      onTap: () {
                        state.setLanguage(option.code);
                        Navigator.pop(ctx);
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _nickname;
  late final TextEditingController _height;
  late final TextEditingController _weight;
  late String _gender;
  late final TextEditingController _birth;

  @override
  void initState() {
    super.initState();
    final p = widget.state.profile;
    _nickname = TextEditingController(text: p?.nickname ?? '');
    _height = TextEditingController(
      text: (p?.heightCm ?? 170).toStringAsFixed(0),
    );
    _weight = TextEditingController(
      text: (p?.weightKg ?? 65).toStringAsFixed(1),
    );
    _birth = TextEditingController(text: p?.birthDate ?? '1990-01-01');
    _gender = p?.gender ?? 'male';
  }

  @override
  void dispose() {
    _nickname.dispose();
    _height.dispose();
    _weight.dispose();
    _birth.dispose();
    super.dispose();
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
            VDetailHeader(
              title: '个人资料',
              trailing: GestureDetector(
                onTap: _save,
                child: const VChip(text: '保存'),
              ),
            ),
            VCard(
              child: Center(
                child: Column(
                  children: [
                    Container(
                      width: 74,
                      height: 74,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2549B8),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        (_nickname.text.isNotEmpty ? _nickname.text[0] : 'V')
                            .toUpperCase(),
                        style: VText.h1.copyWith(
                          color: Colors.white,
                          fontSize: 28,
                        ),
                      ),
                    ),
                    const SizedBox(height: 11),
                    Text(
                      '头像使用昵称首字母',
                      style: VText.label.copyWith(color: v.muted),
                    ),
                  ],
                ),
              ),
            ),
            VCard(
              child: Column(
                children: [
                  _Field(
                    label: '昵称',
                    child: TextField(
                      controller: _nickname,
                      style: _inputStyle(v),
                      decoration: _decoration(v, hint: '你的昵称'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  _Field(
                    label: '性别',
                    child: Row(
                      children: [
                        _GenderChip(
                          label: '男',
                          selected: _gender == 'male',
                          onTap: () => setState(() => _gender = 'male'),
                        ),
                        const SizedBox(width: 8),
                        _GenderChip(
                          label: '女',
                          selected: _gender == 'female',
                          onTap: () => setState(() => _gender = 'female'),
                        ),
                      ],
                    ),
                  ),
                  _Field(
                    label: '出生日期',
                    child: TextField(
                      controller: _birth,
                      style: _inputStyle(v),
                      decoration: _decoration(v, hint: '1990-01-01'),
                    ),
                  ),
                  _Field(
                    label: '身高',
                    child: TextField(
                      controller: _height,
                      keyboardType: TextInputType.number,
                      style: _inputStyle(v),
                      decoration: _decoration(v, hint: 'cm', suffix: 'cm'),
                    ),
                  ),
                  _Field(
                    label: '体重',
                    last: true,
                    child: TextField(
                      controller: _weight,
                      keyboardType: TextInputType.number,
                      style: _inputStyle(v),
                      decoration: _decoration(v, hint: 'kg', suffix: 'kg'),
                    ),
                  ),
                ],
              ),
            ),
            VCard(
              background: v.tintGrey,
              child: Text(
                '身高体重用于 BMI 与基础代谢；年龄与性别用于最大心率估算和卡路里计算；以上数据仅保存在本机。',
                style: VText.label.copyWith(color: v.ink2, height: 1.55),
              ),
            ),
            VPrimaryButton(label: '保存资料', onTap: _save),
          ],
        ),
      ),
    );
  }

  void _save() async {
    final current = widget.state.profile ?? await VitaloopApi.profile();
    await widget.state.saveProfile(
      Profile(
        nickname: _nickname.text.trim().isEmpty
            ? current.nickname
            : _nickname.text.trim(),
        gender: _gender,
        heightCm: double.tryParse(_height.text) ?? current.heightCm,
        weightKg: double.tryParse(_weight.text) ?? current.weightKg,
        birthDate: _birth.text.trim().isEmpty
            ? current.birthDate
            : _birth.text.trim(),
        email: current.email,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  TextStyle _inputStyle(VColors v) => VText.meta.copyWith(
    color: v.ink,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
  );

  InputDecoration _decoration(VColors v, {String? hint, String? suffix}) =>
      InputDecoration(
        hintText: hint,
        suffixText: suffix,
        hintStyle: VText.meta.copyWith(color: v.muted),
        suffixStyle: VText.meta.copyWith(color: v.muted),
        isDense: true,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
      );
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.last = false});

  final String label;
  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: v.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: VText.meta.copyWith(color: v.ink2)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _GenderChip extends StatelessWidget {
  const _GenderChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? v.blue : v.tintGrey,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          style: VText.label.copyWith(
            color: selected ? Colors.white : v.ink2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class HeartRateSettingsScreen extends StatefulWidget {
  const HeartRateSettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<HeartRateSettingsScreen> createState() =>
      _HeartRateSettingsScreenState();
}

class _HeartRateSettingsScreenState extends State<HeartRateSettingsScreen> {
  late int _maxHr = _estimate();
  late int _resting = widget.state.home?.restingHr?.round() ?? 59;
  bool _customMaxHr = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      VitaloopApi.setting('max_hr', ''),
      VitaloopApi.setting('resting_hr', '$_resting'),
      VitaloopApi.setting('max_hr_auto', '1'),
    ]);
    if (!mounted) return;
    final saved = int.tryParse(values[0]);
    final custom = values[2] == '0' && saved != null && saved > 0;
    setState(() {
      _customMaxHr = custom;
      _maxHr = custom ? saved : _estimate();
      _resting = int.tryParse(values[1]) ?? _resting;
    });
  }

  int _estimate() {
    return estimatedMaxHr(widget.state.profile?.birthDate);
  }

  Future<void> _toggleCustom(bool value) async {
    setState(() {
      _customMaxHr = value;
      if (!value) _maxHr = _estimate();
    });
    await VitaloopApi.setSetting('max_hr_auto', value ? '0' : '1');
    await VitaloopApi.setSetting('max_hr', '$_maxHr');
    await widget.state.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final reserve = _maxHr - _resting;
    final zones = [
      ('Z1 热身', 0.50, v.skyInk),
      ('Z2 轻松', 0.60, v.greenInk),
      ('Z3 有氧', 0.70, const Color(0xFFB8860B)),
      ('Z4 阈值', 0.80, const Color(0xFFD97A12)),
      ('Z5 最大', 0.90, v.heartInk),
    ];
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '心率设置'),
            VCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('基本设置', style: VText.h3.copyWith(color: v.ink)),
                      const Spacer(),
                      const VChip(text: '储备心率法'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _kvRow('静息心率', '$_resting bpm（自动）'),
                  _kvRow(
                    '最大心率',
                    '$_maxHr bpm（${_customMaxHr ? '手动' : '自动 220 − 年龄'}）',
                  ),
                  _kvRow('储备心率', '$reserve bpm'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '自定义最大心率',
                        style: VText.meta.copyWith(color: v.ink2),
                      ),
                      const Spacer(),
                      Switch(
                        value: _customMaxHr,
                        activeThumbColor: v.blue,
                        onChanged: _toggleCustom,
                      ),
                    ],
                  ),
                  if (_customMaxHr)
                    Slider(
                      value: _maxHr.toDouble(),
                      min: 150,
                      max: 210,
                      divisions: 60,
                      activeColor: v.blue,
                      label: '$_maxHr',
                      onChanged: (value) =>
                          setState(() => _maxHr = value.round()),
                      onChangeEnd: (value) async {
                        await VitaloopApi.setSetting('max_hr_auto', '0');
                        await VitaloopApi.setSetting(
                          'max_hr',
                          '${value.round()}',
                        );
                        await widget.state.refresh();
                      },
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '220 − ${ageFromBirthDate(widget.state.profile?.birthDate)} = $_maxHr bpm',
                        style: VText.label.copyWith(color: v.muted),
                      ),
                    ),
                ],
              ),
            ),
            VCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('五档心率区间', style: VText.h3.copyWith(color: v.ink)),
                      const Spacer(),
                      Text(
                        '基于储备心率',
                        style: VText.label.copyWith(color: v.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final zone in zones)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: zone.$3,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 62,
                            child: Text(
                              zone.$1,
                              style: VText.meta.copyWith(color: v.ink2),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${(_resting + reserve * zone.$2).round()}–${(_resting + reserve * (zone.$2 + 0.1)).round()} bpm',
                            style: VText.meta.copyWith(
                              color: v.ink,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '最大心率默认按 220 − 年龄自动计算；打开自定义后才使用手动值，区间会根据当前静息心率重新计算。',
                    style: VText.label.copyWith(
                      fontSize: 10,
                      color: v.muted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(String label, String value) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: VText.meta.copyWith(color: v.muted)),
          const Spacer(),
          Text(
            value,
            style: VText.meta.copyWith(
              color: v.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _shownVersion;
  bool _dialogOpen = false;
  bool _installing = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_check(manual: false));
    });
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    final update = _state.availableUpdate;
    if (update != null) _queueUpdateDialog(update);
  }

  Future<void> _check({required bool manual}) async {
    if (manual) _shownVersion = null;
    await _state.checkForUpdate();
    if (!mounted) return;
    final update = _state.availableUpdate;
    if (update != null) {
      _queueUpdateDialog(update);
      return;
    }
    if (manual) {
      final error = _state.updateCheckError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error == null || error.isEmpty ? '已是最新版本' : error),
        ),
      );
    }
  }

  void _queueUpdateDialog(AppUpdateInfo update) {
    if (!mounted || _dialogOpen) return;
    if (_shownVersion == update.latestVersion) return;
    _shownVersion = update.latestVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_dialogOpen) {
        unawaited(_showUpdateDialog(update));
      }
    });
  }

  Future<void> _showUpdateDialog(AppUpdateInfo update) async {
    _dialogOpen = true;
    final action = await showDialog<_UpdateAction>(
      context: context,
      barrierDismissible: !update.forceUpdate,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 v${update.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                update.updateNotes.isEmpty ? '修复已知问题并优化体验' : update.updateNotes,
              ),
              if (update.forceUpdate) ...[
                const SizedBox(height: 10),
                Text(
                  '此版本为强制更新，请升级后继续使用',
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!update.forceUpdate)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('以后再说'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_UpdateAction.install),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (action == _UpdateAction.install && mounted) {
      await _install(update);
    }
  }

  Future<void> _install(AppUpdateInfo update) async {
    if (_installing) return;
    if (!await AppUpdateClient.canInstall()) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('需要安装权限'),
          content: const Text('请允许元环安装未知来源应用，返回后再点一次“立即更新”。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('去授权'),
            ),
          ],
        ),
      );
      if (go == true) await AppUpdateClient.openInstallPermission();
      return;
    }

    if (!mounted) return;
    setState(() => _installing = true);
    var loadingOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              SizedBox(width: 14),
              Expanded(child: Text('正在下载并校验更新包…')),
            ],
          ),
        ),
      ).whenComplete(() => loadingOpen = false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final result = await AppUpdateClient.downloadAndInstall(update.downloadUrl);
    if (loadingOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    setState(() => _installing = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  }

  String _updateSubtitle() {
    if (_installing) return '正在下载更新包…';
    if (_state.updateChecking) return '正在检查服务端版本…';
    final update = _state.availableUpdate;
    if (update != null) {
      return '发现新版本 v${update.latestVersion}${update.forceUpdate ? ' · 强制更新' : ''}';
    }
    final error = _state.updateCheckError;
    if (error != null && error.isNotEmpty) {
      return error.length > 28 ? '检查失败，点此重试' : error;
    }
    return '当前 ${_state.appVersion.label}';
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final busy = _state.updateChecking || _installing;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '关于'),
            VCard(
              child: Column(
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: v.blue,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Icon(
                      Icons.all_inclusive_rounded,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Vitaloop · 元环',
                    style: VText.h2.copyWith(color: v.ink, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '版本 ${_state.appVersion.label}',
                    style: VText.label.copyWith(color: v.muted),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '把心率、睡眠、HRV 与运动记录留给自己。\nFlutter 界面 + Rust 核心；不登录只存本机，登录后可选云端同步。',
                    textAlign: TextAlign.center,
                    style: VText.body.copyWith(color: v.ink2),
                  ),
                ],
              ),
            ),
            VCard(
              child: Column(
                children: [
                  VRowItem(
                    icon: Icons.system_update_rounded,
                    iconBackground: v.tintBlue,
                    iconColor: v.blueInk,
                    title: '检查更新',
                    subtitle: _updateSubtitle(),
                    value: _state.availableUpdate == null
                        ? null
                        : 'v${_state.availableUpdate!.latestVersion}',
                    trailing: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    showChevron: !busy,
                    onTap: busy ? null : () => _check(manual: true),
                  ),
                  const VRowItem(
                    icon: Icons.code_rounded,
                    title: '开源许可',
                    subtitle: 'GNU AGPL-3.0',
                  ),
                  const VRowItem(
                    icon: Icons.favorite_rounded,
                    title: '致谢',
                    subtitle: 'Huawei 协议参考 Gadgetbridge（AGPL-3.0）',
                  ),
                  VRowItem(
                    icon: Icons.privacy_tip_rounded,
                    title: '隐私',
                    subtitle: '不登录只存本机 · 登录后 HTTPS 云同步',
                    showChevron: true,
                    onTap: () => showModalBottomSheet(
                      context: context,
                      backgroundColor: v.surface,
                      showDragHandle: true,
                      builder: (ctx) => Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '隐私',
                              style: VText.h2.copyWith(color: ctx.v.ink),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '不登录时：健康数据（心率、睡眠、运动记录、从旧版导入的历史）只写入本机 SQLite，不上传服务器，没有埋点与第三方分析 SDK。\n\n登录后：健康快照通过 HTTPS 上传到你配置的云端服务器账号目录，用于云备份和换机恢复；密码只保存加盐哈希。地图只向当前选择的底图服务请求查看区域瓦片；默认使用自托管的 Protomaps PMTiles，也可以一键切换到高德栅格底图，不含健康数据。',
                              style: VText.body.copyWith(color: ctx.v.ink2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Center(
              child: Text(
                '© 2026 Vitaloop contributors',
                style: VText.label.copyWith(color: v.muted, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _UpdateAction { install }

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  late final TextEditingController _steps;
  late final TextEditingController _calories;
  late final TextEditingController _active;
  late final TextEditingController _exercise;

  @override
  void initState() {
    super.initState();
    final g = widget.state.goals;
    _steps = TextEditingController(text: '${g?.steps ?? 10000}');
    _calories = TextEditingController(text: '${g?.calories ?? 500}');
    _active = TextEditingController(text: '${g?.activeMinutes ?? 60}');
    _exercise = TextEditingController(text: '${g?.exerciseMinutes ?? 30}');
  }

  @override
  void dispose() {
    _steps.dispose();
    _calories.dispose();
    _active.dispose();
    _exercise.dispose();
    super.dispose();
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
            const VDetailHeader(title: '运动目标'),
            VCard(
              child: Column(
                children: [
                  _GoalField(label: '每日步数', controller: _steps, unit: '步'),
                  _GoalField(
                    label: '活动热量',
                    controller: _calories,
                    unit: 'kcal',
                  ),
                  _GoalField(label: '活动时长', controller: _active, unit: '分钟'),
                  _GoalField(
                    label: '运动时长',
                    controller: _exercise,
                    unit: '分钟',
                    last: true,
                  ),
                ],
              ),
            ),
            VCard(
              background: v.tintGrey,
              child: Text(
                '目标会显示在首页进度条中，也会在同步时下发给手表。',
                style: VText.label.copyWith(color: v.ink2, height: 1.55),
              ),
            ),
            VPrimaryButton(label: '保存目标', onTap: _save),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final current = widget.state.goals ?? await VitaloopApi.goals();
    await VitaloopApi.saveGoals(
      Goals(
        steps: int.tryParse(_steps.text) ?? current.steps,
        calories: int.tryParse(_calories.text) ?? current.calories,
        activeMinutes: int.tryParse(_active.text) ?? current.activeMinutes,
        exerciseMinutes:
            int.tryParse(_exercise.text) ?? current.exerciseMinutes,
      ),
    );
    await widget.state.refresh();
    if (mounted) Navigator.pop(context);
  }
}

class _GoalField extends StatelessWidget {
  const _GoalField({
    required this.label,
    required this.controller,
    required this.unit,
    this.last = false,
  });

  final String label;
  final TextEditingController controller;
  final String unit;
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
          SizedBox(
            width: 90,
            child: Text(label, style: VText.meta.copyWith(color: v.ink2)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.right,
              style: VText.meta.copyWith(
                color: v.ink,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                suffixText: unit,
                suffixStyle: VText.meta.copyWith(color: v.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
