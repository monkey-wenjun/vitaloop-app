import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

/// 按模板训练：逐组记录重量/次数，组间休息倒计时，结束后存成一条力量训练。
class TemplateWorkoutScreen extends StatefulWidget {
  const TemplateWorkoutScreen({
    super.key,
    required this.state,
    required this.template,
  });

  final AppState state;
  final StrengthTemplate template;

  @override
  State<TemplateWorkoutScreen> createState() => _TemplateWorkoutScreenState();
}

class _TemplateWorkoutScreenState extends State<TemplateWorkoutScreen> {
  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;
  Timer? _restTicker;
  DateTime? _startedAt;
  final Map<int, int> _doneSets = {};
  final List<StrengthSetInput> _sets = [];
  DateTime? _lastSetAt;
  int _restLeft = 0;
  bool _saving = false;

  int get _seconds => _watch.elapsed.inSeconds;
  bool get _started => _startedAt != null;

  int get _plannedSets =>
      widget.template.exercises.fold(0, (sum, e) => sum + e.targetSets.toInt());

  double get _weightKg {
    final w = widget.state.profile?.weightKg ?? 0;
    return w > 0 ? w : 70;
  }

  int get _calories => (5.0 * _weightKg * (_seconds / 3600)).round();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _restTicker?.cancel();
    _watch.stop();
    super.dispose();
  }

  void _startRest(int seconds) {
    _restTicker?.cancel();
    if (seconds <= 0) {
      setState(() => _restLeft = 0);
      return;
    }
    setState(() => _restLeft = seconds);
    _restTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_restLeft <= 1) {
        timer.cancel();
        setState(() => _restLeft = 0);
      } else {
        setState(() => _restLeft--);
      }
    });
  }

  void _skipRest() {
    _restTicker?.cancel();
    setState(() => _restLeft = 0);
  }

  void _startTraining() {
    if (_started) return;
    _startedAt = DateTime.now();
    _watch.start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  Future<void> _recordSet(int index) async {
    if (!_started) return;
    final exercise = widget.template.exercises[index];
    final target = exercise.targetWeightKg;
    var selectedWeight = target?.toDouble() ?? 0.0;
    final reps = TextEditingController(text: '${exercise.targetReps}');
    final v = context.v;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '第 ${(_doneSets[index] ?? 0) + 1} 组 · ${exercise.exerciseName}',
                style: VText.h2.copyWith(color: v.ink),
              ),
              const SizedBox(height: 4),
              Text(
                '目标 ${exercise.targetSets} 组 × ${exercise.targetReps} 次',
                style: VText.meta.copyWith(color: v.muted),
              ),
              const SizedBox(height: 12),
              VWeightSlider(
                value: selectedWeight,
                onChanged: (value) => setSheet(() => selectedWeight = value),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reps,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: tr('次数'),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              VPrimaryButton(
                label: '完成这组',
                icon: Icons.check_rounded,
                onTap: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;

    final now = DateTime.now();
    final restActual = _lastSetAt == null
        ? 0
        : now.difference(_lastSetAt!).inSeconds;
    final parsedWeight = selectedWeight;
    final parsedReps = int.tryParse(reps.text.trim()) ?? 0;
    setState(() {
      _sets.add(
        StrengthSetInput(
          exerciseId: exercise.exerciseId,
          exerciseName: exercise.exerciseName,
          setNumber: (_doneSets[index] ?? 0) + 1,
          weightKg: parsedWeight,
          reps: parsedReps,
          restSecondsActual: restActual,
          completedAtMs: now.millisecondsSinceEpoch,
        ),
      );
      _doneSets[index] = (_doneSets[index] ?? 0) + 1;
      _lastSetAt = now;
    });
    _startRest(exercise.restSeconds.toInt());
  }

  Future<void> _finish() async {
    if (_sets.isEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('还没有记录任何一组'),
          content: const Text('现在结束只会保存一条时长记录，确定结束吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续训练'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('结束'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('结束训练？'),
          content: Text('已记录 ${_sets.length} 组，时长 ${fmtDuration(_seconds)}。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续训练'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('结束并保存'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _saving = true);
    try {
      final id = await VitaloopApi.saveManualWorkout(
        sport: '力量训练',
        startMs: _startedAt!.millisecondsSinceEpoch,
        durationSec: _seconds,
        calories: _calories,
      );
      if (_sets.isNotEmpty) {
        await VitaloopApi.saveStrengthSets(id, _sets);
      }
      await widget.state.refresh();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已保存 ${widget.template.name} · ${_sets.length} 组 · ${fmtDuration(_seconds)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
          children: [
            VDetailHeader(
              title: widget.template.name,
              icon: Icons.fitness_center_rounded,
              iconColor: v.purpleInk,
              onBack: () => _confirmQuit(),
            ),
            VCard(
              background: v.purple,
              foreground: v.purpleInk,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fmtDuration(_seconds),
                          style: VText.h1.copyWith(
                            fontSize: 40,
                            color: v.purpleInk,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已记录 ${_sets.length} / $_plannedSets 组 · 约 $_calories 千卡',
                          style: VText.meta.copyWith(
                            color: v.purpleInk.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${(_sets.length / (_plannedSets == 0 ? 1 : _plannedSets) * 100).clamp(0, 100).round()}%',
                    style: VText.h2.copyWith(color: v.purpleInk),
                  ),
                ],
              ),
            ),
            if (!_started) ...[
              const SizedBox(height: 11),
              VPrimaryButton(
                label: '开始训练',
                icon: Icons.play_arrow_rounded,
                onTap: _startTraining,
              ),
            ],
            if (_restLeft > 0) _restBanner(v),
            const VSectionHead(title: '动作'),
            for (var i = 0; i < widget.template.exercises.length; i++)
              _exerciseCard(i),
            const SizedBox(height: 6),
            if (_started)
              VPrimaryButton(
                label: _saving ? '正在保存…' : '结束并保存',
                icon: Icons.stop_rounded,
                onTap: _saving ? null : _finish,
              ),
          ],
        ),
      ),
    );
  }

  Widget _restBanner(VColors v) {
    return VCard(
      background: v.tintGreen,
      foreground: v.greenInk,
      child: Row(
        children: [
          Icon(Icons.timer_outlined, size: 22, color: v.greenInk),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '组间休息 $_restLeft 秒',
              style: VText.h3.copyWith(color: v.greenInk),
            ),
          ),
          TextButton(
            onPressed: _skipRest,
            child: Text('跳过', style: TextStyle(color: v.greenInk)),
          ),
        ],
      ),
    );
  }

  Widget _exerciseCard(int index) {
    final v = context.v;
    final e = widget.template.exercises[index];
    final done = _doneSets[index] ?? 0;
    final target = e.targetSets.toInt();
    final recorded = <StrengthSetInput>[];
    for (final s in _sets) {
      if (s.exerciseId == e.exerciseId && s.exerciseName == e.exerciseName) {
        recorded.add(s);
      }
    }
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  e.exerciseName,
                  style: VText.h3.copyWith(color: v.ink),
                ),
              ),
              Text(
                '$done / $target 组',
                style: VText.meta.copyWith(
                  color: done >= target ? v.greenInk : v.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '目标 ${e.targetReps} 次 · 休息 ${e.restSeconds} 秒'
            '${e.targetWeightKg == null ? ' · 自重' : ' · ${_num(e.targetWeightKg!.toDouble())} kg'}',
            style: VText.meta.copyWith(color: v.muted),
          ),
          if (recorded.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in recorded)
                  VChip(
                    text:
                        '${s.setNumber}. ${s.weightKg > 0 ? '${_num(s.weightKg)}kg × ' : ''}${s.reps}',
                    background: v.tintGrey,
                    foreground: v.ink2,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (!_started)
            Text('点上方「开始训练」后记录每组', style: VText.label.copyWith(color: v.muted))
          else
            VPrimaryButton(
              label: done >= target ? '再加一组' : '记录一组',
              icon: Icons.add_rounded,
              onTap: _saving ? null : () => _recordSet(index),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmQuit() async {
    if (!_started || _sets.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃这次训练？'),
        content: Text('已记录的 ${_sets.length} 组不会保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续训练'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop(false);
  }

  String _num(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
