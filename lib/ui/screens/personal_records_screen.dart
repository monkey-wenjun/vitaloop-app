import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/race_predictor.dart';
import '../components.dart';
import '../nav.dart';
import 'workout_detail_screen.dart';

class PersonalRecordsScreen extends StatefulWidget {
  const PersonalRecordsScreen({super.key});

  @override
  State<PersonalRecordsScreen> createState() => _PersonalRecordsScreenState();
}

class _PersonalRecordsScreenState extends State<PersonalRecordsScreen> {
  late final Future<List<PersonalRecord>> _future =
      VitaloopApi.personalRecords();

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<List<PersonalRecord>>(
          future: _future,
          builder: (context, snapshot) {
            final records = snapshot.data ?? const <PersonalRecord>[];
            final half = predictRace(records, 21.0975);
            final full = predictRace(records, 42.195);
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                const VDetailHeader(title: '个人纪录'),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Padding(
                    padding: EdgeInsets.only(top: 140),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (records.isEmpty)
                  const VEmpty(
                    title: '暂无个人纪录',
                    subtitle: '同步带距离或心率的运动后自动生成',
                    icon: Icons.emoji_events_rounded,
                  )
                else ...[
                  _predictionCard(context, '预估半马成绩', half),
                  const SizedBox(height: 10),
                  _predictionCard(context, '预估全马成绩', full),
                  const SizedBox(height: 10),
                  VCard(
                    background: v.mint,
                    foreground: v.mintInk,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '最好成绩',
                          style: VText.h3.copyWith(
                            color: v.mintInk,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '从全部 ${records.length} 项纪录中按项目分组，含 5K / 10K / 半马分段成绩。',
                          style: VText.label.copyWith(
                            color: v.mintInk.withValues(alpha: 0.75),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final entry in _group(records).entries) ...[
                    VSectionHead(
                      title: _groupName(entry.key),
                      trailing: '${entry.value.length} 项',
                    ),
                    VCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (final r in entry.value)
                            VRowItem(
                              icon: _icon(entry.key),
                              iconBackground: v.tintPeach,
                              iconColor: v.warnInk,
                              title: r.label,
                              subtitle:
                                  '${relativeDay(DateTime.fromMillisecondsSinceEpoch(r.achievedMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(r.achievedMs))}',
                              value: _value(r),
                              showChevron: r.workoutId.isNotEmpty,
                              onTap: r.workoutId.isEmpty
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => WorkoutDetailScreen(
                                          id: r.workoutId,
                                        ),
                                      ),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _predictionCard(
    BuildContext context,
    String title,
    RacePrediction? prediction,
  ) {
    final v = context.v;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: VText.h3.copyWith(color: v.ink, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          if (prediction == null)
            Text(
              '没有可用的分段成绩。先同步一次带整公里分段的跑步记录，才能按 Riegel 公式外推。',
              style: VText.label.copyWith(color: v.muted, height: 1.5),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  fmtDuration(prediction.timeSec),
                  style: VText.value.copyWith(
                    fontSize: 30,
                    color: v.blueInk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    '配速 ${fmtPace(prediction.targetKm * 1000, prediction.timeSec)}/km',
                    style: VText.label.copyWith(color: v.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '按${prediction.sourceLabel}（${fmtDuration(prediction.sourceSec)}）外推',
              style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
            ),
          ],
        ],
      ),
    );
  }

  Map<String, List<PersonalRecord>> _group(List<PersonalRecord> records) {
    final groups = <String, List<PersonalRecord>>{};
    for (final record in records) {
      groups.putIfAbsent(record.sport, () => []).add(record);
    }
    return groups;
  }

  String _groupName(String sport) => switch (sport) {
    'running' => '跑步',
    'cycling' => '骑行',
    'hiking' => '徒步 / 登山',
    'swimming' => '游泳',
    _ => sportName(sport),
  };

  String _value(PersonalRecord r) {
    if (r.unit == '秒/公里') return '${fmtPace(1000, r.value.toInt())}/km';
    if (r.unit == '秒') return fmtDuration(r.value.round());
    if (r.unit == 'km') return '${r.value.toStringAsFixed(2)} km';
    return '${r.value.round()} ${r.unit}';
  }

  IconData _icon(String sport) => switch (sport) {
    'cycling' => Icons.route_rounded,
    'hiking' => Icons.terrain_rounded,
    'swimming' => Icons.pool_rounded,
    'strength' => Icons.fitness_center_rounded,
    _ => Icons.directions_run_rounded,
  };
}
