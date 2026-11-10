import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';

import '../../theme/tokens.dart';

Future<String?> showWatchAuthKeyDialog(
  BuildContext context, {
  String initialKey = '',
}) {
  final v = context.v;
  return showDialog<String>(
    context: context,
    builder: (_) => _WatchAuthKeyDialog(initialKey: initialKey, colors: v),
  );
}

class _WatchAuthKeyDialog extends StatefulWidget {
  const _WatchAuthKeyDialog({required this.initialKey, required this.colors});

  final String initialKey;
  final VColors colors;

  @override
  State<_WatchAuthKeyDialog> createState() => _WatchAuthKeyDialogState();
}

class _WatchAuthKeyDialogState extends State<_WatchAuthKeyDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialKey,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _controller.text.trim().toLowerCase();
    final error = key.isEmpty
        ? tr('请输入手表的认证 key')
        : !RegExp(r'^[0-9a-f]+$').hasMatch(key)
        ? tr('认证 key 只能是十六进制字符')
        : key.length != 64
        ? tr('认证 key 应为 64 个十六进制字符（32 字节）')
        : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, key);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.colors;
    return AlertDialog(
      backgroundColor: v.surface,
      title: Text(tr('华为认证 key'), style: VText.h2.copyWith(color: v.ink)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 2,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr('手表的 HiChain 认证 key'),
              hintText: tr('64 位十六进制字符串'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tr('用于手表已在官方 App 配对过、需要免恢复出厂重新认证的场景；保存后请重新连接手表。'),
            style: VText.label.copyWith(color: v.muted, height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('取消')),
        ),
        TextButton(onPressed: _submit, child: Text(tr('保存'))),
      ],
    );
  }
}
