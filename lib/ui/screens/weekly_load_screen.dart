import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 本周训练负荷：按周一~周日汇总每次运动的 load，和旧版的口径一致。
class WeeklyLoadScreen extends StatefulWidget {
  const WeeklyLoadScreen({super.key});

  @override
  State<WeeklyLoadScreen> createState() => _WeeklyLoadScreenState();
}

class _WeeklyLoadScreenState extends State<WeeklyLoadScreen> {
  List<WorkoutSummary> _workouts = const [];
  bool _loading = true;

  static const _labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await VitaloopApi.workouts(limit: 500);
    if (!mounted) return;
    setState(() {
      _workouts = list;
      _loading = false;
    });
  }

  DateTime get _monday {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  List<int> get _daily {
    final out = List<int>.filled(7, 0);
    for (final w in _workouts) {
      final at = DateTime.fromMillisecondsSinceEpoch(w.startMs.toInt());
      final index = DateTime(
        at.year,
        at.month,
        at.day,
      ).difference(_monday).inDays;
      if (index >= 0 && index < 7) out[index] += w.load.toInt();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final daily = _daily;
    final total = daily.fold<int>(0, (a, b) => a + b);
    final maxLoad = daily.fold<int>(1, (a, b) => b > a ? b : a);
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            const VDetailHeader(title: '本周负荷', icon: Icons.bolt_rounded),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              VCard(
                background: v.mint,
                foreground: v.mintInk,
                child: Column(
                  children: [
                    Text(
                      '本周训练负荷',
                      style: VText.label.copyWith(
                        color: v.mintInk.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$total',
                      style: VText.h1.copyWith(fontSize: 54, color: v.mintInk),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_workouts.where((w) => w.load > 0).length} 次带负荷的运动',
                      style: VText.label.copyWith(
                        color: v.mintInk.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '每天负荷'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < 7; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              child: Text(
                                _labels[i],
                                style: VText.label.copyWith(color: v.ink),
                              ),
                            ),
                            SizedBox(
                              width: 62,
                              child: Text(
                                _dateLabel(i),
                                style: VText.label.copyWith(
                                  fontSize: 9.5,
                                  color: v.muted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: daily[i] / maxLoad,
                                  minHeight: 8,
                                  backgroundColor: v.tintGrey,
                                  valueColor: AlwaysStoppedAnimation(v.blue),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 44,
                              child: Text(
                                '${daily[i]}',
                                textAlign: TextAlign.right,
                                style: VText.h3.copyWith(
                                  fontSize: 13,
                                  color: daily[i] > 0 ? v.ink : v.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const VSectionHead(title: '这周的运动'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    for (final w in _workouts.where((w) {
                      final at = DateTime.fromMillisecondsSinceEpoch(
                        w.startMs.toInt(),
                      );
                      return !DateTime(
                        at.year,
                        at.month,
                        at.day,
                      ).isBefore(_monday);
                    }))
                      VRowItem(
                        icon: Icons.fitness_center_rounded,
                        iconBackground: v.tintBlue,
                        iconColor: v.blueInk,
                        title: sportName(w.sport),
                        subtitle:
                            '${monthDayShort(DateTime.fromMillisecondsSinceEpoch(w.startMs.toInt()))} ${clock(DateTime.fromMillisecondsSinceEpoch(w.startMs.toInt()))}',
                        value: '${w.load}',
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

  String _dateLabel(int index) {
    final d = _monday.add(Duration(days: index));
    return '${d.month}/${d.day}';
  }
}
