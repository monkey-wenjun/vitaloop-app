import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.state});

  final AppState state;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _register = false;
  bool _obscure = true;
  bool _agreed = false;
  late final _email = TextEditingController(
    text: widget.state.accountEmail ?? '',
  );
  final _password = TextEditingController();
  late final _server = TextEditingController(text: widget.state.cloudServer);
  String? _error;

  bool get _emailLooksValid {
    final email = _email.text.trim();
    return email.contains('@') && email.contains('.');
  }

  @override
  void initState() {
    super.initState();
    _email.addListener(_onEmailChanged);
  }

  void _onEmailChanged() => setState(() {});

  @override
  void dispose() {
    _email.removeListener(_onEmailChanged);
    _email.dispose();
    _password.dispose();
    _server.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 28),
          children: [
            const SizedBox(height: 18),
            Center(
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF6F8CFF),
                      Color(0xFF3B63F0),
                      Color(0xFF2343BC),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF3B63F0).withValues(alpha: 0.32),
                      blurRadius: 26,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.all_inclusive_rounded,
                  color: Colors.white,
                  size: 42,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                'VITALOOP',
                style: VText.label.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: v.muted,
                  letterSpacing: 3.2,
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              _register ? '创建账号' : '欢迎回来',
              style: VText.h1.copyWith(fontSize: 30, color: v.ink),
            ),
            const SizedBox(height: 6),
            Text(
              _register
                  ? '注册后健康数据会加密传输并同步到你的云端账号；不登录也能继续只用本机'
                  : '登录后把本机历史与后续手表数据同步到云端；不登录则全部只存本机',
              style: VText.meta.copyWith(color: v.muted, height: 1.5),
            ),
            if (_register) ...[
              const SizedBox(height: 10),
              const Align(
                alignment: Alignment.centerLeft,
                child: VChip(text: '邮箱注册 · 无需手机号'),
              ),
            ],
            const SizedBox(height: 24),
            _AuthField(
              icon: Icons.dns_outlined,
              hint: '云端服务器地址（可自建）',
              controller: _server,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            _AuthField(
              icon: Icons.mail_outline_rounded,
              hint: '邮箱',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              trailing: _emailLooksValid ? Icons.check_circle_rounded : null,
              trailingColor: v.greenInk,
            ),
            const SizedBox(height: 12),
            _AuthField(
              icon: Icons.lock_outline_rounded,
              hint: '密码',
              controller: _password,
              obscure: _obscure,
              trailing: _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              onTrailingTap: () => setState(() => _obscure = !_obscure),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: VText.label.copyWith(color: v.danger)),
            ],
            if (!_register) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _sheet(
                      '忘记密码',
                      '账号密码只用于云端登录，服务器保存的是加盐哈希，不保存明文。当前版本还没有自助重置入口；忘记后请在本机保留数据并在后续版本通过重置流程处理。',
                    ),
                    child: Text(
                      '忘记密码',
                      style: VText.label.copyWith(
                        color: v.blue,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () => setState(() => _agreed = !_agreed),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _agreed
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                      color: _agreed ? v.blue : v.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '我已阅读并同意 ',
                            style: VText.label.copyWith(
                              color: v.muted,
                              height: 1.5,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _sheet(
                              '服务条款',
                              '这是装在你自己设备上的开源健康看板，不登录时全部功能只用本机 SQLite。登录后，健康快照会通过 HTTPS 上传到你配置的云端服务器账号目录，用于多设备恢复；可随时退出登录停止同步。',
                            ),
                            child: Text(
                              '《服务条款》',
                              style: VText.label.copyWith(
                                color: v.blue,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            ' 与 ',
                            style: VText.label.copyWith(color: v.muted),
                          ),
                          GestureDetector(
                            onTap: () => _sheet(
                              '隐私政策',
                              '不登录时：健康数据（心率、睡眠、运动记录、从旧版导入的历史）只写入本机 SQLite，不上传服务器，没有埋点与第三方分析 SDK。\n\n登录后：上述健康快照通过 HTTPS 上传到你配置的云端服务器账号目录，仅用于你自己的云备份与换机恢复；密码只保存加盐哈希。地图瓦片仍只向高德 autonavi.com 请求当前查看区域，不含健康数据。',
                            ),
                            child: Text(
                              '《隐私政策》',
                              style: VText.label.copyWith(
                                color: v.blue,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 22),
            VPrimaryButton(
              label: widget.state.cloudBusy
                  ? '请稍候…'
                  : (_register ? '注册并登录' : '登录'),
              onTap: widget.state.cloudBusy ? null : _submit,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Divider(color: v.line)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('或', style: VText.label.copyWith(color: v.muted)),
                ),
                Expanded(child: Divider(color: v.line)),
              ],
            ),
            const SizedBox(height: 18),
            VGhostButton(
              label: '游客模式 · 仅本机记录',
              icon: Icons.person_outline_rounded,
              onTap: () async {
                final navigator = Navigator.of(context);
                await widget.state.continueAsGuest();
                if (mounted && navigator.canPop()) navigator.pop();
              },
            ),
            const SizedBox(height: 22),
            Center(
              child: GestureDetector(
                onTap: () => setState(() {
                  _register = !_register;
                  _error = null;
                }),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _register ? '已有账号？' : '还没有账号？',
                        style: VText.meta.copyWith(color: v.muted),
                      ),
                      TextSpan(
                        text: _register ? ' 去登录' : ' 立即注册',
                        style: VText.meta.copyWith(
                          color: v.blue,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shield_outlined, size: 13, color: v.muted),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '不登录 = 只存本机；登录 = HTTPS 同步到你的云端账号',
                    textAlign: TextAlign.center,
                    style: VText.label.copyWith(fontSize: 10, color: v.muted),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _sheet(String title, String body) {
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

  Future<void> _submit() async {
    if (!_emailLooksValid) {
      setState(() => _error = '请输入有效的邮箱地址');
      return;
    }
    final email = _email.text.trim();
    if (_password.text.length < 6) {
      setState(() => _error = '密码至少 6 位');
      return;
    }
    if (_server.text.trim().isEmpty) {
      setState(() => _error = '请填写云端服务器地址；只用本机请选择游客模式');
      return;
    }
    if (_register && !_agreed) {
      setState(() => _error = '请先阅读并同意服务条款');
      return;
    }
    try {
      await widget.state.setCloudServer(_server.text);
      await widget.state.signIn(
        email,
        password: _password.text,
        register: _register,
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AccountCenterScreen(state: widget.state),
      ),
    );
  }
}

class AccountCenterScreen extends StatelessWidget {
  const AccountCenterScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final signedIn = state.signedIn;
        final profile = state.profile;
        final nickname = profile?.nickname.isNotEmpty == true
            ? profile!.nickname
            : '元环用户';
        final email = !signedIn
            ? '未登录 · 本机资料'
            : (state.accountEmail?.isNotEmpty == true
                  ? state.accountEmail!
                  : (profile?.email.isNotEmpty == true
                        ? profile!.email
                        : '未绑定邮箱'));
        final emailLabel = signedIn ? email : '未绑定邮箱';
        return Scaffold(
          backgroundColor: v.bg,
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                const VDetailHeader(title: '个人中心'),
                VCard(
                  padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                  child: Column(
                    children: [
                      Container(
                        width: 68,
                        height: 68,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2549B8),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          nickname.substring(0, 1).toUpperCase(),
                          style: VText.h1.copyWith(
                            color: Colors.white,
                            fontSize: 26,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(nickname, style: VText.h2.copyWith(color: v.ink)),
                      const SizedBox(height: 4),
                      Text(email, style: VText.meta.copyWith(color: v.muted)),
                      const SizedBox(height: 10),
                      VChip(
                        icon: signedIn
                            ? Icons.cloud_done_rounded
                            : Icons.person_outline_rounded,
                        text: signedIn ? '已登录' : '未登录',
                        background: signedIn ? v.tintGreen : v.tintGrey,
                        foreground: signedIn ? v.greenInk : v.ink2,
                      ),
                    ],
                  ),
                ),
                VSectionHead(title: signedIn ? '云端账号' : '本机资料'),
                VCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      VRowItem(
                        icon: Icons.mail_outline_rounded,
                        iconBackground: v.tintBlue,
                        iconColor: v.blueInk,
                        title: '登录邮箱',
                        subtitle: emailLabel,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      VRowItem(
                        icon: Icons.dns_outlined,
                        iconBackground: v.tintPurple,
                        iconColor: v.purpleInk,
                        title: '云端服务器',
                        subtitle: state.cloudServer,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      VRowItem(
                        icon: Icons.schedule_rounded,
                        iconBackground: v.tintGreen,
                        iconColor: v.greenInk,
                        title: '最近同步',
                        subtitle: state.cloudLastSync == null
                            ? '还没有同步记录'
                            : _syncTime(state.cloudLastSync!),
                        value: state.cloudBusy ? '同步中' : null,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ],
                  ),
                ),
                if (state.cloudStatus != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    state.cloudStatus!,
                    textAlign: TextAlign.center,
                    style: VText.label.copyWith(color: v.muted),
                  ),
                  const SizedBox(height: 8),
                ],
                if (signedIn) ...[
                  VGhostButton(
                    label: '退出登录',
                    icon: Icons.logout_rounded,
                    onTap: () => _confirmSignOut(context),
                  ),
                ] else ...[
                  VPrimaryButton(
                    label: '登录 / 注册（可选）',
                    icon: Icons.login_rounded,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AuthScreen(state: state),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  signedIn
                      ? '登录期间每 1 分钟自动同步云端；退出后本机数据不会删除。'
                      : '当前展示的是本机资料；登录后才会把健康数据同步到云端。',
                  textAlign: TextAlign.center,
                  style: VText.label.copyWith(
                    fontSize: 10,
                    color: v.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.v.surface,
        title: Text('退出登录', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '退出后停止云端同步，本机健康记录仍会保留。',
          style: VText.body.copyWith(color: ctx.v.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.signOut();
    if (context.mounted) Navigator.of(context).pop();
  }

  static String _syncTime(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _AuthField extends StatelessWidget {
  const _AuthField({
    required this.icon,
    required this.hint,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.trailing,
    this.trailingColor,
    this.onTrailingTap,
  });

  final IconData icon;
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final IconData? trailing;
  final Color? trailingColor;
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      decoration: BoxDecoration(
        color: v.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: v.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 19, color: v.muted),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboardType,
              style: VText.meta.copyWith(
                fontSize: 13.5,
                color: v.ink,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: VText.meta.copyWith(fontSize: 13, color: v.muted),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          if (trailing != null)
            GestureDetector(
              onTap: onTrailingTap,
              child: Icon(trailing, size: 19, color: trailingColor ?? v.muted),
            ),
        ],
      ),
    );
  }
}
