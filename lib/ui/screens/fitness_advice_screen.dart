import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

/// 运动建议：旧版服务端的 AI 建议页在本地用准备度、HRV、睡眠、压力与训练量生成。
/// 不依赖云端是否登录，也不上传额外的健康数据。
class FitnessAdviceScreen extends StatefulWidget {
  const FitnessAdviceScreen({super.key});

  @override
  State<FitnessAdviceScreen> createState() => _FitnessAdviceScreenState();
}

class _FitnessAdviceScreenState extends State<FitnessAdviceScreen> {
  int _range = 0;
  late Future<_AdviceView> _future = _load(7);

  static const _rangeDays = [7, 30];
  static const _rangeLabels = ['近 7 天', '近 30 天'];

  Future<_AdviceView> _load(int days) async {
    final results = await Future.wait([
      VitaloopApi.readinessDetail(),
      VitaloopApi.sleep(),
      VitaloopApi.metricSeries('hrv', days),
      VitaloopApi.metricSeries('sleep', days),
      VitaloopApi.metricSeries('stress', days),
      VitaloopApi.metricSeries('resting_hr', days),
      VitaloopApi.workouts(limit: 500),
    ]);
    final readiness = results[0] as ReadinessDetail;
    final sleep = results[1] as SleepSummary?;
    final hrv = results[2] as List<DailyPoint>;
    final sleepSeries = results[3] as List<DailyPoint>;
    final stress = results[4] as List<DailyPoint>;
    final resting = results[5] as List<DailyPoint>;
    final workouts = results[6] as List<WorkoutSummary>;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final recent = workouts.where((w) => w.startMs.toInt() >= cutoff).toList();
    return _AdviceView.from(
      days: days,
      readiness: readiness,
      sleep: sleep,
      hrv: hrv,
      sleepSeries: sleepSeries,
      stress: stress,
      resting: resting,
      workouts: recent,
    );
  }

  void _setRange(int index) {
    if (index == _range) return;
    setState(() {
      _range = index;
      _future = _load(_rangeDays[index]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<_AdviceView>(
          future: _future,
          builder: (context, snapshot) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                const VDetailHeader(
                  title: 'AI 运动建议',
                  icon: Icons.auto_awesome_rounded,
                ),
                VSegmented(
                  options: _rangeLabels,
                  index: _range,
                  onChanged: _setRange,
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (snapshot.hasError)
                  VCard(
                    child: Text(
                      '加载失败：${snapshot.error}',
                      style: VText.body.copyWith(color: v.danger),
                    ),
                  )
                else if (snapshot.data != null)
                  _body(snapshot.data!),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(_AdviceView advice) {
    final v = context.v;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VCard(
          background: v.tintBlue,
          foreground: v.blueInk,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 18, color: v.blueInk),
                  const SizedBox(width: 7),
                  Text(
                    advice.headline,
                    style: VText.h3.copyWith(color: v.blueInk, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                advice.summary,
                style: VText.body.copyWith(color: v.blueInk, height: 1.55),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: VStat(
                      label: '训练次数',
                      value: '${advice.workoutCount}',
                      unit: ' 次',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '总距离',
                      value: advice.totalKm.toStringAsFixed(1),
                      unit: ' km',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(label: '总负荷', value: '${advice.totalLoad}'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 11),
        _section('运动分析', advice.workoutAnalysis, v),
        _section('健康指标', advice.healthAnalysis, v),
        _section('恢复状态', _recoveryText(advice), v),
        if (advice.risks.isNotEmpty)
          _section('关注提醒', '', v, highlight: true, items: advice.risks),
        if (advice.recommendations.isNotEmpty) ...[
          const VSectionHead(title: '运动建议'),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in advice.recommendations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: v.blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item,
                            style: VText.body.copyWith(
                              color: v.ink2,
                              height: 1.5,
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
        const VSectionHead(title: '说明'),
        VCard(
          background: v.tintGrey,
          child: Text(
            '建议由本机已有的准备度、HRV、睡眠、压力与训练记录生成，仅用于安排训练强度，'
            '不构成医疗诊断。出现胸痛、明显心悸或头晕时请停止运动并咨询医生。',
            style: VText.label.copyWith(color: v.muted, height: 1.6),
          ),
        ),
      ],
    );
  }

  /// 逐句翻译成目标语言后再按 locale 标点拼接，避免把带汉字的片段塞进占位符
  /// 触发整段中文回落（见 readiness_screen._advice 同款做法）。
  String _recoveryText(_AdviceView a) {
    final languageCode = Localizations.localeOf(context).languageCode;
    String translate(String source) =>
        UiTranslations.instance.translate(source, languageCode: languageCode);
    final sleepBase = a.sleepHours > 0
        ? translate('睡眠平均 ${a.sleepHours.toStringAsFixed(1)} 小时')
        : translate('暂无睡眠数据');
    final parts = <String>[
      a.hasLastNight
          ? '$sleepBase${translate('，最近一晚 ${a.lastNightHours.toStringAsFixed(1)} 小时')}'
          : sleepBase,
    ];
    if (a.recoveryMinutes > 0) {
      parts.add(
        translate('当天运动累计建议恢复 ${_AdviceView._recoveryLabel(a.recoveryMinutes)}'),
      );
    }
    final sign = a.trend >= 0 ? '+' : '';
    parts.add(translate('准备度较昨天 $sign${a.trend}'));
    final separator = languageCode == 'zh' ? '；' : '; ';
    final period = languageCode == 'zh' ? '。' : '.';
    return '${parts.join(separator)}$period';
  }

  Widget _section(
    String title,
    String text,
    VColors v, {
    bool highlight = false,
    List<String>? items,
  }) {
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: VText.h3.copyWith(
              color: highlight ? v.danger : v.ink,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 7),
          if (items != null)
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        '•',
                        style: VText.body.copyWith(
                          color: v.danger,
                          height: 1.55,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        items[i],
                        style: VText.body.copyWith(
                          color: v.danger,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ),
              )
          else
            Text(
              text,
              style: VText.body.copyWith(
                color: highlight ? v.danger : v.ink2,
                height: 1.55,
              ),
            ),
        ],
      ),
    );
  }
}

class _AdviceView {
  _AdviceView({
    required this.headline,
    required this.summary,
    required this.workoutAnalysis,
    required this.healthAnalysis,
    required this.sleepHours,
    required this.lastNightHours,
    required this.hasLastNight,
    required this.recoveryMinutes,
    required this.trend,
    required this.risks,
    required this.recommendations,
    required this.workoutCount,
    required this.totalKm,
    required this.totalLoad,
  });

  final String headline;
  final String summary;
  final String workoutAnalysis;
  final String healthAnalysis;
  final double sleepHours;
  final double lastNightHours;
  final bool hasLastNight;
  final int recoveryMinutes;
  final double trend;
  final List<String> risks;
  final List<String> recommendations;
  final int workoutCount;
  final double totalKm;
  final int totalLoad;

  factory _AdviceView.from({
    required int days,
    required ReadinessDetail readiness,
    required SleepSummary? sleep,
    required List<DailyPoint> hrv,
    required List<DailyPoint> sleepSeries,
    required List<DailyPoint> stress,
    required List<DailyPoint> resting,
    required List<WorkoutSummary> workouts,
  }) {
    final score = readiness.score.total.toInt();
    final hrvAvg = _avg(hrv);
    final sleepAvg = _avg(sleepSeries);
    final stressAvg = _avg(stress);
    final restingAvg = _avg(resting);
    final totalKm =
        workouts.fold<double>(0, (sum, w) => sum + w.distanceM) / 1000;
    final totalMinutes =
        workouts.fold<int>(0, (sum, w) => sum + w.durationSec.toInt()) ~/ 60;
    final totalLoad = workouts.fold<int>(0, (sum, w) => sum + w.load.toInt());
    final totalCalories = workouts.fold<int>(
      0,
      (sum, w) => sum + w.calories.toInt(),
    );
    final avgHr = workouts.isEmpty
        ? 0
        : workouts.fold<int>(0, (sum, w) => sum + w.avgHr.toInt()) ~/
              workouts.length;
    final longest = workouts.isEmpty
        ? 0
        : workouts.map((w) => w.distanceM).reduce(math.max).toDouble() / 1000;
    final hrvTrend = _trend(hrv);
    final sleepHours = sleepAvg > 0 ? sleepAvg / 60 : 0.0;
    final risks = <String>[];
    if (score < 60) risks.add('准备度 $score，今天不建议安排强度课。');
    if (sleepHours > 0 && sleepHours < 6.5) {
      risks.add('平均睡眠 ${sleepHours.toStringAsFixed(1)} 小时，低于恢复所需。');
    }
    if (stressAvg > 70) risks.add('平均压力 ${stressAvg.round()}，偏高。');
    if (hrvTrend < -0.12) {
      risks.add('HRV 较前一段时间下降 ${(-hrvTrend * 100).round()}%。');
    }
    if (readiness.score.recoveryScore > 0 &&
        readiness.score.recoveryScore < 60) {
      risks.add(
        '当天训练累计建议恢复 ${_recoveryLabel(readiness.score.recoveryMinutes.toInt())}，'
        '恢复压力偏高。',
      );
    }

    final recommendations = <String>[];
    if (score >= 80) {
      recommendations.add('可安排 1 次质量课（节奏跑或短间歇），其余以轻松有氧为主。');
    } else if (score >= 60) {
      recommendations.add('以有氧基础为主，强度课之间至少间隔 48 小时。');
    } else {
      recommendations.add('今天只做 20–30 分钟恢复走或慢跑，心率控制在二区以内。');
    }
    if (totalLoad > days * 90) {
      recommendations.add('本周期训练负荷偏高，下一周总量建议下调 15%–20%。');
    }
    if (sleepHours > 0 && sleepHours < 7) {
      recommendations.add('今晚比平时提前 30 分钟睡，连续 3 晚补足睡眠。');
    }
    if (stressAvg > 60) {
      recommendations.add('训练后加 5 分钟慢呼吸或拉伸，先把压力降下来。');
    }
    if (hrvAvg > 0 && hrvTrend < 0) {
      recommendations.add('HRV 走低时优先轻松跑；连续两天低于基线就取消强度课。');
    }
    if (workouts.isEmpty) {
      recommendations.add('还没有本周期训练记录，先从 20 分钟轻松跑开始建立节奏。');
    }
    if (readiness.score.recoveryScore > 0 &&
        readiness.score.recoveryScore < 60) {
      recommendations.add('今天不再叠加高强度训练，优先睡眠、补水和轻松活动。');
    }

    final headline = score >= 80
        ? '状态适合训练'
        : score >= 60
        ? '保持有氧节奏'
        : '优先恢复';
    final summary =
        '准备度 $score 分（${readiness.score.level}），本周期完成 ${workouts.length} 次训练，'
        '共 ${totalKm.toStringAsFixed(1)} km、$totalMinutes 分钟。'
        '${readiness.score.advice}';
    final workoutAnalysis = workouts.isEmpty
        ? '本周期没有运动记录。'
        : '共 ${workouts.length} 次，平均每次 ${(totalKm / workouts.length).toStringAsFixed(1)} km，'
              '平均心率 ${avgHr > 0 ? '$avgHr bpm' : '未记录'}，'
              '累计消耗 ${totalCalories > 0 ? '$totalCalories kcal' : '未记录'}；'
              '最长一次 ${longest.toStringAsFixed(1)} km。';
    final healthAnalysis =
        'HRV 平均 ${hrvAvg > 0 ? '${hrvAvg.round()} ms' : '暂无数据'}，'
        '静息心率 ${restingAvg > 0 ? '${restingAvg.round()} bpm' : '暂无数据'}，'
        '压力 ${stressAvg > 0 ? '${stressAvg.round()}' : '暂无数据'}。';
    return _AdviceView(
      headline: headline,
      summary: summary,
      workoutAnalysis: workoutAnalysis,
      healthAnalysis: healthAnalysis,
      sleepHours: sleepHours,
      lastNightHours: sleep == null ? 0 : sleep.totalMinutes / 60,
      hasLastNight: sleep != null,
      recoveryMinutes: readiness.score.recoveryMinutes.toInt(),
      trend: readiness.score.trend.toDouble(),
      risks: risks,
      recommendations: recommendations,
      workoutCount: workouts.length,
      totalKm: totalKm,
      totalLoad: totalLoad,
    );
  }

  static double _avg(List<DailyPoint> points) {
    final values = points
        .map((p) => p.value)
        .where((v) => v.isFinite && v > 0)
        .toList();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _trend(List<DailyPoint> points) {
    final values = points
        .map((p) => p.value)
        .where((v) => v.isFinite && v > 0)
        .toList();
    if (values.length < 4) return 0;
    final half = values.length ~/ 2;
    final old = values.sublist(0, half).reduce((a, b) => a + b) / half;
    final recentValues = values.sublist(half);
    final recent = recentValues.reduce((a, b) => a + b) / recentValues.length;
    if (old <= 0) return 0;
    return (recent - old) / old;
  }

  static String _recoveryLabel(int minutes) {
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
    }
    return '$minutes 分钟';
  }
}
