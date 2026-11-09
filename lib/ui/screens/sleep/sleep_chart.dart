import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/sleep_copy.dart';
import '../../../theme/tokens.dart';
import 'sleep_data.dart';
import 'sleep_style.dart';

class SleepChartMetrics {
  const SleepChartMetrics._();

  static double plotLeft = SleepStyle.chartLeftGutter;
  static double plotRight(Size size) =>
      size.width - SleepStyle.chartRightGutter;

  static double xFor(NightSleepData night, Size size, int ms) {
    final span = math.max(1, night.endMs - night.startMs);
    final ratio = ((ms - night.startMs) / span).clamp(0.0, 1.0);
    return plotLeft + ratio * (plotRight(size) - plotLeft);
  }
}

class SleepChartPainter extends CustomPainter {
  SleepChartPainter({
    required this.night,
    required this.l10n,
    required this.colors,
    required this.startLabel,
    required this.endLabel,
  });

  final NightSleepData night;
  final AppLocalizations l10n;
  final VColors colors;
  final String startLabel;
  final String endLabel;

  static const _kinds = [
    SleepStageKind.awake,
    SleepStageKind.rem,
    SleepStageKind.light,
    SleepStageKind.deep,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final plotLeft = SleepChartMetrics.plotLeft;
    final plotRight = SleepChartMetrics.plotRight(size);
    final laneHeight = SleepStyle.chartLaneHeight;
    final top = SleepStyle.chartTop;
    final axisTop = top + laneHeight * _kinds.length + 6;

    for (var i = 0; i < _kinds.length; i++) {
      final kind = _kinds[i];
      final y = top + laneHeight * i;
      final lane = RRect.fromRectAndRadius(
        Rect.fromLTRB(plotLeft, y + 2, plotRight, y + laneHeight - 2),
        const Radius.circular(10),
      );
      canvas.drawRRect(
        lane,
        Paint()
          ..color = SleepStyle.stageTint(
            kind,
            colors,
          ).withValues(alpha: colors.isDark ? 0.10 : 0.055),
      );
      _paintText(
        canvas,
        l10n.sleepStageName(kind),
        Offset(0, y + laneHeight / 2),
        TextStyle(
          color: colors.muted,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
        ),
        verticalCenter: true,
      );
    }

    _paintGrid(canvas, size, top, axisTop);

    for (final band in night.bands) {
      final row = _kinds.indexOf(band.kind);
      if (row < 0) continue;
      final x0 = SleepChartMetrics.xFor(night, size, band.startMs);
      final x1 = SleepChartMetrics.xFor(night, size, band.endMs);
      if (x1 - x0 < 0.8) continue;
      final y = top + laneHeight * row;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, y + 8, math.max(x0 + 2, x1 - 0.8), y + 30),
        const Radius.circular(7),
      );
      canvas.drawRRect(rect, Paint()..color = SleepStyle.stageColor(band.kind));
    }

    _paintText(
      canvas,
      startLabel,
      Offset(plotLeft, axisTop + 13),
      TextStyle(color: colors.muted, fontSize: 9, fontWeight: FontWeight.w600),
    );
    _paintText(
      canvas,
      endLabel,
      Offset(plotRight, axisTop + 13),
      TextStyle(color: colors.muted, fontSize: 9, fontWeight: FontWeight.w600),
      alignRight: true,
    );
  }

  void _paintGrid(Canvas canvas, Size size, double top, double axisTop) {
    final start = DateTime.fromMillisecondsSinceEpoch(night.startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(night.endMs);
    var tick = DateTime(start.year, start.month, start.day, start.hour + 1);
    final paint = Paint()
      ..strokeWidth = 0.8
      ..color = colors.line;
    while (tick.isBefore(end)) {
      final x = SleepChartMetrics.xFor(
        night,
        size,
        tick.millisecondsSinceEpoch,
      );
      canvas.drawLine(Offset(x, top), Offset(x, axisTop), paint);
      tick = tick.add(const Duration(hours: 1));
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    bool alignRight = false,
    bool verticalCenter = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    var dx = offset.dx;
    var dy = offset.dy;
    if (alignRight) dx -= painter.width;
    if (verticalCenter) dy -= painter.height / 2;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant SleepChartPainter old) =>
      old.night != night ||
      old.colors != colors ||
      old.startLabel != startLabel ||
      old.endLabel != endLabel;
}

class SleepScorePainter extends CustomPainter {
  SleepScorePainter({required this.score, required this.colors});

  final int score;
  final VColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 5;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..color = colors.purple,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * (score.clamp(0, 100) / 100),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          colors: [Color(0xFF6552D8), Color(0xFFA794F5)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant SleepScorePainter old) =>
      old.score != score || old.colors != colors;
}
