import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/home_cards.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import 'auth_screen.dart';
import 'ecg_screen.dart';
import 'fitness_advice_screen.dart';
import 'heart_rhythm_screen.dart';
import 'metric_detail_screen.dart';
import 'readiness_screen.dart';
import 'running_index_screen.dart';
import 'sleep_detail_screen.dart';
import 'weekly_load_screen.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state, required this.onOpenTab});

  final AppState state;
  final ValueChanged<int> onOpenTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _layoutKey = 'home_cards_layout';

  HomeCardLayout _layout = HomeCardLayout.defaults;
  bool _editing = false;
  int _lastUiPointerDownMs = 0;
  int? _lastBlankTapMs;
  bool _layoutLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLayout());
  }

  Future<void> _loadLayout() async {
    try {
      final raw = await VitaloopApi.setting(_layoutKey, '');
      if (!mounted || _layoutLoaded) return;
      setState(() {
        _layout = HomeCardLayout.parse(raw);
        _layoutLoaded = true;
      });
    } catch (_) {
      if (mounted) _layoutLoaded = true;
    }
  }

  Future<void> _saveLayout(HomeCardLayout layout) async {
    try {
      await VitaloopApi.setSetting(_layoutKey, layout.encode());
    } catch (_) {}
  }

  void _commitLayout(HomeCardLayout layout) {
    setState(() {
      _layout = layout;
      _layoutLoaded = true;
    });
    unawaited(_saveLayout(layout));
  }

  void _moveCard(String from, String? to) {
    if (from == to) return;
    final order = HomeCardLayout.move(_layout.order, from, to);
    if (order.join('\u0000') == _layout.order.join('\u0000')) return;
    _commitLayout(_layout.copyWith(order: order));
  }

  void _hideCard(String id) {
    if (_layout.hidden.contains(id)) return;
    _commitLayout(_layout.copyWith(hidden: {..._layout.hidden, id}));
  }

  void _showCard(String id) {
    if (!_layout.hidden.contains(id)) return;
    _commitLayout(_layout.copyWith(hidden: _layout.hidden.difference({id})));
  }

  Future<void> _resetLayout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认首页？'),
        content: const Text('卡片顺序和隐藏状态会恢复为默认，数据不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok == true) _commitLayout(HomeCardLayout.defaults);
  }

  void _openAddSheet() {
    final hidden = [
      for (final id in _layout.order)
        if (_layout.hidden.contains(id)) HomeCardLayout.specOf(id),
    ];
    if (hidden.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('所有卡片都已经在首页上')));
      return;
    }
    final v = context.v;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 18),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('添加卡片', style: VText.h2.copyWith(color: v.ink)),
            ),
            for (final spec in hidden)
              ListTile(
                leading: Icon(Icons.add_circle_outline_rounded, color: v.blue),
                title: Text(spec.title),
                subtitle: const Text('点击添加到首页'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showCard(spec.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _handlePagePointerDown(PointerDownEvent event) {
    if (!_editing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUiPointerDownMs < 120) {
      _lastBlankTapMs = null;
      return;
    }
    final previous = _lastBlankTapMs;
    if (previous != null && now - previous <= 500) {
      _lastBlankTapMs = null;
      setState(() => _editing = false);
    } else {
      _lastBlankTapMs = now;
    }
  }

  Future<void> _refresh() async {
    try {
      await widget.state.refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('刷新失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final state = widget.state;
    final home = state.home;
    if (home == null) {
      return Center(child: CircularProgressIndicator(color: v.blue));
    }

    final readiness = home.readiness;
    final readinessHasData = readiness.total > 0;
    final now = DateTime.now();
    final dataDay = DateTime.fromMillisecondsSinceEpoch(
      home.dateEpochDay * Duration.millisecondsPerDay,
    );
    final isToday =
        dataDay.year == now.year &&
        dataDay.month == now.month &&
        dataDay.day == now.day;
    final initial = (state.profile?.nickname.isNotEmpty ?? false)
        ? state.profile!.nickname[0]
        : 'V';
    final todayWorkoutMeters = state.workouts
        .where((w) {
          final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
          return start.year == dataDay.year &&
              start.month == dataDay.month &&
              start.day == dataDay.day;
        })
        .fold<double>(0, (sum, w) => sum + w.distanceM);
    final sleepMinutes = home.sleepMinutes ?? 0;
    final stressText = (home.stress ?? 100) < 40
        ? '轻松'
        : (home.stress ?? 100) < 70
        ? '中等'
        : '偏高';
    final weight = state.weights.isNotEmpty
        ? state.weights.first.weightKg
        : null;
    final bmi = weight == null
        ? null
        : weight /
              ((state.profile?.heightCm ?? 170) /
                  100 *
                  (state.profile?.heightCm ?? 170) /
                  100);
    final bp = state.bloodPressure.isNotEmpty
        ? state.bloodPressure.first
        : null;
    final glucose = state.glucose.isNotEmpty ? state.glucose.first : null;
    final arrhythmiaText = state.arrhythmia.isEmpty
        ? '暂无记录'
        : '${state.arrhythmia.length} 条筛查';
    final coreTemp = home.bodyTempC;
    final temp = coreTemp ?? home.skinTempC;
    final tempAtMs = home.bodyTempAtMs ?? home.skinTempAtMs;
    final tempDay = tempAtMs == null
        ? '今天'
        : relativeDay(DateTime.fromMillisecondsSinceEpoch(tempAtMs));

    Widget baseCard(String id) {
      switch (id) {
        case 'advice':
          return _adviceCard(
            context,
            readiness,
            readinessHasData,
            isToday,
            dataDay,
          );
        case 'readiness':
          return ReadinessRing(
            score: readiness.total,
            level: readiness.level,
            trend: readiness.trend,
            hasData: readinessHasData,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ReadinessScreen(state: state)),
            ),
          );
        case 'steps':
          return VTile(
            icon: Icons.directions_walk_rounded,
            label: '步数',
            value: fmtInt(home.steps),
            background: v.mint,
            foreground: v.mintInk,
            progress: home.stepsGoal == 0 ? 0 : home.steps / home.stepsGoal,
            onTap: () =>
                _open(context, 'steps', title: '步数', color: v.greenInk),
          );
        case 'workout':
          return VTile(
            icon: Icons.directions_run_rounded,
            label: isToday ? '今日运动' : '当日运动',
            value: todayWorkoutMeters > 0
                ? (todayWorkoutMeters / 1000).toStringAsFixed(2)
                : '0',
            unit: '公里',
            background: v.green,
            foreground: v.greenInk,
            onTap: () => widget.onOpenTab(2),
          );
        case 'sleep':
          return VTile(
            icon: Icons.bedtime_rounded,
            label: '今日睡眠',
            value: sleepMinutes > 0 ? fmtSleep(sleepMinutes) : '--',
            background: v.purple,
            foreground: v.purpleInk,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SleepDetailScreen()),
            ),
          );
        case 'calories':
          return VTile(
            icon: Icons.local_fire_department_rounded,
            label: '消耗卡数',
            value: fmtInt(home.activeCalories),
            background: v.mint,
            foreground: v.mintInk,
            progress: home.caloriesGoal == 0
                ? 0
                : home.activeCalories / home.caloriesGoal,
            onTap: () => _open(
              context,
              'active_calories',
              title: '活动热量',
              color: v.greenInk,
            ),
          );
        case 'minutes':
          return VTile(
            icon: Icons.schedule_rounded,
            label: '运动时长',
            value: '${home.exerciseMinutes}',
            unit: '分钟',
            background: v.mint,
            foreground: v.mintInk,
            progress: home.exerciseGoalMin == 0
                ? 0
                : home.exerciseMinutes / home.exerciseGoalMin,
            onTap: () => _open(
              context,
              'exercise_minutes',
              title: '运动时长',
              color: v.greenInk,
            ),
          );
        case 'weekly_workouts':
          return VTile(
            icon: Icons.fitness_center_rounded,
            label: '本周运动',
            value: '${home.weeklyWorkouts}',
            unit: '目标 5',
            background: v.mint,
            foreground: v.mintInk,
            progress: home.weeklyWorkouts / 5,
            onTap: () => widget.onOpenTab(2),
          );
        case 'weekly_load':
          return VTile(
            icon: Icons.bolt_rounded,
            label: '训练负荷',
            value: '${home.weeklyLoad}',
            unit: '7 天',
            background: v.mint,
            foreground: v.mintInk,
            progress: (home.weeklyLoad / 600).clamp(0, 1),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const WeeklyLoadScreen())),
          );
        case 'active_hours':
          return VTile(
            icon: Icons.wb_twilight_rounded,
            label: '活动小时数',
            value: home.activeHours == null ? '--' : '${home.activeHours}',
            unit: '/ ${home.activeHoursGoal} 小时',
            background: v.mint,
            foreground: v.mintInk,
            progress: home.activeHours == null || home.activeHoursGoal == 0
                ? 0.0
                : (home.activeHours! / home.activeHoursGoal)
                      .clamp(0, 1)
                      .toDouble(),
            onTap: () => widget.onOpenTab(2),
          );
        case 'running_index':
          return VTile(
            icon: Icons.directions_run_rounded,
            label: '跑力指数',
            value: home.runningIndex == null
                ? '--'
                : home.runningIndex!.toStringAsFixed(1),
            unit: _raiLevel(home.runningIndex),
            background: v.mint,
            foreground: v.mintInk,
            progress: home.runningIndex == null
                ? 0.0
                : (home.runningIndex! / 70).clamp(0, 1).toDouble(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RunningIndexScreen(state: state),
              ),
            ),
          );
        case 'heart_rate':
          return VMini(
            label: '心率',
            value: home.heartRate == null ? '--' : '${home.heartRate}',
            unit: 'bpm',
            sub: '静息 ${home.restingHr ?? '--'}',
            background: v.pink,
            foreground: v.heartInk,
            onTap: () =>
                _open(context, 'heart_rate', title: '心率', color: v.heartInk),
          );
        case 'spo2':
          return VMini(
            label: '血氧',
            value: '${home.spo2 ?? '--'}',
            unit: '%',
            sub: home.spo2 == null ? '未采集' : '最近一次',
            background: v.green,
            foreground: v.greenInk,
            onTap: () => _open(context, 'spo2', title: '血氧', color: v.greenInk),
          );
        case 'respiration':
          return VMini(
            label: '呼吸率',
            value: '${home.respiration ?? '--'}',
            unit: '次/分',
            sub: home.respiration == null ? '未采集' : '睡眠期间',
            background: v.sky,
            foreground: v.skyInk,
            onTap: () =>
                _open(context, 'respiration', title: '呼吸率', color: v.skyInk),
          );
        case 'stress':
          return VMini(
            label: '压力',
            value: '${home.stress ?? '--'}',
            sub: home.stress == null ? '未采集' : stressText,
            background: v.purple,
            foreground: v.purpleInk,
            onTap: () =>
                _open(context, 'stress', title: '压力', color: v.purpleInk),
          );
        case 'temp':
          return VMini(
            label: coreTemp != null ? '体温' : '腕温',
            value: temp == null ? '--' : temp.toStringAsFixed(1),
            unit: '°C',
            sub: temp == null
                ? '未采集'
                : (coreTemp != null
                      ? (tempDay == '今天' ? '核心' : '核心 · $tempDay')
                      : (tempDay == '今天' ? '腕温' : '腕温 · $tempDay')),
            background: v.peach,
            foreground: v.peachInk,
            onTap: () => _open(
              context,
              coreTemp != null ? 'body_temp' : 'skin_temp',
              title: coreTemp != null ? '体温' : '腕温',
              color: v.warnInk,
            ),
          );
        case 'weight':
          return VMini(
            label: '体重',
            value: weight == null ? '--' : weight.toStringAsFixed(1),
            unit: 'kg',
            sub: bmi == null ? '暂无' : 'BMI ${bmi.toStringAsFixed(1)}',
            background: v.sky,
            foreground: v.skyInk,
            onTap: () => _open(context, 'weight', title: '体重', color: v.skyInk),
          );
        case 'bp':
          return VMini(
            label: '血压',
            value: bp == null ? '--/--' : '${bp.systolic}/${bp.diastolic}',
            sub: bp == null ? '暂无记录' : '脉搏 ${bp.pulse ?? '--'}',
            background: v.pink,
            foreground: v.pinkInk,
            onTap: () => _open(context, 'bp', title: '血压', color: v.pinkInk),
          );
        case 'glucose':
          return VMini(
            label: '血糖',
            value: glucose == null ? '--' : glucose.value.toStringAsFixed(1),
            unit: 'mmol',
            sub: glucose == null ? '暂无记录' : '最近一次',
            background: v.lime,
            foreground: v.limeInk,
            onTap: () =>
                _open(context, 'glucose', title: '血糖', color: v.limeInk),
          );
        case 'hrv':
          return VMini(
            label: 'HRV',
            value: '${home.hrvMs ?? '--'}',
            unit: 'ms',
            sub: home.hrvMs == null
                ? '未采集'
                : (readiness.hrvScore >= 70 ? '良好' : '偏低'),
            background: v.purple,
            foreground: v.purpleInk,
            onTap: () =>
                _open(context, 'hrv', title: 'HRV', color: v.purpleInk),
          );
        case 'emotion':
          return VMini(
            label: '情绪',
            value: home.emotionStatus == null
                ? '--'
                : emotionLabel(home.emotionStatus!),
            sub: home.emotionStatus == null
                ? '未采集'
                : '愉悦度 ${(home.emotionValence ?? 0).round()} · 激活度 ${(home.emotionArousal ?? 0).round()}',
            background: v.pink,
            foreground: v.pinkInk,
            onTap: () =>
                _open(context, 'emotion', title: '情绪', color: v.pinkInk),
          );
        case 'vo2max':
          return VMini(
            label: '最大摄氧量',
            value: home.vo2Max == null ? '--' : home.vo2Max!.toStringAsFixed(1),
            unit: 'ml/kg',
            sub: home.vo2Max == null ? '未采集' : _vo2Level(home.vo2Max!),
            background: v.mint,
            foreground: v.mintInk,
            onTap: () =>
                _open(context, 'vo2max', title: '最大摄氧量', color: v.mintInk),
          );
        case 'arrhythmia':
          return VMini(
            label: '心律',
            value: state.arrhythmia.isEmpty
                ? '--'
                : arrhythmiaLabel(state.arrhythmia.first.resultType),
            sub: arrhythmiaText,
            background: v.green,
            foreground: v.greenInk,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => EcgScreen(records: state.ecg)),
            ),
          );
        case 'ecg':
          final latest = state.ecg.isNotEmpty ? state.ecg.first : null;
          return VMini(
            label: '心电',
            value: latest?.arrhythmiaType == null
                ? '--'
                : arrhythmiaLabel(latest!.arrhythmiaType!),
            unit: latest == null ? '' : '${latest.avgHeartRate ?? '--'} bpm',
            sub: latest == null
                ? '暂无记录'
                : '${relativeDay(DateTime.fromMillisecondsSinceEpoch(latest.startMs))} · ${(latest.sampleCount / 500).round()} 秒',
            background: v.pink,
            foreground: v.heartInk,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => HeartRhythmScreen(records: state.arrhythmia),
              ),
            ),
          );
        default:
          return const SizedBox.shrink();
      }
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePagePointerDown,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = math.max(0.0, constraints.maxWidth - 36);
          final visible = [
            for (final id in _layout.order)
              if (!_layout.hidden.contains(id)) HomeCardLayout.specOf(id),
          ];
          final rows = <Widget>[];
          var index = 0;
          while (index < visible.length) {
            final spec = visible[index];
            if (spec.id == 'readiness') {
              final following = <HomeCardSpec>[];
              var next = index + 1;
              while (next < visible.length &&
                  following.length < 3 &&
                  visible[next].size == HomeCardSize.half) {
                following.add(visible[next]);
                next++;
              }
              final ringSize = math.min(206.0, contentWidth * 0.59);
              final rightWidth = math.max(0.0, contentWidth - ringSize - 12);
              final ring = _cardSlot(
                context,
                id: spec.id,
                width: ringSize,
                child: ReadinessRing(
                  size: ringSize,
                  score: readiness.total,
                  level: readiness.level,
                  trend: readiness.trend,
                  hasData: readinessHasData,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReadinessScreen(state: state),
                    ),
                  ),
                ),
              );
              Widget row;
              if (following.isEmpty) {
                row = Align(alignment: Alignment.centerLeft, child: ring);
              } else {
                row = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ring,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        children: [
                          for (var i = 0; i < following.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            _cardSlot(
                              context,
                              id: following[i].id,
                              width: rightWidth,
                              child: baseCard(following[i].id),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              }
              rows.add(
                Padding(padding: const EdgeInsets.only(bottom: 10), child: row),
              );
              index = next;
              continue;
            }

            if (spec.size == HomeCardSize.full) {
              rows.add(
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _cardSlot(
                    context,
                    id: spec.id,
                    width: contentWidth,
                    child: baseCard(spec.id),
                  ),
                ),
              );
              index++;
              continue;
            }

            // 编辑态也要保持三列：移除按钮是 Stack 里的悬浮层，不占布局。
            // 改成两列会让小卡突然变宽、整页重排，看起来像卡片被挤变形。
            final limit = spec.size == HomeCardSize.mini ? 3 : 2;
            final group = <HomeCardSpec>[spec];
            var next = index + 1;
            while (next < visible.length &&
                group.length < limit &&
                visible[next].size == spec.size) {
              group.add(visible[next]);
              next++;
            }
            final gap = spec.size == HomeCardSize.mini ? 8.0 : 10.0;
            final cardWidth = math.max(
              0.0,
              (contentWidth - gap * (limit - 1)) / limit,
            );
            rows.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < group.length; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      _cardSlot(
                        context,
                        id: group[i].id,
                        width: cardWidth,
                        child: baseCard(group[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            );
            index = next;
          }

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: _editing
                ? () => setState(() => _editing = false)
                : null,
            child: RefreshIndicator(
              onRefresh: _refresh,
              color: v.blue,
              backgroundColor: v.surface,
              displacement: 42,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
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
                              Text(
                                isToday ? '今天' : '最近数据',
                                style: VText.h1.copyWith(color: v.ink),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${MaterialLocalizations.of(context).formatFullDate(dataDay)}'
                                '${isToday ? '' : ' · 离线快照'}',
                                style: VText.meta.copyWith(
                                  color: v.muted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: tr('编辑首页卡片'),
                          onPressed: () => setState(() => _editing = true),
                          icon: Icon(Icons.tune_rounded, color: v.ink2),
                        ),
                        const SizedBox(width: 2),
                        VAvatar(
                          initial: initial,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => state.signedIn
                                  ? AccountCenterScreen(state: state)
                                  : AuthScreen(state: state),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_editing) _editBar(context),
                  if (rows.isEmpty)
                    VCard(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        children: [
                          Text(
                            '首页卡片已全部移除',
                            style: VText.h3.copyWith(color: v.ink),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '点“添加卡片”把需要的指标找回来。',
                            style: VText.meta.copyWith(color: v.muted),
                          ),
                        ],
                      ),
                    ),
                  ...rows,
                  if (_editing) _dropAtEnd(context),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _cardSlot(
    BuildContext context, {
    required String id,
    required double width,
    required Widget child,
  }) {
    final v = context.v;
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (details) => _editing && details.data != id,
      onAcceptWithDetails: (details) => _moveCard(details.data, id),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        final content = Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            child,
            if (_editing)
              Positioned(
                right: 5,
                top: 5,
                child: GestureDetector(
                  onTap: () => _hideCard(id),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: v.isDark
                          ? const Color(0xFF243044)
                          : Colors.white.withValues(alpha: 0.94),
                      shape: BoxShape.circle,
                      border: Border.all(color: v.line),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Icon(Icons.close_rounded, size: 16, color: v.ink2),
                  ),
                ),
              ),
          ],
        );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: active ? v.blue : Colors.transparent,
              width: active ? 2 : 0,
            ),
          ),
          child: content,
        );
      },
    );

    Widget markUi(Widget child) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        _lastUiPointerDownMs = DateTime.now().millisecondsSinceEpoch;
      },
      child: child,
    );

    if (!_editing) {
      return markUi(
        SizedBox(
          width: width,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onLongPress: () => setState(() => _editing = true),
            child: child,
          ),
        ),
      );
    }

    return markUi(
      SizedBox(
        width: width,
        child: LongPressDraggable<String>(
          data: id,
          delay: const Duration(milliseconds: 220),
          feedback: Material(
            color: Colors.transparent,
            elevation: 10,
            borderRadius: BorderRadius.circular(26),
            child: SizedBox(width: width, child: child),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: target),
          // 编辑态点卡片不该再跳详情；拦住内层点击，但长按拖动仍由外层
          // LongPressDraggable 接收。
          child: AbsorbPointer(absorbing: _editing, child: target),
        ),
      ),
    );
  }

  Widget _editBar(BuildContext context) {
    final v = context.v;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        _lastUiPointerDownMs = DateTime.now().millisecondsSinceEpoch;
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        decoration: BoxDecoration(
          color: v.tintBlue,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.drag_indicator_rounded, size: 18, color: v.blueInk),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '拖动排序 · 点 × 移除 · 双击空白退出',
                    style: VText.label.copyWith(
                      color: v.blueInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _openAddSheet,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('添加卡片'),
                ),
                const Spacer(),
                TextButton(onPressed: _resetLayout, child: const Text('恢复默认')),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: () => setState(() => _editing = false),
                  child: const Text('完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropAtEnd(BuildContext context) {
    final v = context.v;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => _moveCard(details.data, null),
      builder: (context, candidate, rejected) {
        final active = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? v.tintBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: active ? v.blue : v.line,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Text(
            active ? '松开移到最后' : '拖到这里放到最后',
            style: VText.label.copyWith(
              color: active ? v.blueInk : v.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      },
    );
  }

  Widget _adviceCard(
    BuildContext context,
    ReadinessScore readiness,
    bool readinessHasData,
    bool isToday,
    DateTime dataDay,
  ) {
    final v = context.v;
    return VCard(
      margin: EdgeInsets.zero,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const FitnessAdviceScreen())),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: v.blue),
              const SizedBox(width: 6),
              Text(
                '今日训练建议',
                style: VText.h3.copyWith(color: v.ink, fontSize: 13),
              ),
              const Spacer(),
              VChip(text: readinessHasData ? '准备度 ${readiness.total}' : '暂无数据'),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            readinessHasData
                ? _advice(readiness, widget.state.home?.restingHr ?? 60)
                : '暂无足够的 HRV、睡眠与静息心率数据。手表完成一次同步后会自动生成建议。',
            style: VText.body.copyWith(color: v.ink2),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                isToday
                    ? (readiness.recoveryMinutes > 0
                          ? '基于身心准备度与恢复时间'
                          : '基于身心准备度')
                    : '基于 ${monthDay(dataDay)} 的 AI 分析',
                style: VText.label.copyWith(fontSize: 10, color: v.muted),
              ),
              const Spacer(),
              Text(
                'AI 分析 ›',
                style: VText.label.copyWith(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: v.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _open(
    BuildContext context,
    String metric, {
    String? title,
    Color? color,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MetricDetailScreen(
          metric: metric,
          title: title,
          color: color,
          state: widget.state,
        ),
      ),
    );
  }

  String _vo2Level(double value) {
    if (value >= 53) return '优秀';
    if (value >= 46) return '良好';
    if (value >= 38) return '一般';
    return '较低';
  }

  String _raiLevel(double? rai) {
    if (rai == null) return '';
    if (rai < 30) return '入门';
    if (rai < 40) return '初级';
    if (rai < 50) return '中级';
    if (rai < 60) return '高级';
    return '精英';
  }

  String _advice(ReadinessScore readiness, int restingHr) {
    final score = readiness.total.toInt();
    final level = readiness.level;
    final low = restingHr + 68;
    final high = restingHr + 82;
    final recovery = readiness.recoveryMinutes > 0
        ? ' 当天运动累计建议恢复 ${_recoveryLabel(readiness.recoveryMinutes.toInt())}。'
        : '';
    if (score >= 85) {
      return '身心准备度 $score 分，$level。今天可以尝试高强度间歇或长距离耐力，心率区间 $low–$high bpm；训练后记得补充碳水与睡眠。$recovery';
    }
    if (score >= 75) {
      return '身心准备度 $score 分，$level。今天建议 30–40 分钟轻松跑，心率压在 $low–$high bpm；睡前补 10 分钟拉伸，明早看静息心率是否回落。$recovery';
    }
    if (score >= 60) {
      return '身心准备度 $score 分，$level。建议降低强度，做 20–30 分钟有氧恢复，心率控制在 $low bpm 以内，避免连续高强度。$recovery';
    }
    return '身心准备度 $score 分，$level。今天优先恢复：散步、拉伸或完全休息，等 HRV 与静息心率回到基线再恢复训练。$recovery';
  }

  String _recoveryLabel(int minutes) {
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final rest = minutes % 60;
      return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
    }
    return '$minutes 分钟';
  }
}
