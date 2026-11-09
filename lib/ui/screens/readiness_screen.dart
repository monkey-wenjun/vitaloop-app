import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';

import '../../data/api.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/range_buckets.dart';
import '../components.dart';
import '../nav.dart';
import 'metric_detail_screen.dart';

class ReadinessScreen extends StatefulWidget {
  const ReadinessScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ReadinessScreen> createState() => _ReadinessScreenState();
}

class _ReadinessScreenState extends State<ReadinessScreen> {
  late Future<ReadinessDetail> _future = VitaloopApi.readinessDetail();
  Timer? _timer;
  int _range = 0;
  List<DailyPoint>? _rangeSeries;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(hours: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _future = VitaloopApi.readinessDetail();
      _rangeSeries = null;
      if (_range > 0) _loadRange(_range);
    });
  }

  void _setRange(int index) {
    if (index == _range) return;
    setState(() {
      _range = index;
      _rangeSeries = null;
    });
    if (index > 0) _loadRange(index);
  }

  void _loadRange(int index) {
    final days = rangeDays[index];
    VitaloopApi.readinessSeries(days).then((points) {
      if (!mounted || _range != index) return;
      setState(() {
        _rangeSeries = [
          for (final p in points)
            if (p.value > 0) p,
        ];
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<ReadinessDetail>(
          future: _future,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            final dataDay = detail == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    detail.dateEpochDay * 86400000,
                  );
            final now = DateTime.now();
            final isToday =
                dataDay != null &&
                dataDay.year == now.year &&
                dataDay.month == now.month &&
                dataDay.day == now.day;
            final latestLabel = isToday ? '今天' : '最近';
            final hasData = detail != null && detail.score.total > 0;
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                VDetailHeader(title: '准备度', onMore: () => _showHelp(context)),
                VSegmented(
                  options: rangeLabels,
                  index: _range,
                  onChanged: _setRange,
                  margin: const EdgeInsets.only(top: 2, bottom: 12),
                ),
                if (_range > 0)
                  _rangeBody()
                else if (detail == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 120),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  VCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ReadinessRing(
                          score: detail.score.total,
                          level: detail.score.level,
                          trend: detail.score.trend,
                          hasData: hasData,
                          size: 138,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              VChip(
                                text: hasData ? detail.score.advice : '等待数据',
                                background: hasData ? v.tintGreen : v.tintGrey,
                                foreground: hasData ? v.greenInk : v.ink2,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                hasData ? _advice(detail) : '还没有足够的 HRV、睡眠与静息心率数据。手表完成一次同步后，这里会按 7 天基线生成建议。',
                                style: VText.body.copyWith(
                                  color: v.ink2,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
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
                            Text(
                              '分数构成',
                              style: VText.h3.copyWith(color: v.ink),
                            ),
                            const Spacer(),
                            Text(
                              '加权 100%',
                              style: VText.label.copyWith(color: v.muted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _ZoneRow(
                          label: 'HRV',
                          weight: _effWeight(
                            detail,
                            detail.weights.hrv,
                            detail.score.hrvScore,
                          ),
                          score: detail.score.hrvScore,
                          color: const Color(0xFF4FB8A2),
                          metric: 'hrv',
                          state: widget.state,
                        ),
                        _ZoneRow(
                          label: '睡眠',
                          weight: _effWeight(
                            detail,
                            detail.weights.sleep,
                            detail.score.sleepScore,
                          ),
                          score: detail.score.sleepScore,
                          color: const Color(0xFF4FB8A2),
                          metric: 'sleep',
                        ),
                        _ZoneRow(
                          label: '静息心率',
                          weight: _effWeight(
                            detail,
                            detail.weights.rhr,
                            detail.score.rhrScore,
                          ),
                          score: detail.score.rhrScore,
                          color: const Color(0xFF3B63F0),
                          metric: 'resting_hr',
                        ),
                        _ZoneRow(
                          label: '腕温',
                          weight: _effWeight(
                            detail,
                            detail.weights.temp,
                            detail.score.tempScore,
                          ),
                          score: detail.score.tempScore,
                          color: const Color(0xFFE0A03A),
                          metric: 'skin_temp',
                        ),
                        _ZoneRow(
                          label: '压力',
                          weight: _effWeight(
                            detail,
                            detail.weights.stress,
                            detail.score.stressScore,
                          ),
                          score: detail.score.stressScore,
                          color: const Color(0xFF8C6BD8),
                          metric: 'stress',
                        ),
                        _ZoneRow(
                          label: '恢复',
                          weight: _effWeight(
                            detail,
                            detail.weights.recovery,
                            detail.score.recoveryScore,
                          ),
                          score: detail.score.recoveryScore,
                          color: const Color(0xFF4D9B72),
                        ),
                        if (detail.score.recoveryMinutes > 0)
                          Padding(
                            padding: const EdgeInsets.only(
                              left: 64,
                              top: 1,
                              bottom: 3,
                            ),
                            child: Text(
                              '当天运动累计建议恢复 ${_recoveryLabel(detail.score.recoveryMinutes.toInt())}',
                              style: VText.label.copyWith(
                                fontSize: 10,
                                color: v.muted,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          '每项先按 7 天基线归一化到 0–100，再按权重合成；当天多次运动的恢复时间累加。缺失项自动剔除并重新分配权重。',
                          style: VText.label.copyWith(
                            fontSize: 10,
                            color: v.muted,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  VCard(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              '近 7 天',
                              style: VText.h3.copyWith(color: v.ink),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 96,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (
                                var i = 0;
                                i < detail.history.length;
                                i++
                              ) ...[
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text(
                                        '${detail.history[i].total}',
                                        style: VText.label.copyWith(
                                          fontSize: 9.5,
                                          color: i == detail.history.length - 1
                                              ? v.blue
                                              : v.muted,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        height:
                                            8 +
                                            52 *
                                                (detail.history[i].total / 100),
                                        decoration: BoxDecoration(
                                          color: i == detail.history.length - 1
                                              ? v.blue
                                              : v.blueTrack,
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (i != detail.history.length - 1)
                                  const SizedBox(width: 7),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (var i = 0; i < detail.history.length; i++) ...[
                              Expanded(
                                child: Text(
                                  i == detail.history.length - 1
                                      ? latestLabel
                                      : weekday(
                                          DateTime.fromMillisecondsSinceEpoch(
                                            detail.history[i].dateEpochDay *
                                                86400000,
                                          ),
                                        ),
                                  textAlign: TextAlign.center,
                                  style: VText.label.copyWith(
                                    fontSize: 9,
                                    color: v.muted,
                                  ),
                                ),
                              ),
                              if (i != detail.history.length - 1)
                                const SizedBox(width: 7),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: VMini(
                          label: latestLabel,
                          value: '${detail.score.total}',
                          sub: '分',
                          background: v.green,
                          foreground: v.greenInk,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VMini(
                          label: '7 日均',
                          value: '${detail.weekAverage}',
                          sub: '分',
                          background: v.mint,
                          foreground: v.mintInk,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VMini(
                          label: '较前一日',
                          value: hasData
                              ? '${detail.score.trend >= 0 ? '+' : ''}${detail.score.trend}'
                              : '--',
                          sub: '分',
                          background: v.purple,
                          foreground: v.purpleInk,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 11),
                VCard(
                  background: v.tintGrey,
                  child: Text(
                    '准备度只用于训练强度建议，不构成医疗诊断。分数低于 60 时建议改为休息或低强度恢复。',
                    style: VText.label.copyWith(
                      fontSize: 10,
                      color: v.muted,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String get _rangeTitle => switch (_range) {
    1 => '近 7 天',
    2 => '近 30 天',
    3 => '近半年',
    _ => '近一年',
  };

  Widget _rangeBody() {
    final v = context.v;
    final series = _rangeSeries;
    if (series == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 120),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (series.isEmpty) {
      return VCard(
        child: Column(
          children: [
            Icon(Icons.hourglass_empty_rounded, size: 34, color: v.muted),
            const SizedBox(height: 10),
            Text('这段时间没有准备度数据', style: VText.h3.copyWith(color: v.ink)),
            const SizedBox(height: 6),
            Text(
              '手表同步 HRV、睡眠与静息心率后，会按${rangeLabels[_range]}汇总展示。',
              textAlign: TextAlign.center,
              style: VText.label.copyWith(color: v.muted, height: 1.5),
            ),
          ],
        ),
      );
    }
    final avg =
        series.fold<double>(0, (sum, p) => sum + p.value) / series.length;
    final peak = series.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final low = series.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    final buckets = bucketSeries(series, _range);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('平均准备度', style: VText.label.copyWith(color: v.muted)),
                  const Spacer(),
                  VChip(
                    text: '${series.length} 天',
                    background: v.tintBlue,
                    foreground: v.blueInk,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${avg.round()}',
                    style: VText.h1.copyWith(fontSize: 40, color: v.ink),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Text(
                      '分',
                      style: VText.meta.copyWith(
                        color: v.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: VStat(
                      label: '最高',
                      value: '${peak.round()}',
                      unit: '分',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '最低',
                      value: '${low.round()}',
                      unit: '分',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '最近',
                      value: '${series.last.value.round()}',
                      unit: '分',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        VCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
              const SizedBox(height: 12),
              VRangeLine(
                buckets: buckets,
                color: v.blue,
                unit: '分',
                valueFormat: (value) => value.round().toString(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  int _effWeight(ReadinessDetail detail, int weight, int score) {
    final present = [
      detail.weights.hrv,
      detail.weights.sleep,
      detail.weights.rhr,
      detail.weights.temp,
      detail.weights.stress,
      detail.weights.recovery,
    ];
    final scores = [
      detail.score.hrvScore,
      detail.score.sleepScore,
      detail.score.rhrScore,
      detail.score.tempScore,
      detail.score.stressScore,
      detail.score.recoveryScore,
    ];
    var sum = 0;
    for (var i = 0; i < present.length; i++) {
      if (scores[i] > 0) sum += present[i];
    }
    if (score <= 0 || sum == 0) return 0;
    return (weight * 100 / sum).round();
  }

  String _advice(ReadinessDetail detail) {
    final languageCode = Localizations.localeOf(context).languageCode;
    String translate(String source) =>
        UiTranslations.instance.translate(source, languageCode: languageCode);
    final parts = <String>[];
    if (detail.score.hrvScore >= 70) {
      parts.add(translate('HRV 高于 7 天基线'));
    } else {
      parts.add(translate('HRV 低于 7 天基线'));
    }
    if (detail.score.sleepScore >= 70) {
      parts.add(translate('睡眠充足'));
    } else {
      parts.add(translate('睡眠不足'));
    }
    if (detail.score.stressScore < 60) {
      parts.add(translate('压力偏高，今天把强度控制在 Z2'));
    } else {
      parts.add(translate('压力水平正常'));
    }
    if (detail.score.recoveryScore > 0 && detail.score.recoveryScore < 60) {
      parts.add(translate('当天训练累计恢复时间偏长'));
    }
    final separator = languageCode == 'zh' ? '；' : '; ';
    final period = languageCode == 'zh' ? '。' : '. ';
    return '${parts.join(separator)}$period'
        '${translate(detail.score.trend >= 0 ? '恢复趋势向好，保持当前节奏。' : '恢复略慢，注意补觉与补水。')}';
  }

  String _recoveryLabel(int minutes) {
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
    }
    return '$minutes 分钟';
  }

  void _showHelp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('准备度怎么算', style: VText.h2.copyWith(color: context.v.ink)),
            const SizedBox(height: 10),
            Text(
              '睡眠 80%，其余 HRV、静息心率、腕温、压力和当天恢复合计 20%。睡眠总时长大于 6 小时且深睡大于 2 小时为优秀；深睡 1 小时以内分数最高只有 30。',
              style: VText.body.copyWith(color: context.v.ink2),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    required this.label,
    required this.weight,
    required this.score,
    required this.color,
    this.metric,
    this.state,
  });

  final String label;
  final int weight;
  final int score;
  final Color color;
  final String? metric;
  final AppState? state;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: metric == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MetricDetailScreen(
                  metric: metric!,
                  title: label,
                  color: color,
                  state: state,
                ),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                label,
                style: VText.label.copyWith(
                  fontSize: 11,
                  color: v.ink2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(
              width: 62,
              child: Text(
                score <= 0 ? '未采集' : '$weight% · $score',
                style: VText.label.copyWith(fontSize: 10, color: v.muted),
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (score / 100).clamp(0, 1),
                  minHeight: 6,
                  backgroundColor: v.barTrack,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                score <= 0 ? '—' : '$score',
                textAlign: TextAlign.right,
                style: VText.label.copyWith(
                  fontSize: 11,
                  color: score <= 0 ? v.muted : v.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (metric != null)
              Icon(Icons.chevron_right_rounded, size: 15, color: v.muted),
          ],
        ),
      ),
    );
  }
}
