import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/range_buckets.dart';
import '../components.dart';
import '../nav.dart';

/// 跑力指数详情页：华为按「最佳成绩」划定跑力，只认超过 12 分钟、
/// 心率 ≥100bpm 的跑步；我们与手表 TruSport 的 VO2max 估算同源。
class RunningIndexScreen extends StatefulWidget {
  const RunningIndexScreen({super.key, required this.state});

  final AppState state;

  @override
  State<RunningIndexScreen> createState() => _RunningIndexScreenState();
}

class _RunningIndexScreenState extends State<RunningIndexScreen> {
  List<RunningIndexPoint> _points = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final points = await VitaloopApi.runningIndex(limit: 100);
      if (mounted) setState(() => _points = points);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _level(double? rai) {
    if (rai == null) return '--';
    if (rai < 30) return '入门';
    if (rai < 40) return '初级';
    if (rai < 50) return '中级';
    if (rai < 60) return '高级';
    return '精英';
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final best = _points.isEmpty
        ? null
        : _points.map((p) => p.rai).reduce((a, b) => a > b ? a : b);
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(title: '跑力指数'),
            VCard(
              background: v.mint,
              foreground: v.mintInk,
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: best == null
                                  ? '--'
                                  : best.toStringAsFixed(1),
                              style: VText.value.copyWith(
                                fontSize: 40,
                                color: v.mintInk,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const WidgetSpan(child: SizedBox(width: 6)),
                            TextSpan(
                              text: _level(best),
                              style: VText.h3.copyWith(
                                color: v.mintInk,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '近 90 天最佳成绩',
                        style: VText.label.copyWith(
                          color: v.mintInk.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  VIconBox(
                    icon: Icons.directions_run_rounded,
                    background: Colors.white.withValues(
                      alpha: v.isDark ? 0.10 : 0.52,
                    ),
                    foreground: v.mintInk,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_points.isEmpty)
              VEmpty(
                title: '还没有跑力数据',
                subtitle: '完成一次超过 12 分钟、心率 100bpm 以上的跑步后\n跑表会把跑力同步进来',
                icon: Icons.directions_run_rounded,
              )
            else ...[
              if (_points.length >= 2) ...[
                const VSectionHead(title: '跑力走势'),
                VCard(
                  child: VRangeLine(
                    color: const Color(0xFF37B58C),
                    valueFormat: (value) => value.toStringAsFixed(1),
                    buckets: [
                      for (final p in _points.take(30).toList().reversed)
                        RangeBucket(
                          start: DateTime.fromMillisecondsSinceEpoch(p.startMs),
                          value: p.rai,
                          label: monthDayShort(
                            DateTime.fromMillisecondsSinceEpoch(p.startMs),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              VSectionHead(title: '达标跑步记录', trailing: '${_points.length} 次'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    for (final p in _points)
                      _RunRow(point: p, level: _level(p.rai)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '跑力是怎么算的',
                      style: VText.h3.copyWith(color: v.ink, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '跑力指数衡量跑者的耐力水平与跑步技术效率，依据你所能达成的最佳成绩划定，数值越高比赛成绩越好。\n\n'
                      '与华为一致的取数规则：\n'
                      '· 只统计超过 12 分钟、平均心率 ≥100bpm 的跑步；\n'
                      '· 取近 90 天内最佳一次的成绩；\n'
                      '· 数值来自手表端 TruSport 的摄氧量估算，与手表显示同源。\n\n'
                      '暂无最佳成绩突破时跑力保持不变，好好恢复再战一次。',
                      style: VText.body.copyWith(
                        color: v.ink2,
                        height: 1.55,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.point, required this.level});

  final RunningIndexPoint point;
  final String level;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final d = DateTime.fromMillisecondsSinceEpoch(point.startMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  monthDay(d),
                  style: VText.label.copyWith(
                    color: v.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${fmtDistance(point.distanceM)} · 配速 ${fmtPace(point.distanceM, point.durationSec)} · 均心率 ${point.avgHr}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
                ),
              ],
            ),
          ),
          VChip(text: '${point.rai.toStringAsFixed(1)} $level'),
        ],
      ),
    );
  }
}
