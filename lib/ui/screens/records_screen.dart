import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import '../sport_style.dart';
import 'workout_detail_screen.dart';
import 'workout_stats_screen.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  int _filter = 0;
  final Set<String> _hidden = {};
  static const _filters = ['全部', '跑步', '骑行', '徒步', '游泳', '力量'];

  bool _matches(WorkoutSummary w) {
    return switch (_filter) {
      1 => w.sport.contains('run') || w.sport == 'treadmill',
      2 => w.sport.contains('cycling') || w.sport.contains('spinning'),
      3 =>
        w.sport == 'hiking' ||
            w.sport == 'walk' ||
            w.sport == 'walking' ||
            w.sport.contains('climb'),
      4 => w.sport.contains('swim'),
      5 =>
        w.sport == 'strength' ||
            w.sport == 'free_training' ||
            w.sport == 'core',
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final all = widget.state.workouts
        .where((w) => !_hidden.contains(w.id))
        .toList();
    final filtered = all.where(_matches).toList();
    // 汇总卡 = 当前筛选范围的所有时间合计（用户明确要求「全部」下显示所有时间的汇总）
    final allDistance = filtered.fold<double>(0, (sum, w) => sum + w.distanceM);
    final allSeconds = filtered.fold<int>(0, (sum, w) => sum + w.durationSec);
    final allCalories = filtered.fold<int>(0, (sum, w) => sum + w.calories);
    final summaryTitle = _filter == 0
        ? '所有时间汇总'
        : '${_filters[_filter]} · 所有时间';

    final groups = <String, List<WorkoutSummary>>{};
    for (final w in filtered) {
      final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      final key = '${d.year} 年 ${d.month} 月';
      groups.putIfAbsent(key, () => []).add(w);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('记录', style: VText.h1.copyWith(color: v.ink)),
                    const SizedBox(height: 4),
                    Text(
                      '共 ${all.length} 次运动',
                      style: VText.meta.copyWith(color: v.muted),
                    ),
                  ],
                ),
              ),
              VAvatar(
                initial: (widget.state.profile?.nickname.isNotEmpty ?? false)
                    ? widget.state.profile!.nickname.substring(0, 1)
                    : '元',
              ),
            ],
          ),
        ),
        VSegmented(
          options: _filters,
          index: _filter,
          onChanged: (i) => setState(() => _filter = i),
        ),
        VCard(
          background: v.mint,
          foreground: v.mintInk,
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    summaryTitle,
                    style: VText.h3.copyWith(
                      color: v.mintInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  VChip(
                    text: '累计',
                    background: Colors.white.withValues(alpha: 0.5),
                    foreground: v.mintInk,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Summary(
                      value: '${filtered.length}',
                      unit: '次',
                      label: '运动',
                      color: v.mintInk,
                    ),
                  ),
                  Expanded(
                    child: _Summary(
                      value: (allDistance / 1000).toStringAsFixed(1),
                      unit: 'km',
                      label: '距离',
                      color: v.mintInk,
                    ),
                  ),
                  Expanded(
                    child: _Summary(
                      value: fmtDurationShort(allSeconds),
                      unit: '',
                      label: '时长',
                      color: v.mintInk,
                    ),
                  ),
                  Expanded(
                    child: _Summary(
                      value: fmtInt(allCalories),
                      unit: 'kcal',
                      label: '消耗',
                      color: v.mintInk,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        VCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WorkoutStatsScreen(
                workouts: all,
                bmrPerDay: basalMetabolicRate(
                  weightKg:
                      widget.state.home?.weightKg ??
                      widget.state.profile?.weightKg ??
                      0,
                  heightCm: widget.state.profile?.heightCm ?? 0,
                  age: ageFromBirthDate(widget.state.profile?.birthDate),
                  gender: widget.state.profile?.gender ?? 'male',
                ),
              ),
            ),
          ),
          child: VRowItem(
            icon: Icons.bar_chart_rounded,
            iconBackground: v.tintBlue,
            iconColor: v.blueInk,
            title: '数据统计',
            subtitle: '按日、周、月、半年、年统计运动数据',
            padding: EdgeInsets.zero,
            showChevron: true,
          ),
        ),
        if (filtered.isEmpty)
          const VEmpty(
            title: '还没有符合条件的记录',
            subtitle: '换一个筛选，或从手表同步运动记录',
            icon: Icons.directions_run_rounded,
          ),
        for (final entry in groups.entries) ...[
          VSectionHead(title: entry.key),
          VCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                for (final w in entry.value)
                  _WorkoutRow(
                    workout: w,
                    onDeleted: _reload,
                    onHidden: () => setState(() => _hidden.add(w.id)),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _reload() async {
    await widget.state.refresh();
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.value,
    required this.unit,
    required this.label,
    required this.color,
  });

  final String value;
  final String unit;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: VText.value.copyWith(
                  fontSize: 19,
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextSpan(
                text: ' $unit',
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: VText.label.copyWith(
            fontSize: 9.5,
            color: color.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _WorkoutRow extends StatelessWidget {
  const _WorkoutRow({
    required this.workout,
    required this.onDeleted,
    required this.onHidden,
  });

  final WorkoutSummary workout;
  final Future<void> Function() onDeleted;
  final VoidCallback onHidden;

  Future<void> _open(BuildContext context) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WorkoutDetailScreen(id: workout.id)),
    );
    if (removed == true) await onDeleted();
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.v.surface,
        title: Text('删除运动记录', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '确定删除这条${sportName(workout.sport)}记录？删除后不可恢复，手表同步也不会再把它带回来。',
          style: VText.meta.copyWith(color: ctx.v.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: ctx.v.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    try {
      await VitaloopApi.deleteWorkout(workout.id);
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = DateTime.fromMillisecondsSinceEpoch(workout.startMs);
    return Dismissible(
      key: ValueKey('workout-${workout.id}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.8},
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) {
        onHidden();
        onDeleted();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('运动记录已删除')));
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: context.v.danger,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.white, size: 20),
            SizedBox(width: 6),
            Text(
              '删除',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
      child: VRowItem(
        icon: sportIcon(workout.sport),
        iconBackground: sportTint(context, workout.sport),
        iconColor: sportInk(context, workout.sport),
        title: sportName(workout.sport),
        subtitle:
            '${relativeDay(start)} ${clock(start)} · ${fmtDistance(workout.distanceM)}',
        badge: workout.synced ? null : '待同步',
        value: fmtDuration(workout.durationSec),
        valueSub: '${fmtInt(workout.calories)} kcal',
        onTap: () => _open(context),
      ),
    );
  }
}
