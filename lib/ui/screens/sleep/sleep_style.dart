import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import 'sleep_data.dart';

abstract final class SleepStyle {
  static const awake = Color(0xFFF28B62);
  static const rem = Color(0xFF25AAA8);
  static const light = Color(0xFFA794F5);
  static const deep = Color(0xFF6552D8);

  static const pagePadding = EdgeInsets.fromLTRB(18, 4, 18, 28);
  static const cardPadding = EdgeInsets.all(18);
  static const cardRadius = 26.0;
  static const compactRadius = 18.0;
  static const sectionGap = 12.0;
  static const chartHeight = 216.0;
  static const chartLeftGutter = 54.0;
  static const chartRightGutter = 8.0;
  static const chartTop = 8.0;
  static const chartLaneHeight = 38.0;
  static const chartAxisHeight = 28.0;

  static Color stageColor(SleepStageKind kind) => switch (kind) {
    SleepStageKind.awake => awake,
    SleepStageKind.rem => rem,
    SleepStageKind.light => light,
    SleepStageKind.deep => deep,
  };

  static Color stageTint(SleepStageKind kind, VColors colors) {
    final color = stageColor(kind);
    return color.withValues(alpha: colors.isDark ? 0.20 : 0.12);
  }

  static BoxDecoration card(VColors colors) => BoxDecoration(
    color: colors.surface,
    borderRadius: BorderRadius.circular(cardRadius),
    border: Border.all(color: colors.line),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: colors.isDark ? 0.16 : 0.035),
        blurRadius: 28,
        offset: const Offset(0, 10),
      ),
    ],
  );

  static BoxDecoration hero(VColors colors) => BoxDecoration(
    borderRadius: BorderRadius.circular(30),
    border: Border.all(
      color: colors.purple.withValues(alpha: colors.isDark ? 0.32 : 0.48),
    ),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors.isDark
          ? const [Color(0xFF1B1930), Color(0xFF151B2C)]
          : const [Color(0xFFFFFFFF), Color(0xFFF3EFFF)],
    ),
    boxShadow: [
      BoxShadow(
        color: deep.withValues(alpha: colors.isDark ? 0.20 : 0.11),
        blurRadius: 38,
        offset: const Offset(0, 16),
      ),
    ],
  );

  static BoxDecoration inset(VColors colors) => BoxDecoration(
    color: colors.tintGrey,
    borderRadius: BorderRadius.circular(compactRadius),
  );
}
