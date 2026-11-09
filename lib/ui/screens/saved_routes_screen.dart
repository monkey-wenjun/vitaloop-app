import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../state/app_state.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';
import 'sport_tools_screen.dart';
import 'workout_recorder_screen.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

/// 已保存路线：旧版 SavedRoutesScreen 的迁移。
class SavedRoutesScreen extends StatefulWidget {
  const SavedRoutesScreen({super.key, required this.state});

  final AppState state;

  @override
  State<SavedRoutesScreen> createState() => _SavedRoutesScreenState();
}

class _SavedRoutesScreenState extends State<SavedRoutesScreen> {
  List<SavedRoute> _routes = const [];
  bool _loading = true;
  String? _pushingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final routes = await VitaloopApi.savedRoutes();
    if (!mounted) return;
    setState(() {
      _routes = routes;
      _loading = false;
    });
  }

  Future<void> _newRoute() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const RoutePlannerScreen()));
    if (saved == true) _load();
  }

  Future<void> _edit(SavedRoute route) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RoutePlannerScreen(route: route)),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(SavedRoute route) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除路线？'),
        content: Text('「${route.name}」删除后不可恢复。'),
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
    await VitaloopApi.deleteRoute(route.id);
    await _load();
  }

  Future<void> _push(SavedRoute route) async {
    if (_pushingId != null) return;
    setState(() => _pushingId = route.id);
    final result = await WatchBridge.instance.pushRoute(
      name: route.name,
      distanceMeters: route.distanceM,
      points: route.points,
    );
    if (!mounted) return;
    setState(() => _pushingId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result['message'] as String? ?? '路线发送完成')),
    );
  }

  Future<void> _navigate(SavedRoute route) async {
    final choice = await showModalBottomSheet<(String, String, IconData)>(
      context: context,
      backgroundColor: context.v.surface,
      showDragHandle: true,
      builder: (ctx) {
        final v = ctx.v;
        Widget item(String sport, String title, IconData icon) => ListTile(
          leading: Icon(icon, color: v.greenInk),
          title: Text('$title导航', style: VText.h3.copyWith(color: v.ink)),
          subtitle: Text(
            '沿「${route.name}」前进并播报转向',
            style: VText.label.copyWith(color: v.muted),
          ),
          onTap: () => Navigator.pop(ctx, (sport, title, icon)),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text('选择导航方式', style: VText.h2.copyWith(color: v.ink)),
                  subtitle: Text(
                    route.name,
                    style: VText.meta.copyWith(color: v.muted),
                  ),
                ),
                item('户外跑步', '跑步', Icons.directions_run_rounded),
                item('骑行', '骑行', Icons.route_rounded),
                item('徒步', '徒步', Icons.place_rounded),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    final (sport, title, icon) = choice;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkoutRecorderScreen(
          state: widget.state,
          sport: sport,
          title: title,
          icon: icon,
          route: route,
        ),
      ),
    );
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
              title: '已保存路线',
              icon: Icons.alt_route_rounded,
              iconColor: v.greenInk,
              trailing: VIconButton(icon: Icons.add_rounded, onTap: _newRoute),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_routes.isEmpty) ...[
              const VEmpty(
                title: '还没有保存路线',
                subtitle: '在地图上点出起点、途经点和终点，保存后可随时复用。',
                icon: Icons.alt_route_rounded,
              ),
              VPrimaryButton(
                label: '规划一条路线',
                icon: Icons.add_rounded,
                onTap: _newRoute,
              ),
            ] else ...[
              for (final r in _routes) _card(r),
              VPrimaryButton(
                label: '规划新路线',
                icon: Icons.add_rounded,
                onTap: _newRoute,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card(SavedRoute r) {
    final v = context.v;
    final date = DateTime.fromMillisecondsSinceEpoch(r.createdMs);
    return VCard(
      onTap: () => _edit(r),
      child: Row(
        children: [
          VIconBox(
            icon: Icons.alt_route_rounded,
            background: v.tintGreen,
            foreground: v.greenInk,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name, style: VText.h3.copyWith(color: v.ink)),
                const SizedBox(height: 3),
                Text(
                  '${(r.distanceM / 1000).toStringAsFixed(2)} km · ${r.points.length} 个点 · ${relativeDay(date)}',
                  style: VText.meta.copyWith(color: v.muted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _navigate(r),
            tooltip: tr('开始导航'),
            icon: Icon(Icons.navigation_rounded, size: 18, color: v.greenInk),
          ),
          IconButton(
            onPressed: _pushingId == null ? () => _push(r) : null,
            tooltip: tr('发送到手表'),
            icon: _pushingId == r.id
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.watch_rounded, size: 18, color: v.blueInk),
          ),
          IconButton(
            onPressed: () => _delete(r),
            icon: Icon(Icons.delete_outline_rounded, size: 18, color: v.muted),
          ),
        ],
      ),
    );
  }
}
