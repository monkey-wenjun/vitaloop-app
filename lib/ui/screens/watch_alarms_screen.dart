import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/watch_bridge.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class WatchAlarmsScreen extends StatefulWidget {
  const WatchAlarmsScreen({super.key});

  @override
  State<WatchAlarmsScreen> createState() => _WatchAlarmsScreenState();
}

class _WatchAlarmsScreenState extends State<WatchAlarmsScreen> {
  List<WatchAlarm> _alarms = const [];
  bool _loading = true;
  bool _saving = false;
  bool _holidaySkip = true;
  bool _todayWorkday = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final alarms = await WatchBridge.instance.alarms();
    final holidaySkip = await WatchBridge.instance.holidaySkipEnabled();
    final todayWorkday = await WatchBridge.instance.todayWorkday();
    if (!mounted) return;
    setState(() {
      _alarms = [...alarms]..sort((a, b) => a.index.compareTo(b.index));
      _holidaySkip = holidaySkip;
      _todayWorkday = todayWorkday;
      _loading = false;
    });
  }

  Future<void> _toggleHolidaySkip(bool enabled) async {
    setState(() => _holidaySkip = enabled);
    final ok = await WatchBridge.instance.setHolidaySkipEnabled(enabled);
    if (!mounted) return;
    if (!ok) {
      setState(() => _holidaySkip = !enabled);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请先连接手表')));
      return;
    }
    final todayWorkday = await WatchBridge.instance.todayWorkday();
    if (!mounted) return;
    setState(() => _todayWorkday = todayWorkday);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(enabled ? '休息日会自动跳过闹钟' : '闹钟每天照常响铃')),
    );
  }

  Future<void> _save(List<WatchAlarm> next, String message) async {
    setState(() {
      _alarms = [...next]..sort((a, b) => a.index.compareTo(b.index));
      _saving = true;
    });
    final ok = await WatchBridge.instance.saveAlarms(next);
    if (!mounted) return;
    setState(() => _saving = false);
    final ready = WatchBridge.instance.state.value == 'ready';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          !ok
              ? '保存失败，请先连接手表'
              : ready
              ? '$message，正在同步到手表'
              : '$message，连接手表后自动同步',
        ),
      ),
    );
  }

  Future<void> _add() async {
    final used = _alarms.where((a) => !a.isSmart).map((a) => a.index).toSet();
    int? index;
    for (final i in [1, 2, 3, 4, 5]) {
      if (!used.contains(i)) {
        index = i;
        break;
      }
    }
    if (index == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('最多只能设置 5 个闹钟')));
      return;
    }
    final alarm = await _edit(
      WatchAlarm(
        index: index,
        enabled: true,
        hour: 7,
        minute: 30,
        repeatMask: 0x7f,
        label: '闹钟',
      ),
    );
    if (alarm == null) return;
    await _save([..._alarms, alarm], '闹钟已添加');
  }

  Future<void> _toggle(WatchAlarm alarm, bool enabled) async {
    final next = [
      for (final item in _alarms)
        if (item.index == alarm.index)
          item.copyWith(enabled: enabled)
        else
          item,
    ];
    await _save(next, enabled ? '闹钟已开启' : '闹钟已关闭');
  }

  Future<void> _delete(WatchAlarm alarm) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.v.surface,
        title: Text('删除闹钟', style: VText.h2.copyWith(color: ctx.v.ink)),
        content: Text(
          '确定删除 ${alarm.timeLabel} 的闹钟？',
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
    if (ok != true) return;
    await _save(_alarms.where((a) => a.index != alarm.index).toList(), '闹钟已删除');
  }

  Future<WatchAlarm?> _edit(WatchAlarm alarm) async {
    final v = context.v;
    var hour = alarm.hour;
    var minute = alarm.minute;
    var repeatMask = alarm.repeatMask;
    final labelController = TextEditingController(text: alarm.label);
    String two(int n) => n.toString().padLeft(2, '0');
    final result = await showModalBottomSheet<WatchAlarm>(
      context: context,
      isScrollControlled: true,
      backgroundColor: v.surface,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final repeatBits = [
            (0, '一'),
            (1, '二'),
            (2, '三'),
            (3, '四'),
            (4, '五'),
            (5, '六'),
            (6, '日'),
          ];
          return SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                0,
                18,
                18 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alarm.isSmart ? '编辑智能唤醒' : '编辑闹钟',
                    style: VText.h2.copyWith(color: v.ink),
                  ),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay(hour: hour, minute: minute),
                        helpText: '选择闹钟时间',
                      );
                      if (picked == null) return;
                      setSheet(() {
                        hour = picked.hour;
                        minute = picked.minute;
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color: v.isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : v.grey,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: [
                          Text(
                            '${two(hour)}:${two(minute)}',
                            style: VText.big.copyWith(
                              fontSize: 46,
                              color: v.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '点按修改时间',
                            style: VText.label.copyWith(color: v.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!alarm.isSmart) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: labelController,
                      maxLength: 12,
                      decoration: InputDecoration(
                        labelText: tr('名称'),
                        counterText: '',
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text('重复', style: VText.h3.copyWith(color: v.ink)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final (bit, name) in repeatBits)
                        FilterChip(
                          label: Text('周$name'),
                          selected: repeatMask & (1 << bit) != 0,
                          onSelected: (selected) => setSheet(() {
                            repeatMask = selected
                                ? repeatMask | (1 << bit)
                                : repeatMask & ~(1 << bit);
                          }),
                        ),
                      ActionChip(
                        label: const Text('每天'),
                        onPressed: () => setSheet(() => repeatMask = 0x7f),
                      ),
                      ActionChip(
                        label: const Text('仅一次'),
                        onPressed: () => setSheet(() => repeatMask = 0),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  VPrimaryButton(
                    label: '保存',
                    icon: Icons.check_rounded,
                    onTap: () => Navigator.pop(
                      ctx,
                      alarm.copyWith(
                        hour: hour,
                        minute: minute,
                        repeatMask: repeatMask,
                        label: alarm.isSmart
                            ? '智能唤醒'
                            : labelController.text.trim().isEmpty
                            ? '闹钟'
                            : labelController.text.trim(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    labelController.dispose();
    return result;
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
              title: '闹钟',
              trailing: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            ValueListenableBuilder<String>(
              valueListenable: WatchBridge.instance.state,
              builder: (context, state, _) {
                final ready = state == 'ready';
                return VCard(
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: ready ? v.tintGreen : v.tintPeach,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          ready ? Icons.watch_rounded : Icons.watch_off_rounded,
                          size: 20,
                          color: ready ? v.greenInk : v.warnInk,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ready ? '手表已连接' : '手表未连接',
                              style: VText.h3.copyWith(color: v.ink),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              ready ? '修改后会自动同步到手表' : '修改先存本机，下次连接时补发',
                              style: VText.label.copyWith(color: v.muted),
                            ),
                          ],
                        ),
                      ),
                      if (ready)
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () async {
                                  await WatchBridge.instance.syncAlarms();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已请求同步闹钟')),
                                    );
                                  }
                                },
                          child: const Text('同步'),
                        ),
                    ],
                  ),
                );
              },
            ),
            VCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: VRowItem(
                icon: Icons.event_busy_rounded,
                iconBackground: v.tintPeach,
                iconColor: v.warnInk,
                title: '智能跳过休息日',
                subtitle: '周末与法定节假日不响，调休上班日照常',
                trailing: Switch.adaptive(
                  value: _holidaySkip,
                  activeThumbColor: v.blue,
                  onChanged: _toggleHolidaySkip,
                ),
              ),
            ),
            if (!_todayWorkday)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text(
                  '今日休息（周末/节假日），闹钟已自动跳过',
                  style: VText.label.copyWith(color: v.danger),
                ),
              ),
            const VSectionHead(title: '闹钟列表'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_alarms.isEmpty)
              const VEmpty(
                title: '还没有闹钟',
                subtitle: '点下方按钮添加，保存后会同步到手表',
                icon: Icons.alarm_add_rounded,
              )
            else
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    for (final alarm in _alarms)
                      _AlarmRow(
                        alarm: alarm,
                        onTap: () async {
                          final edited = await _edit(alarm);
                          if (edited == null) return;
                          await _save([
                            for (final item in _alarms)
                              if (item.index == alarm.index) edited else item,
                          ], '闹钟已更新');
                        },
                        onToggle: (value) => _toggle(alarm, value),
                        onDelete: alarm.isSmart ? null : () => _delete(alarm),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            VPrimaryButton(
              label: '添加闹钟',
              icon: Icons.add_alarm_rounded,
              onTap: _loading ? null : _add,
            ),
            const SizedBox(height: 10),
            Text(
              '普通闹钟最多 5 个；智能唤醒由手表提供，仅在支持该功能时显示。',
              textAlign: TextAlign.center,
              style: VText.label.copyWith(color: v.muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmRow extends StatelessWidget {
  const _AlarmRow({
    required this.alarm,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  final WatchAlarm alarm;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 86,
              child: Text(
                alarm.timeLabel,
                style: VText.value.copyWith(
                  fontSize: 25,
                  color: alarm.enabled ? v.ink : v.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          alarm.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: VText.h3.copyWith(
                            color: alarm.enabled ? v.ink : v.muted,
                          ),
                        ),
                      ),
                      if (alarm.isSmart) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: v.tintPurple,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '智能',
                            style: VText.label.copyWith(
                              fontSize: 9,
                              color: v.purpleInk,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    alarm.isSmart
                        ? '提前 ${alarm.smartWakeupIntervalMinutes ?? 5} 分钟唤醒 · ${alarm.repeatLabel}'
                        : alarm.repeatLabel,
                    style: VText.label.copyWith(color: v.muted),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: alarm.enabled,
              activeThumbColor: v.blue,
              onChanged: onToggle,
            ),
            if (onDelete != null)
              IconButton(
                tooltip: tr('删除'),
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 19,
                  color: v.muted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
