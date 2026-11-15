import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';

import '../../theme/tokens.dart';

Future<String?> showHuaweiAccountDialog(
  BuildContext context, {
  required String name,
  required String address,
  required String initialAccount,
}) {
  final v = context.v;
  return showDialog<String>(
    context: context,
    builder: (_) => _HuaweiAccountDialog(
      name: name,
      address: address,
      initialAccount: initialAccount,
      colors: v,
    ),
  );
}

class _HuaweiAccountDialog extends StatefulWidget {
  const _HuaweiAccountDialog({
    required this.name,
    required this.address,
    required this.initialAccount,
    required this.colors,
  });

  final String name;
  final String address;
  final String initialAccount;
  final VColors colors;

  @override
  State<_HuaweiAccountDialog> createState() => _HuaweiAccountDialogState();
}

class _HuaweiAccountDialogState extends State<_HuaweiAccountDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialAccount,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final account = _controller.text.trim();
    final error = account.isEmpty
        ? tr('请输入手表绑定的华为账号')
        : !RegExp(r'^\d{17}$').hasMatch(account)
        ? tr('华为账号 ID 是 17 位数字，不是邮箱')
        : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, account);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.colors;
    return AlertDialog(
      backgroundColor: v.surface,
      title: Text('连接华为手表', style: VText.h2.copyWith(color: v.ink)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.name}\n${widget.address}',
            style: VText.label.copyWith(color: v.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr('手表绑定的华为账号'),
              hintText: tr('例如 20007000023812345'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '填华为账号 ID（17 位数字）。在华为健康 shared_prefs/login_data.xml 的 old_user_id 里获取；不要卸载前解绑官方 App。',
            style: VText.label.copyWith(color: v.muted, height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }
}
