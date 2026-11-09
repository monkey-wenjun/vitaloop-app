import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 我的装备。以前是设置页里弹出来的只读列表：既不能加装备，也没有更换提醒。
/// 已用里程 = 同类型运动的累计里程 − 登记时填的起始里程，全部来自真实运动记录，不另记一套账。
class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({super.key});

  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  static const _sports = [
    'outdoor_run',
    'cycling',
    'walk',
    'hiking',
    'swim',
    'strength',
    'other',
  ];
  static const _gearTypes = [
    ('shoes', '鞋子'),
    ('jersey', '骑行服'),
    ('shorts', '骑行裤'),
    ('bike', '自行车'),
    ('hr_strap', '心率带'),
    ('watch', '手表'),
    ('helmet', '头盔'),
    ('gloves', '手套'),
    ('glasses', '眼镜'),
  ];

  List<Equipment> _items = const [];
  List<WorkoutSummary> _workouts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      VitaloopApi.equipment(),
      VitaloopApi.workouts(limit: 2000),
    ]);
    if (!mounted) return;
    setState(() {
      _items = results[0] as List<Equipment>;
      _workouts = results[1] as List<WorkoutSummary>;
      _loading = false;
    });
  }

  /// 按类型展示名汇总：装备选类型时走同一张 sportName 表，
  /// 否则「户外跑步」和「跑步」各算各的，里程永远对不上。
  Map<String, ({double km, int count})> get _totals {
    final out = <String, ({double km, int count})>{};
    for (final w in _workouts) {
      final name = sportName(w.sport);
      final cur = out[name] ?? (km: 0, count: 0);
      out[name] = (km: cur.km + w.distanceM / 1000.0, count: cur.count + 1);
    }
    return out;
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
              title: '我的装备',
              icon: Icons.hiking_rounded,
              iconColor: v.blue,
              trailing: VIconButton(
                icon: Icons.add_rounded,
                onTap: () => _form(),
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty) ...[
              const VEmpty(
                title: '还没有登记装备',
                subtitle: '加一双跑鞋或一组骑行装备，App 会按同类型运动的累计里程提醒更换。',
                icon: Icons.hiking_rounded,
              ),
              VPrimaryButton(
                label: '添加装备',
                icon: Icons.add_rounded,
                onTap: () => _form(),
              ),
            ] else ...[
              for (final e in _items) _card(e),
            ],
            const VSectionHead(title: '里程怎么算'),
            VCard(
              background: v.tintGrey,
              child: Text(
                '已用里程 = 该运动类型的历史累计里程 − 登记时填写的起始里程。'
                '里程取自各次运动的 GPS 或计步换算，因此改起始里程或补录运动记录，已用里程都会同步变化；'
                '同一类型多件装备会各自从自己的起始里程算起，不会互相扣减。',
                style: VText.label.copyWith(color: v.muted, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(Equipment e) {
    final v = context.v;
    final total = _totals[sportName(e.sport)] ?? (km: 0.0, count: 0);
    final used = (total.km - e.startKm).clamp(0.0, double.infinity).toDouble();
    final ratio = e.limitKm <= 0
        ? 0.0
        : (used / e.limitKm).clamp(0.0, 1.0).toDouble();
    final left = e.limitKm - used;
    final due = left <= 0;
    final accent = due ? v.danger : (ratio >= 0.8 ? v.warnInk : v.greenInk);
    return VCard(
      onTap: () => _form(e),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              VIconBox(
                icon: _sportIcon(e.sport),
                background: accent.withValues(alpha: 0.14),
                foreground: accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VText.h3.copyWith(color: v.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _gearLabel(e.gearType),
                        if (e.brand.isNotEmpty) e.brand,
                        if (e.model.isNotEmpty) e.model,
                        if (!e.isActive) '已退役',
                      ].join(' · '),
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: e.isActive ? v.muted : v.danger,
                      ),
                    ),
                  ],
                ),
              ),
              VChip(
                text: due ? '该更换了' : '剩 ${left.toStringAsFixed(0)} km',
                background: accent.withValues(alpha: 0.14),
                foreground: accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                used.toStringAsFixed(1),
                style: VText.h1.copyWith(fontSize: 28, color: v.ink),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(
                  'km 已用 · 建议 ${e.limitKm.toStringAsFixed(0)} km',
                  style: VText.label.copyWith(color: v.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: v.tintGrey,
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '该类型累计 ${total.km.toStringAsFixed(1)} km · ${total.count} 次 · 起始 ${e.startKm.toStringAsFixed(1)} km',
            style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
          ),
          if (e.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              e.note,
              style: VText.label.copyWith(color: v.ink2, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  IconData _sportIcon(String sport) => switch (sport) {
    'outdoor_run' => Icons.directions_run_rounded,
    'cycling' => Icons.directions_bike_rounded,
    'walk' => Icons.directions_walk_rounded,
    'hiking' => Icons.terrain_rounded,
    'swim' => Icons.pool_rounded,
    'strength' => Icons.fitness_center_rounded,
    _ => Icons.hiking_rounded,
  };

  String _gearLabel(String type) {
    for (final entry in _gearTypes) {
      if (entry.$1 == type) return entry.$2;
    }
    return '装备';
  }

  void _form([Equipment? existing]) {
    final v = context.v;
    final name = TextEditingController(text: existing?.name ?? '');
    final brand = TextEditingController(text: existing?.brand ?? '');
    final model = TextEditingController(text: existing?.model ?? '');
    final start = TextEditingController(
      text: (existing?.startKm ?? (_totals[sportName('outdoor_run')]?.km ?? 0))
          .toStringAsFixed(1),
    );
    final limit = TextEditingController(
      text: (existing?.limitKm ?? 800).toStringAsFixed(0),
    );
    final note = TextEditingController(text: existing?.note ?? '');
    var sport = existing?.sport ?? 'outdoor_run';
    var gearType = existing?.gearType ?? 'shoes';
    var purchase = existing != null && existing.purchaseMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(existing.purchaseMs)
        : null;
    var active = existing?.isActive ?? true;
    var error = '';

    showModalBottomSheet(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> save() async {
            final startKm = double.tryParse(start.text.trim()) ?? 0.0;
            final limitKm = double.tryParse(limit.text.trim()) ?? 0.0;
            try {
              if (existing == null) {
                await VitaloopApi.addEquipment(
                  name: name.text,
                  sport: sport,
                  gearType: gearType,
                  brand: brand.text,
                  model: model.text,
                  purchaseMs: purchase?.millisecondsSinceEpoch ?? 0,
                  isActive: active,
                  startKm: startKm,
                  limitKm: limitKm,
                  note: note.text,
                );
              } else {
                await VitaloopApi.updateEquipment(
                  id: existing.id,
                  name: name.text,
                  sport: sport,
                  gearType: gearType,
                  brand: brand.text,
                  model: model.text,
                  purchaseMs: purchase?.millisecondsSinceEpoch ?? 0,
                  isActive: active,
                  startKm: startKm,
                  limitKm: limitKm,
                  note: note.text,
                );
              }
            } catch (e) {
              setSheet(() => error = '$e'.replaceFirst('Exception: ', ''));
              return;
            }
            if (ctx.mounted) Navigator.pop(ctx);
            await _load();
          }

          void pickSport(String value) {
            setSheet(() => sport = value);
            // 新装备默认从「当前累计」起算，也就是已用 0 km；编辑时不动用户填过的值
            if (existing == null) {
              start.text = (_totals[sportName(value)]?.km ?? 0).toStringAsFixed(
                1,
              );
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              2,
              20,
              MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existing == null ? '添加装备' : '编辑装备',
                    style: VText.h2.copyWith(color: v.ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '名称自己起；装备类型用于分类，里程类型决定用哪一类运动记录累计里程。',
                    style: VText.meta.copyWith(color: v.muted),
                  ),
                  const SizedBox(height: 14),
                  _field(
                    Icons.label_outline_rounded,
                    '名称',
                    name,
                    hint: '例如：飞电 3 Elite',
                  ),
                  const SizedBox(height: 10),
                  Text('装备类型', style: VText.label.copyWith(color: v.muted)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final entry in _gearTypes)
                        GestureDetector(
                          onTap: () => setSheet(() => gearType = entry.$1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: gearType == entry.$1
                                  ? v.purple.withValues(alpha: 0.12)
                                  : v.tintGrey,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: gearType == entry.$1
                                    ? v.purple.withValues(alpha: 0.4)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Text(
                              entry.$2,
                              style: VText.label.copyWith(
                                color: gearType == entry.$1
                                    ? v.purpleInk
                                    : v.ink2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          Icons.business_rounded,
                          '品牌',
                          brand,
                          hint: 'Nike',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _field(
                          Icons.qr_code_rounded,
                          '型号',
                          model,
                          hint: 'Vaporfly 3',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: purchase ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setSheet(() => purchase = picked);
                    },
                    child: _field(
                      Icons.event_rounded,
                      '购入时间',
                      TextEditingController(
                        text: purchase == null
                            ? ''
                            : '${purchase!.year}-${purchase!.month.toString().padLeft(2, '0')}-${purchase!.day.toString().padLeft(2, '0')}',
                      ),
                      hint: '点击选择',
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text('使用中', style: VText.meta.copyWith(color: v.ink)),
                      const Spacer(),
                      Switch(
                        value: active,
                        onChanged: (on) => setSheet(() => active = on),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('里程累计类型', style: VText.label.copyWith(color: v.muted)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final s in _sports)
                        GestureDetector(
                          onTap: () => pickSport(s),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: sport == s
                                  ? v.blue.withValues(alpha: 0.12)
                                  : v.tintGrey,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: sport == s
                                    ? v.blue.withValues(alpha: 0.4)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Text(
                              sportName(s),
                              style: VText.label.copyWith(
                                color: sport == s ? v.blue : v.ink2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _field(
                    Icons.speed_rounded,
                    '起始里程 (km)',
                    start,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _field(
                    Icons.autorenew_rounded,
                    '建议更换里程 (km)',
                    limit,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _field(
                    Icons.notes_rounded,
                    '备注（可选）',
                    note,
                    hint: '例如：2026 年 3 月买的，走路开始有点偏',
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      error,
                      style: VText.label.copyWith(color: v.danger, height: 1.5),
                    ),
                  ],
                  const SizedBox(height: 16),
                  VPrimaryButton(
                    label: existing == null ? '保存' : '保存修改',
                    icon: Icons.check_rounded,
                    onTap: save,
                  ),
                  if (existing != null) ...[
                    const SizedBox(height: 8),
                    VGhostButton(
                      label: '删除这件装备',
                      icon: Icons.delete_outline_rounded,
                      onTap: () => _confirmDelete(ctx, existing),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext sheetCtx, Equipment e) async {
    final ok = await showDialog<bool>(
      context: sheetCtx,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${e.name}」？'),
        content: const Text('只删除这条装备登记，运动记录不受影响。'),
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
    await VitaloopApi.deleteEquipment(e.id);
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    await _load();
  }

  Widget _field(
    IconData icon,
    String label,
    TextEditingController controller, {
    String? hint,
    TextInputType? keyboardType,
    bool readOnly = false,
  }) {
    final v = context.v;
    return Container(
      decoration: BoxDecoration(
        color: v.bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: v.line),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: v.muted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              readOnly: readOnly,
              style: VText.meta.copyWith(
                fontSize: 13.5,
                color: v.ink,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                labelText: label,
                labelStyle: VText.label.copyWith(color: v.muted),
                hintText: hint,
                hintStyle: VText.meta.copyWith(fontSize: 12.5, color: v.muted),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.only(top: 14, bottom: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
