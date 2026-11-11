import 'dart:math' as math;

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
  int? _timelineIndex;

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
                      _timeline(v, timeline)
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

  /// 筛查结果是「正常 / 需关注 / 疑似房颤」三档分类，不是连续数值。
  /// 以前用折线把 1→2→3 连起来，等于凭空造出「逐渐恶化」的斜线和拐弯；
  /// 改成每场筛查一个圆点，只表达发生时间与结果档位。
  Widget _timeline(VColors v, List<ArrhythmiaEntry> timeline) {
    final selected = _timelineIndex != null && _timelineIndex! < timeline.length
        ? timeline[_timelineIndex!]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          child: selected == null
              ? Text(
                  '点按圆点查看日期和结果',
                  key: const ValueKey('hint'),
                  style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                )
              : Text(
                  '${relativeDay(DateTime.fromMillisecondsSinceEpoch(selected.timestampMs))} '
                  '${clock(DateTime.fromMillisecondsSinceEpoch(selected.timestampMs))} · '
                  '${arrhythmiaLabel(selected.resultType.toInt())}',
                  key: ValueKey(selected.timestampMs),
                  style: VText.label.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _ink(v, selected.resultType.toInt()),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) =>
                    _selectTimeline(d.localPosition.dx, width, timeline),
                onHorizontalDragStart: (d) =>
                    _selectTimeline(d.localPosition.dx, width, timeline),
                onHorizontalDragUpdate: (d) =>
                    _selectTimeline(d.localPosition.dx, width, timeline),
                child: CustomPaint(
                  painter: _RhythmTimelinePainter(
                    timeline: timeline,
                    grid: v.line,
                    selectedIndex: _timelineIndex,
                    colorFor: (type) => _ink(v, type),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _selectTimeline(
    double dx,
    double width,
    List<ArrhythmiaEntry> timeline,
  ) {
    if (timeline.isEmpty) return;
    const padX = 10.0;
    final usable = math.max(1.0, width - padX * 2);
    final fraction = ((dx - padX) / usable).clamp(0.0, 1.0);
    final first = timeline.first.timestampMs.toDouble();
    final span = math.max(1.0, timeline.last.timestampMs.toDouble() - first);
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < timeline.length; i++) {
      final ratio = (timeline[i].timestampMs.toDouble() - first) / span;
      final distance = (ratio - fraction).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (_timelineIndex != best) setState(() => _timelineIndex = best);
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

/// 分类结果的离散时间线：三档基线 + 每场筛查一个圆点，不做任何连线插值。
class _RhythmTimelinePainter extends CustomPainter {
  _RhythmTimelinePainter({
    required this.timeline,
    required this.grid,
    required this.selectedIndex,
    required this.colorFor,
  });

  final List<ArrhythmiaEntry> timeline;
  final Color grid;
  final int? selectedIndex;
  final Color Function(int resultType) colorFor;

  static const _padX = 10.0;
  static const _padY = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - _padX * 2);
    final height = math.max(1.0, size.height - _padY * 2);
    final bottom = _padY + height;

    final lanePaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var severity = 1; severity <= 3; severity++) {
      final y = _padY + (3 - severity) / 2 * height;
      canvas.drawLine(Offset(_padX, y), Offset(_padX + width, y), lanePaint);
    }

    final first = timeline.first.timestampMs.toDouble();
    final span = math.max(1.0, timeline.last.timestampMs.toDouble() - first);
    for (var i = 0; i < timeline.length; i++) {
      final entry = timeline[i];
      final severity = _severityOf(entry.resultType.toInt());
      final x = _padX + (entry.timestampMs.toDouble() - first) / span * width;
      final y = _padY + (3 - severity) / 2 * height;
      final selected = i == selectedIndex;
      // 底线到圆点的细茎：让孤立的筛查也能读出发生在时间轴的哪个位置。
      canvas.drawLine(
        Offset(x, bottom),
        Offset(x, y),
        Paint()
          ..color = grid.withValues(alpha: 0.8)
          ..strokeWidth = 1,
      );
      final color = colorFor(entry.resultType.toInt());
      if (selected) {
        canvas.drawCircle(
          Offset(x, y),
          7,
          Paint()..color = color.withValues(alpha: 0.18),
        );
      }
      canvas.drawCircle(
        Offset(x, y),
        selected ? 4.6 : 3.6,
        Paint()..color = color,
      );
    }
  }

  static int _severityOf(int type) => switch (type) {
    2 || 5 => 2,
    3 || 4 => 3,
    _ => 1,
  };

  @override
  bool shouldRepaint(covariant _RhythmTimelinePainter old) =>
      old.timeline != timeline ||
      old.grid != grid ||
      old.selectedIndex != selectedIndex;
}
