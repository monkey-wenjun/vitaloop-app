import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 心律（房颤 / 早搏筛查）。以前是首页点出来的弹层，只能翻 20 条也没有分布，
/// 独立成页后展示全部记录、按结果类型给出真实占比。
class HeartRhythmScreen extends StatefulWidget {
  const HeartRhythmScreen({super.key, required this.records});

  final List<ArrhythmiaEntry> records;

  @override
  State<HeartRhythmScreen> createState() => _HeartRhythmScreenState();
}

class _HeartRhythmScreenState extends State<HeartRhythmScreen> {
  bool _showAllRecords = false;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final records = widget.records;
    final counts = <int, int>{};
    for (final e in records) {
      counts.update(e.resultType.toInt(), (n) => n + 1, ifAbsent: () => 1);
    }
    final normal = counts[1] ?? 0;
    final attention = records.length - normal;
    final latest = records.isNotEmpty ? records.first.resultType.toInt() : null;
    final recent = records;
    final timeline = records.reversed.toList();

    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(
              title: '心律',
              icon: Icons.monitor_heart_rounded,
              iconColor: v.heartInk,
            ),
            if (records.isEmpty)
              const VEmpty(
                title: '暂无筛查记录',
                subtitle: '在手表上做一次心律筛查（房颤 / 早搏检测），同步后结果会显示在这里。',
                icon: Icons.monitor_heart_rounded,
              )
            else ...[
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          arrhythmiaLabel(latest!),
                          style: VText.h1.copyWith(
                            fontSize: 30,
                            color: _ink(v, latest),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '共 ${records.length} 次',
                          style: VText.label.copyWith(color: v.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: VStat(
                            label: '正常窦性',
                            value: '$normal',
                            unit: '次',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: VStat(
                            label: '需关注',
                            value: '$attention',
                            unit: '次',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: VStat(
                            label: '最近检测',
                            value: relativeDay(
                              DateTime.fromMillisecondsSinceEpoch(
                                records.first.timestampMs,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '筛查时间线'),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('结果趋势', style: VText.h3.copyWith(color: v.ink)),
                        const Spacer(),
                        Text(
                          '${records.length} 次 · 左旧右新',
                          style: VText.label.copyWith(
                            fontSize: 9.5,
                            color: v.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (timeline.length >= 2)
                      HeartRateCurve(
                        points: [
                          for (final e in timeline)
                            Offset(
                              e.timestampMs.toDouble(),
                              _severity(e.resultType.toInt()).toDouble(),
                            ),
                        ],
                        height: 96,
                        color: v.heartInk,
                        valueFormat: (value) => _severityLabel(value.round()),
                        xLabel: (value) {
                          final d = DateTime.fromMillisecondsSinceEpoch(
                            value.round(),
                          );
                          return '${d.month}/${d.day} ${clock(d)}';
                        },
                      )
                    else
                      Text(
                        '再完成一次筛查后即可画出趋势。',
                        style: VText.label.copyWith(color: v.muted),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _legend(v.greenInk, '正常'),
                        const SizedBox(width: 12),
                        _legend(v.warnInk, '需关注'),
                        const SizedBox(width: 12),
                        _legend(v.danger, '疑似房颤'),
                        const Spacer(),
                        Text(
                          '点按曲线可查看日期和结果',
                          style: VText.label.copyWith(
                            fontSize: 9.5,
                            color: v.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '结果分布'),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final type in const [1, 2, 3, 4, 5])
                      if ((counts[type] ?? 0) > 0)
                        _bar(type, counts[type]!, records.length, v),
                    const SizedBox(height: 4),
                    Text(
                      '占比按全部筛查记录统计，同一天多次检测会分别计入。',
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: v.muted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              VSectionHead(
                title: '全部记录',
                trailing: _showAllRecords ? '收起' : '${recent.length} 条 · 展开',
                onTrailing: () =>
                    setState(() => _showAllRecords = !_showAllRecords),
              ),
              if (_showAllRecords)
                VCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    children: [
                      for (final e in recent.take(100)) _row(e, v),
                      if (recent.length > 100)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            '仅显示最近 100 条，共 ${recent.length} 条记录',
                            style: VText.label.copyWith(
                              fontSize: 9.5,
                              color: v.muted,
                            ),
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
                '房颤 / 早搏筛查来自手表的脉搏波分析，仅作参考，不能替代医疗诊断；'
                '单次结果异常不等于患病，若反复出现心悸、胸闷或头晕请咨询医生。',
                style: VText.label.copyWith(color: v.muted, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ArrhythmiaEntry e, VColors v) => VRowItem(
    icon: e.resultType == 1
        ? Icons.check_circle_rounded
        : Icons.monitor_heart_rounded,
    iconBackground: _tint(v, e.resultType.toInt()),
    iconColor: _ink(v, e.resultType.toInt()),
    title: arrhythmiaLabel(e.resultType.toInt()),
    subtitle:
        '${relativeDay(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} '
        '${clock(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))}',
  );

  Widget _legend(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: VText.label.copyWith(fontSize: 9.5)),
    ],
  );

  int _severity(int type) => switch (type) {
    2 || 5 => 2,
    3 || 4 => 3,
    _ => 1,
  };

  String _severityLabel(int severity) => switch (severity) {
    2 => '需关注',
    3 => '疑似房颤',
    _ => '正常',
  };

  Widget _bar(int type, int count, int total, VColors v) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(
            arrhythmiaLabel(type),
            style: VText.label.copyWith(color: v.ink2),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: count / total,
              minHeight: 7,
              backgroundColor: v.tintGrey,
              valueColor: AlwaysStoppedAnimation(_ink(v, type)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          child: Text(
            '$count 次',
            textAlign: TextAlign.right,
            style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
          ),
        ),
      ],
    ),
  );

  Color _ink(VColors v, int type) => switch (type) {
    1 => v.greenInk,
    2 || 5 => v.warnInk,
    3 || 4 => v.danger,
    _ => v.ink2,
  };

  Color _tint(VColors v, int type) => switch (type) {
    1 => v.tintGreen,
    2 || 5 => v.tintPeach,
    3 || 4 => v.tintHeart,
    _ => v.tintGrey,
  };
}
