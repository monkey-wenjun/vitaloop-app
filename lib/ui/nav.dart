import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../theme/tokens.dart';

class VDetailHeader extends StatelessWidget {
  const VDetailHeader({
    super.key,
    required this.title,
    this.onMore,
    this.trailing,
    this.onBack,
    this.icon,
    this.iconColor,
  });

  final String title;
  final VoidCallback? onMore;
  final Widget? trailing;
  final VoidCallback? onBack;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final accent = iconColor ?? v.blue;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
      child: Row(
        children: [
          VIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          if (icon != null) ...[
            const SizedBox(width: 10),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 16, color: accent),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              textAlign: icon == null ? TextAlign.center : TextAlign.start,
              style: VText.h3.copyWith(fontSize: 15, color: v.ink),
            ),
          ),
          // 只有真的挂了动作才画这个按钮，否则满屏的「···」点下去没反应，等于骗人
          if (trailing != null)
            trailing!
          else if (onMore != null)
            VIconButton(icon: Icons.more_horiz_rounded, onTap: onMore!)
          else
            const SizedBox(width: 38),
        ],
      ),
    );
  }
}

class VIconButton extends StatelessWidget {
  const VIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: v.surface,
          shape: BoxShape.circle,
          border: Border.all(color: v.line),
        ),
        child: Icon(icon, size: 16, color: color ?? v.ink),
      ),
    );
  }
}

class VEmpty extends StatelessWidget {
  const VEmpty({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_rounded,
  });

  final String title;
  final String? subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(icon, size: 34, color: v.muted),
          const SizedBox(height: 10),
          Text(title, style: VText.h3.copyWith(color: v.ink2)),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: VText.label.copyWith(color: v.muted, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
