import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import '../sport_style.dart';
import 'personal_records_screen.dart';
import 'saved_routes_screen.dart';
import 'sport_tools_screen.dart';
import 'strength_home_screen.dart';
import 'training_plan_screen.dart';
import 'workout_detail_screen.dart';
import 'workout_recorder_screen.dart';

class SportScreen extends StatelessWidget {
  const SportScreen({super.key, required this.state, required this.onOpenTab});

  final AppState state;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final recent = state.workouts.take(3).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('运动', style: VText.h1.copyWith(color: v.ink)),
                    const SizedBox(height: 4),
                    Text(
                      state.home == null
                          ? '选择一项运动开始'
                          : state.home!.readiness.advice,
                      style: VText.meta.copyWith(color: v.muted),
                    ),
                  ],
                ),
              ),
              VAvatar(
                initial: (state.profile?.nickname.isNotEmpty ?? false)
                    ? state.profile!.nickname.substring(0, 1)
                    : '元',
                blue: true,
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _SportCard(
                icon: Icons.directions_run_rounded,
                title: '跑步',
                sub: '计时 · 配速 · 心率',
                background: v.mint,
                foreground: v.mintInk,
                onTap: () =>
                    _start(context, '户外跑步', '跑步', Icons.directions_run_rounded),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SportCard(
                icon: Icons.route_rounded,
                title: '骑行',
                sub: '计时 · 距离',
                background: v.green,
                foreground: v.greenInk,
                onTap: () => _start(context, '骑行', '骑行', Icons.route_rounded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SportCard(
                icon: Icons.place_rounded,
                title: '徒步',
                sub: '计时 · 距离',
                background: v.sky,
                foreground: v.skyInk,
                height: 142,
                onTap: () => _start(context, '徒步', '徒步', Icons.place_rounded),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SportCard(
                icon: Icons.fitness_center_rounded,
                title: '力量',
                sub: '模板 · 组数 · 重量',
                background: v.purple,
                foreground: v.purpleInk,
                height: 142,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StrengthHomeScreen(state: state),
                  ),
                ),
              ),
            ),
          ],
        ),
        const VSectionHead(title: '计划与工具'),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              VRowItem(
                icon: Icons.event_note_rounded,
                iconBackground: v.tintBlue,
                iconColor: v.blueInk,
                title: '训练计划',
                subtitle: '生成 5K – 全马备赛课表',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TrainingPlanScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.alt_route_rounded,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: '规划路线',
                subtitle: '在地图上点选途经点',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RoutePlannerScreen()),
                ),
              ),
              VRowItem(
                icon: Icons.bookmarks_rounded,
                iconBackground: v.tintGreen,
                iconColor: v.greenInk,
                title: '已保存路线',
                subtitle: '复用之前点好的路线',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SavedRoutesScreen(state: state),
                  ),
                ),
              ),
              VRowItem(
                icon: Icons.emoji_events_rounded,
                iconBackground: v.tintPeach,
                iconColor: v.warnInk,
                title: '个人纪录',
                subtitle: '最好成绩与半马 / 全马预估',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const PersonalRecordsScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
        VSectionHead(
          title: '最近运动',
          trailing: '全部',
          onTrailing: () => onOpenTab(2),
        ),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (final w in recent)
                VRowItem(
                  icon: sportIcon(w.sport),
                  iconBackground: sportTint(context, w.sport),
                  iconColor: sportInk(context, w.sport),
                  title: sportName(w.sport),
                  subtitle:
                      '${relativeDay(DateTime.fromMillisecondsSinceEpoch(w.startMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(w.startMs))} · ${fmtDistance(w.distanceM)}',
                  value: fmtDuration(w.durationSec),
                  valueSub: '${fmtInt(w.calories)} kcal',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkoutDetailScreen(id: w.id),
                    ),
                  ),
                ),
              if (recent.isEmpty)
                const VEmpty(
                  title: '还没有运动记录',
                  subtitle: '连接手表或开始一次运动后，记录会出现在这里',
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _start(BuildContext context, String sport, String title, IconData icon) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkoutRecorderScreen(
          state: state,
          sport: sport,
          title: title,
          icon: icon,
        ),
      ),
    );
  }
}

class _SportCard extends StatelessWidget {
  const _SportCard({
    required this.icon,
    required this.title,
    required this.sub,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.height = 150,
  });

  final IconData icon;
  final String title;
  final String sub;
  final Color background;
  final Color foreground;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(icon, size: 24, color: foreground),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VText.value.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: VText.label.copyWith(
                    fontSize: 10.5,
                    color: foreground.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
