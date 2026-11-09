import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';
import 'strength_templates_screen.dart';
import 'workout_recorder_screen.dart';

/// 力量训练首页：旧版 StrengthHomeScreen 的迁移。
///
/// 一条路是不带计划的自由训练，只记时长、心率和卡路里；另一条路按模板
/// 逐组记录重量和次数。之前新版点「力量」直接进模板列表，自由训练没有入口。
class StrengthHomeScreen extends StatelessWidget {
  const StrengthHomeScreen({super.key, required this.state});

  final AppState state;

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
            const VDetailHeader(
              title: '力量训练',
              icon: Icons.fitness_center_rounded,
              iconColor: Color(0xFF8C6BD8),
            ),
            VCard(
              background: v.purple,
              foreground: v.purpleInk,
              onTap: () => _openFree(context),
              child: Row(
                children: [
                  const VIconBox(
                    icon: Icons.play_arrow_rounded,
                    background: Colors.white54,
                    foreground: Color(0xFF5B3FA8),
                    size: 46,
                    radius: 15,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自由训练',
                          style: VText.h3.copyWith(
                            fontSize: 16,
                            color: v.purpleInk,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '不套模板，只记录时长、心率和卡路里',
                          style: VText.label.copyWith(
                            fontSize: 10.5,
                            color: v.purpleInk.withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: v.purpleInk.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
            VCard(
              onTap: () => _openTemplates(context),
              child: Row(
                children: [
                  VIconBox(
                    icon: Icons.checklist_rounded,
                    background: v.tintPurple,
                    foreground: v.purpleInk,
                    size: 46,
                    radius: 15,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '按模板训练',
                          style: VText.h3.copyWith(fontSize: 16, color: v.ink),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '按动作、组数、重量和组间休息逐组跟练',
                          style: VText.label.copyWith(
                            fontSize: 10.5,
                            color: v.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: v.muted.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openFree(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkoutRecorderScreen(
          state: state,
          sport: '力量训练',
          title: '力量训练',
          icon: Icons.fitness_center_rounded,
        ),
      ),
    );
  }

  void _openTemplates(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StrengthTemplatesScreen(state: state)),
    );
  }
}
