import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import 'template_edit_screen.dart';
import 'template_workout_screen.dart';

/// 力量训练模板列表：旧版 StrengthTemplatesScreen 的迁移。
class StrengthTemplatesScreen extends StatefulWidget {
  const StrengthTemplatesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<StrengthTemplatesScreen> createState() =>
      _StrengthTemplatesScreenState();
}

class _StrengthTemplatesScreenState extends State<StrengthTemplatesScreen> {
  List<StrengthTemplate> _templates = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final templates = await VitaloopApi.strengthTemplates();
    if (!mounted) return;
    setState(() {
      _templates = templates;
      _loading = false;
    });
  }

  Future<void> _openEditor([StrengthTemplate? template]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TemplateEditScreen(template: template)),
    );
    if (changed == true) _load();
  }

  Future<void> _start(StrengthTemplate template) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            TemplateWorkoutScreen(state: widget.state, template: template),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(StrengthTemplate template) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板？'),
        content: Text('「${template.name}」删除后不可恢复，已完成的训练记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await VitaloopApi.deleteStrengthTemplate(template.id);
    await _load();
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
              title: '力量训练',
              icon: Icons.fitness_center_rounded,
              iconColor: v.purpleInk,
              trailing: VIconButton(
                icon: Icons.add_rounded,
                onTap: () => _openEditor(),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_templates.isEmpty) ...[
              const VEmpty(
                title: '还没有训练模板',
                subtitle: '把常练的动作、组数和重量存成模板，下次直接照着做。',
                icon: Icons.fitness_center_rounded,
              ),
              VPrimaryButton(
                label: '新建模板',
                icon: Icons.add_rounded,
                onTap: () => _openEditor(),
              ),
            ] else ...[
              for (final t in _templates) _card(t),
              VPrimaryButton(
                label: '新建模板',
                icon: Icons.add_rounded,
                onTap: () => _openEditor(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card(StrengthTemplate t) {
    final v = context.v;
    final sets = t.exercises.fold<int>(
      0,
      (sum, e) => sum + e.targetSets.toInt(),
    );
    return VCard(
      onTap: () => _start(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              VIconBox(
                icon: Icons.fitness_center_rounded,
                background: v.purple.withValues(alpha: 0.35),
                foreground: v.purpleInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name, style: VText.h3.copyWith(color: v.ink)),
                    if (t.notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          t.notes,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: VText.meta.copyWith(color: v.muted),
                        ),
                      ),
                  ],
                ),
              ),
              VIconButton(
                icon: Icons.edit_rounded,
                onTap: () => _openEditor(t),
              ),
              const SizedBox(width: 6),
              VIconButton(
                icon: Icons.delete_outline_rounded,
                onTap: () => _delete(t),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              VChip(
                text: '${t.exercises.length} 个动作',
                background: v.tintGrey,
                foreground: v.ink2,
              ),
              const SizedBox(width: 6),
              VChip(
                text: '$sets 组',
                background: v.tintGrey,
                foreground: v.ink2,
              ),
              const SizedBox(width: 6),
              Text(
                fmtDuration(_plannedSeconds(t)),
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t.exercises
                .map((e) => e.exerciseName)
                .where((n) => n.isNotEmpty)
                .join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: VText.label.copyWith(color: v.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  int _plannedSeconds(StrengthTemplate t) {
    var seconds = 0;
    for (final e in t.exercises) {
      seconds +=
          e.targetSets.toInt() *
          (e.restSeconds.toInt() + e.targetReps.toInt() * 4);
    }
    return seconds;
  }
}
