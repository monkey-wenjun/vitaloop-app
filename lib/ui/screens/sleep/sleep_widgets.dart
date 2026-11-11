import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../../l10n/app_localizations.dart';
import '../../../l10n/sleep_copy.dart';
import '../../../src/rust/api/types.dart';
import '../../../theme/tokens.dart';
import '../../../util/format.dart';
import 'sleep_chart.dart';
import 'sleep_data.dart';
import 'sleep_style.dart';

class SleepEmptyCard extends StatelessWidget {
  const SleepEmptyCard({super.key, required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    return Container(
      decoration: SleepStyle.card(colors),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.tintPurple,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.bedtime_rounded,
              color: colors.purpleInk,
              size: 27,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: VText.h2.copyWith(color: colors.ink),
          ),
          const SizedBox(height: 7),
          Text(
            body,
            textAlign: TextAlign.center,
            style: VText.body.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
  }
}

class SleepNightHero extends StatelessWidget {
  const SleepNightHero({super.key, required this.data});

  final NightSleepData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final summary = data.summary;
    final start = summary.startMs.toInt();
    final end = summary.endMs.toInt();
    return Container(
      decoration: SleepStyle.hero(colors),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 500;
          final veryCompact = constraints.maxWidth < 275;
          final ringSize = veryCompact
              ? 82.0
              : compact
              ? 98.0
              : 126.0;
          final ring = SizedBox(
            width: ringSize,
            height: ringSize,
            child: CustomPaint(
              painter: SleepScorePainter(
                score: summary.score.toInt(),
                colors: colors,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${summary.score}',
                      style: VText.num.copyWith(
                        fontSize: veryCompact
                            ? 25
                            : compact
                            ? 29
                            : 38,
                        color: colors.ink,
                      ),
                    ),
                    Text(
                      l10n.sleepScore,
                      style: VText.label.copyWith(
                        fontSize: veryCompact
                            ? 7.5
                            : compact
                            ? 8
                            : 9,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          final copy = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: colors.mintInk,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: colors.mintInk.withValues(alpha: 0.18),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        l10n.sleepRecoveryLabel(summary.score.toInt()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: VText.meta.copyWith(
                          color: colors.ink2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  l10n.sleepDurationText(summary.totalMinutes.toInt()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VText.num.copyWith(
                    fontSize: veryCompact
                        ? 30
                        : compact
                        ? 35
                        : 48,
                    color: colors.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 5,
                  children: [
                    _HeroMeta(
                      icon: Icons.bedtime_outlined,
                      text: l10n.bedAt(
                        clock(DateTime.fromMillisecondsSinceEpoch(start)),
                      ),
                    ),
                    _HeroMeta(
                      icon: Icons.wb_sunny_outlined,
                      text: l10n.wakeAt(
                        clock(DateTime.fromMillisecondsSinceEpoch(end)),
                      ),
                    ),
                    _HeroMeta(
                      icon: Icons.nights_stay_outlined,
                      text: '${data.awakenings}${l10n.wakesShort}',
                    ),
                  ],
                ),
              ],
            ),
          );
          if (compact) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ring,
                SizedBox(width: veryCompact ? 11 : 16),
                copy,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [ring, const SizedBox(width: 22), copy],
          );
        },
      ),
    );
  }
}

class SleepPeriodHero extends StatelessWidget {
  const SleepPeriodHero({
    super.key,
    required this.period,
    required this.rangeLabel,
  });

  final SleepPeriodData period;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    return Container(
      decoration: SleepStyle.hero(colors),
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 300;
          final badgeSize = compact ? 72.0 : 92.0;
          return Row(
            children: [
              Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  color: colors.purple,
                  borderRadius: BorderRadius.circular(compact ? 24 : 30),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${period.nights}',
                      style: VText.num.copyWith(
                        fontSize: compact ? 28 : 34,
                        color: colors.purpleInk,
                      ),
                    ),
                    Text(
                      l10n.nightsShort.trim(),
                      style: VText.label.copyWith(
                        fontSize: compact ? 8 : 9,
                        color: colors.purpleInk,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: compact ? 13 : 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$rangeLabel · ${l10n.averageSleep}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VText.meta.copyWith(color: colors.ink2),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.sleepDurationText(period.avgTotal.round()),
                      style: VText.num.copyWith(
                        fontSize: compact ? 32 : 40,
                        color: colors.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(period.deepShare * 100).round()}% ${l10n.deepSleepShare}',
                      style: VText.meta.copyWith(color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SleepNightChartCard extends StatelessWidget {
  const SleepNightChartCard({super.key, required this.data});

  final NightSleepData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final start = DateTime.fromMillisecondsSinceEpoch(
      data.summary.startMs.toInt(),
    );
    final end = DateTime.fromMillisecondsSinceEpoch(data.summary.endMs.toInt());
    final material = MaterialLocalizations.of(context);
    return Container(
      decoration: SleepStyle.card(colors),
      padding: SleepStyle.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(
            title: l10n.nightRhythm,
            subtitle: l10n.nightRhythmSubtitle,
            trailing:
                '${clock(start)} — ${clock(end)}\n'
                '${material.formatShortMonthDay(start)}',
          ),
          const SizedBox(height: 14),
          Semantics(
            label: '${l10n.nightRhythm}. ${l10n.chartHint}',
            child: SizedBox(
              height: SleepStyle.chartHeight,
              child: CustomPaint(
                painter: SleepChartPainter(
                  night: data,
                  l10n: l10n,
                  colors: colors,
                  startLabel: clock(start),
                  endLabel: clock(end),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SleepCompositionCard extends StatelessWidget {
  const SleepCompositionCard({super.key, required this.data});

  final NightSleepData data;

  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    return _CompositionCard(
      title: AppLocalizations.of(context).stageComposition,
      subtitle: AppLocalizations.of(context).stageCompositionSubtitle,
      values: [
        (SleepStageKind.awake, summary.awakeMinutes.toDouble()),
        (SleepStageKind.rem, summary.remMinutes.toDouble()),
        (SleepStageKind.light, summary.lightMinutes.toDouble()),
        (SleepStageKind.deep, summary.deepMinutes.toDouble()),
      ],
      footer: [
        (
          AppLocalizations.of(context).longestSleep,
          AppLocalizations.of(context).sleepDurationText(data.longestSleepBand),
        ),
        if (data.detail.breathing != null)
          (
            AppLocalizations.of(context).breathing,
            '${data.detail.breathing!.toStringAsFixed(1)} '
                '${AppLocalizations.of(context).breathsPerMinute}',
          ),
      ],
    );
  }
}

class SleepPeriodCompositionCard extends StatelessWidget {
  const SleepPeriodCompositionCard({super.key, required this.period});

  final SleepPeriodData period;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _CompositionCard(
      title: l10n.stageComposition,
      subtitle: l10n.stageCompositionSubtitle,
      values: [
        (SleepStageKind.awake, period.avgAwake),
        (SleepStageKind.rem, period.avgRem),
        (SleepStageKind.light, period.avgLight),
        (SleepStageKind.deep, period.avgDeep),
      ],
      footer: [
        (l10n.totalSleep, l10n.sleepDurationText(period.avgTotal.round())),
      ],
    );
  }
}

class _CompositionCard extends StatelessWidget {
  const _CompositionCard({
    required this.title,
    required this.subtitle,
    required this.values,
    required this.footer,
  });

  final String title;
  final String subtitle;
  final List<(SleepStageKind, double)> values;
  final List<(String, String)> footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final total = values.fold<double>(0, (sum, item) => sum + item.$2);
    final deep = values
        .where((item) => item.$1 == SleepStageKind.deep)
        .fold<double>(0, (sum, item) => sum + item.$2);
    return Container(
      decoration: SleepStyle.card(colors),
      padding: SleepStyle.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(title: title, subtitle: subtitle),
          const SizedBox(height: 15),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${total <= 0 ? 0 : (deep / total * 100).round()}%',
                style: VText.num.copyWith(fontSize: 34, color: colors.ink),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  l10n.deepSleepShare,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: VText.label.copyWith(
                    fontSize: 10,
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  for (final item in values)
                    if (item.$2 > 0)
                      Expanded(
                        flex: math.max(1, (item.$2 * 10).round()),
                        child: Container(
                          margin: const EdgeInsets.only(right: 2),
                          color: SleepStyle.stageColor(item.$1),
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 13),
          for (final item in values)
            _StageValueRow(
              kind: item.$1,
              minutes: item.$2,
              percentage: total <= 0 ? 0 : item.$2 / total,
            ),
          if (footer.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < footer.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: SleepStyle.inset(colors),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            footer[i].$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VText.label.copyWith(
                              fontSize: 9,
                              color: colors.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            footer[i].$2,
                            style: VText.h3.copyWith(color: colors.ink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class SleepTrendCard extends StatefulWidget {
  const SleepTrendCard({super.key, required this.period});

  final SleepPeriodData period;

  @override
  State<SleepTrendCard> createState() => _SleepTrendCardState();
}

class _SleepTrendCardState extends State<SleepTrendCard> {
  int? _selected;

  @override
  void didUpdateWidget(covariant SleepTrendCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final points = widget.period.trend;
    final selected = _selected == null || _selected! >= points.length
        ? null
        : points[_selected!];
    final peak = points.fold<double>(
      0,
      (max, point) => math.max(max, point.totalMinutes),
    );
    final scale = math.max(480.0, peak * 1.12);
    final material = MaterialLocalizations.of(context);
    return Container(
      decoration: SleepStyle.card(colors),
      padding: SleepStyle.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(
            title: l10n.sleepTrend,
            subtitle: _trendSubtitle(points),
            trailing: l10n.sleepDurationText(widget.period.avgTotal.round()),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 186,
            child: Stack(
              children: [
                Positioned(
                  top: 6 + (1 - 450 / scale) * 150,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 1,
                    color: colors.purple.withValues(alpha: 0.26),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < points.length; i++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: points.length > 10 ? 0.5 : 3,
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _selected = i),
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: points[i].hasData
                                      ? (points[i].totalMinutes / scale).clamp(
                                          0.05,
                                          1,
                                        )
                                      : 0.025,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: points[i].hasData
                                          ? null
                                          : colors.muted.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(
                                        points.length > 10 ? 4 : 9,
                                      ),
                                      border: _selected == i
                                          ? Border.all(
                                              color: colors.purpleInk,
                                              width: 1.5,
                                            )
                                          : null,
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: points[i].hasData
                                        ? Column(
                                            children: [
                                              Expanded(
                                                flex: math.max(
                                                  1,
                                                  points[i].lightMinutes
                                                      .round(),
                                                ),
                                                child: Container(
                                                  color: SleepStyle.light,
                                                ),
                                              ),
                                              Expanded(
                                                flex: math.max(
                                                  1,
                                                  points[i].remMinutes.round(),
                                                ),
                                                child: Container(
                                                  margin: const EdgeInsets.only(
                                                    bottom: 1,
                                                  ),
                                                  color: SleepStyle.rem,
                                                ),
                                              ),
                                              Expanded(
                                                flex: math.max(
                                                  1,
                                                  points[i].deepMinutes.round(),
                                                ),
                                                child: Container(
                                                  color: SleepStyle.deep,
                                                ),
                                              ),
                                            ],
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Row(
                    children: [
                      Text(
                        material.formatShortMonthDay(points.first.date),
                        style: VText.label.copyWith(
                          fontSize: 8.5,
                          color: colors.muted,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        material.formatShortMonthDay(points.last.date),
                        style: VText.label.copyWith(
                          fontSize: 8.5,
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: selected == null
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey(selected.date),
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: SleepStyle.inset(colors),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            material.formatMediumDate(selected.date),
                            style: VText.meta.copyWith(color: colors.ink2),
                          ),
                        ),
                        Text(
                          selected.hasData
                              ? l10n.sleepDurationText(
                                  selected.totalMinutes.round(),
                                )
                              : l10n.noTrendData,
                          style: VText.h3.copyWith(color: colors.ink),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _trendSubtitle(List<SleepTrendPoint> points) {
    if (points.isEmpty) return '';
    final l10n = AppLocalizations.of(context);
    return l10n.sleepRangeName(widget.period.rangeIndex);
  }
}

class SleepHealthCard extends StatelessWidget {
  const SleepHealthCard({super.key, required this.data});

  final NightSleepData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final detail = data.detail;
    final hrv = detail.sleepHrvAvg;
    final min = detail.sleepHrvMinBaseline;
    final max = detail.sleepHrvMaxBaseline;
    final delta = detail.sleepHrvDayToBaseline;
    return Container(
      decoration: SleepStyle.card(colors),
      padding: SleepStyle.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(
            title: l10n.nightHrv,
            subtitle: l10n.stageCompositionSubtitle,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              _MetricTile(
                label: l10n.average,
                value: hrv == null ? '--' : '${hrv.round()} ms',
              ),
              _MetricTile(
                label: l10n.personalBaseline,
                value: min == null || max == null
                    ? '--'
                    : '${min.round()}–${max.round()} ms',
              ),
              _MetricTile(
                label: l10n.vsBaseline,
                value: delta == null
                    ? '--'
                    : '${delta >= 0 ? '+' : ''}${delta.round()} ms',
              ),
              if (detail.breathing != null)
                _MetricTile(
                  label: l10n.breathing,
                  value:
                      '${detail.breathing!.toStringAsFixed(1)} ${l10n.breathsPerMinute}',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class SleepApneaCard extends StatelessWidget {
  const SleepApneaCard({
    super.key,
    required this.records,
    required this.loading,
  });

  final List<ApneaRecord> records;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    final risk = records.isEmpty
        ? null
        : records
              .map((record) => record.level.toInt())
              .reduce((a, b) => a > b ? a : b);
    final high = risk != null && risk >= 2;
    final label = risk == null
        ? l10n.noApneaRisk
        : risk >= 3
        ? l10n.highRisk
        : risk >= 2
        ? l10n.mediumRisk
        : risk >= 1
        ? l10n.lowRisk
        : l10n.noApneaRisk;
    return Container(
      decoration: SleepStyle.card(colors),
      padding: SleepStyle.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHeader(
            title: l10n.sleepApnea,
            subtitle: records.isEmpty ? l10n.noApneaRecords : null,
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else if (records.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: high ? colors.tintPeach : colors.tintGreen,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    high ? Icons.warning_amber_rounded : Icons.air_rounded,
                    color: high ? colors.warnInk : colors.greenInk,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: VText.h3.copyWith(color: colors.ink)),
                      const SizedBox(height: 3),
                      Text(
                        '${records.length}${l10n.recordsShort} · '
                        '${l10n.maxLevel} $risk',
                        style: VText.meta.copyWith(color: colors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: VText.h2.copyWith(color: colors.ink)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: VText.label.copyWith(
                    fontSize: 10,
                    height: 1.45,
                    color: colors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          Text(
            trailing!,
            textAlign: TextAlign.end,
            style: VText.label.copyWith(
              fontSize: 9.5,
              height: 1.35,
              color: colors.muted,
            ),
          ),
        ],
      ],
    );
  }
}

class _HeroMeta extends StatelessWidget {
  const _HeroMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: colors.muted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: VText.label.copyWith(fontSize: 9.5, color: colors.ink2),
          ),
        ),
      ],
    );
  }
}

class _StageValueRow extends StatelessWidget {
  const _StageValueRow({
    required this.kind,
    required this.minutes,
    required this.percentage,
  });

  final SleepStageKind kind;
  final double minutes;
  final double percentage;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 21,
            decoration: BoxDecoration(
              color: SleepStyle.stageColor(kind),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              l10n.sleepStageName(kind),
              style: VText.meta.copyWith(color: colors.ink2),
            ),
          ),
          Text(
            l10n.sleepDurationText(minutes.round()),
            style: VText.meta.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 34,
            child: Text(
              '${(percentage * 100).round()}%',
              textAlign: TextAlign.end,
              style: VText.label.copyWith(fontSize: 9, color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.v;
    return SizedBox(
      width: 138,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: SleepStyle.inset(colors),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(fontSize: 9, color: colors.muted),
            ),
            const SizedBox(height: 4),
            Text(value, style: VText.h3.copyWith(color: colors.ink)),
          ],
        ),
      ),
    );
  }
}
