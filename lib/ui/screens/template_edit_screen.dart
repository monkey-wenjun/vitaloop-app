import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

/// 新建 / 编辑力量训练模板。旧版 TemplateEditScreen 的迁移。
class TemplateEditScreen extends StatefulWidget {
  const TemplateEditScreen({super.key, this.template});

  final StrengthTemplate? template;

  @override
  State<TemplateEditScreen> createState() => _TemplateEditScreenState();
}

class _Entry {
  _Entry({
    required this.exerciseId,
    required this.name,
    this.sets = 3,
    this.reps = 12,
    this.rest = 60,
    this.weight,
  });

  int exerciseId;
  String name;
  int sets;
  int reps;
  int rest;
  double? weight;
}

class _TemplateEditScreenState extends State<TemplateEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late final List<_Entry> _entries;

  List<StrengthExercise> _exercises = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _name = TextEditingController(text: t?.name ?? '');
    _notes = TextEditingController(text: t?.notes ?? '');
    _entries = [
      for (final e in t?.exercises ?? const <StrengthTemplateExercise>[])
        _Entry(
          exerciseId: e.exerciseId.toInt(),
          name: e.exerciseName,
          sets: e.targetSets.toInt(),
          reps: e.targetReps.toInt(),
          rest: e.restSeconds.toInt(),
          weight: e.targetWeightKg,
        ),
    ];
    _loadExercises();
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadExercises() async {
    final list = await VitaloopApi.strengthExercises();
    if (!mounted) return;
    setState(() => _exercises = list);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('先给模板起个名字');
      return;
    }
    if (_entries.isEmpty) {
      _toast('至少添加一个动作');
      return;
    }
    setState(() => _saving = true);
    try {
      await VitaloopApi.saveStrengthTemplate(
        id: widget.template?.id.toInt() ?? 0,
        name: name,
        notes: _notes.text.trim(),
        exercises: [
          for (final e in _entries)
            StrengthTemplateExerciseInput(
              exerciseId: e.exerciseId,
              targetSets: e.sets,
              targetReps: e.reps,
              restSeconds: e.rest,
              targetWeightKg: e.weight,
              notes: '',
            ),
        ],
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
              title: widget.template == null ? '新建模板' : '编辑模板',
              icon: Icons.fitness_center_rounded,
              iconColor: v.purpleInk,
              trailing: TextButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: tr('模板名称'),
                hintText: tr('例如：推胸日'),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              decoration: InputDecoration(
                labelText: tr('说明（可选）'),
                border: OutlineInputBorder(),
              ),
            ),
            const VSectionHead(title: '动作'),
            if (_entries.isEmpty)
              VCard(
                background: v.tintGrey,
                child: Text(
                  '还没有动作，点下面的「添加动作」从动作库里选。',
                  style: VText.label.copyWith(color: v.muted, height: 1.5),
                ),
              ),
            for (var i = 0; i < _entries.length; i++) _entryCard(i),
            VGhostButton(
              label: '添加动作',
              icon: Icons.add_rounded,
              onTap: _pickExercise,
            ),
            const SizedBox(height: 10),
            VPrimaryButton(
              label: _saving ? '正在保存…' : '保存模板',
              icon: Icons.check_rounded,
              onTap: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryCard(int index) {
    final v = context.v;
    final e = _entries[index];
    final weight = e.weight == null ? '自重' : '${_num(e.weight!)} kg';
    return VCard(
      onTap: () => _editEntry(index),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: v.tintGrey,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${index + 1}',
              style: VText.label.copyWith(
                color: v.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name, style: VText.h3.copyWith(color: v.ink)),
                const SizedBox(height: 3),
                Text(
                  '${e.sets} 组 × ${e.reps} 次 · 休息 ${e.rest} 秒 · $weight',
                  style: VText.meta.copyWith(color: v.muted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _entries.removeAt(index)),
            icon: Icon(Icons.close_rounded, size: 18, color: v.muted),
          ),
        ],
      ),
    );
  }

  Future<void> _pickExercise() async {
    final v = context.v;
    final groups = <String>['全部'];
    for (final e in _exercises) {
      if (!groups.contains(e.muscleGroup)) groups.add(e.muscleGroup);
    }
    var group = '全部';
    final search = TextEditingController();
    final picked = await showModalBottomSheet<StrengthExercise>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final query = search.text.trim().toLowerCase();
          final list = _exercises
              .where((e) => group == '全部' || e.muscleGroup == group)
              .where(
                (e) =>
                    query.isEmpty ||
                    e.name.toLowerCase().contains(query) ||
                    e.muscleGroup.toLowerCase().contains(query) ||
                    e.equipment.toLowerCase().contains(query),
              )
              .toList();
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.78,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 10, 6),
                  child: Row(
                    children: [
                      Text('选择动作', style: VText.h2.copyWith(color: v.ink)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () async {
                          final created = await _newCustomExercise(ctx);
                          if (created != null && ctx.mounted) {
                            Navigator.pop(ctx, created);
                          }
                        },
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('自定义'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                  child: TextField(
                    controller: search,
                    onChanged: (_) => setSheet(() {}),
                    decoration: InputDecoration(
                      hintText: tr('搜索动作名称 / 部位 / 器械'),
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                search.clear();
                                setSheet(() {});
                              },
                            ),
                      isDense: true,
                      filled: true,
                      fillColor: v.isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : v.grey,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: [
                      for (final g in groups)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => setSheet(() => group = g),
                            child: VChip(
                              text: g,
                              background: group == g ? v.tintBlue : v.tintGrey,
                              foreground: group == g ? v.blueInk : v.ink2,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: list.isEmpty
                      ? const VEmpty(
                          title: '没有匹配的动作',
                          subtitle: '换个关键词，或点右上角自定义',
                          icon: Icons.search_off_rounded,
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                          itemCount: list.length,
                          itemBuilder: (ctx, i) {
                            final e = list[i];
                            return VRowItem(
                              icon: Icons.fitness_center_rounded,
                              title: e.name,
                              subtitle: '${e.muscleGroup} · ${e.equipment}',
                              showChevron: true,
                              onTap: () => Navigator.pop(ctx, e),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    search.dispose();
    if (picked == null) return;
    setState(
      () => _entries.add(
        _Entry(exerciseId: picked.id.toInt(), name: picked.name),
      ),
    );
  }

  Future<StrengthExercise?> _newCustomExercise(
    BuildContext sheetContext,
  ) async {
    final name = TextEditingController();
    final muscle = TextEditingController(text: '全身');
    final equipment = TextEditingController(text: '自重');
    final created = await showDialog<bool>(
      context: sheetContext,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义动作'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: tr('名称')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: muscle,
              decoration: InputDecoration(labelText: tr('部位')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: equipment,
              decoration: InputDecoration(labelText: tr('器械')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (created != true) return null;
    try {
      await VitaloopApi.addStrengthExercise(
        name: name.text.trim(),
        muscleGroup: muscle.text.trim(),
        equipment: equipment.text.trim(),
      );
      await _loadExercises();
      for (final e in _exercises) {
        if (e.name == name.text.trim()) return e;
      }
      return null;
    } catch (e) {
      if (mounted) _toast('添加失败：$e');
      return null;
    }
  }

  Future<void> _editEntry(int index) async {
    final v = context.v;
    final e = _entries[index];
    final sets = TextEditingController(text: '${e.sets}');
    final reps = TextEditingController(text: '${e.reps}');
    final rest = TextEditingController(text: '${e.rest}');
    var selectedWeight = e.weight ?? 0.0;
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
              Text(e.name, style: VText.h2.copyWith(color: v.ink)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: _numberField(sets, '组数')),
                  const SizedBox(width: 10),
                  Expanded(child: _numberField(reps, '次数')),
                ],
              ),
              const SizedBox(height: 10),
              _numberField(rest, '休息（秒）'),
              const SizedBox(height: 10),
              VWeightSlider(
                value: selectedWeight,
                onChanged: (value) => setSheet(() => selectedWeight = value),
              ),
              const SizedBox(height: 18),
              VPrimaryButton(
                label: '确定',
                icon: Icons.check_rounded,
                onTap: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      e.sets = int.tryParse(sets.text.trim()) ?? e.sets;
      e.reps = int.tryParse(reps.text.trim()) ?? e.reps;
      e.rest = int.tryParse(rest.text.trim()) ?? e.rest;
      e.weight = selectedWeight <= 0 ? null : selectedWeight;
    });
  }

  Widget _numberField(
    TextEditingController controller,
    String label, {
    bool decimal = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  String _num(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
