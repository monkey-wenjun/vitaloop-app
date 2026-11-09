import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/watch_bridge.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 手表连接/同步日志详情页：原生层每条状态变化、每轮同步窗口都会写一行，
/// 这里按天分组展开，排查「为什么没同步上」不用再靠内存里的状态字符串猜。
class WatchLogsScreen extends StatefulWidget {
  const WatchLogsScreen({super.key, required this.state});

  final AppState state;

  @override
  State<WatchLogsScreen> createState() => _WatchLogsScreenState();
}

class _WatchLogsScreenState extends State<WatchLogsScreen> {
  Timer? _timer;
  List<WatchLog> _logs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    // 原生日志是随同步轮次产生的，页面开着就该自己长出来
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final logs = await VitaloopApi.watchLogs(limit: 500);
      if (mounted) setState(() => _logs = logs);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final bridge = WatchBridge.instance;
    final device = widget.state.primaryDevice;
    final lastSync =
        bridge.lastSync.value?.millisecondsSinceEpoch ?? device?.lastSyncMs;
    return AnimatedBuilder(
      animation: bridge.state,
      builder: (context, _) {
        final rows = _groupByDay(_logs);
        return Scaffold(
          backgroundColor: v.bg,
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                VDetailHeader(
                  title: '连接日志',
                  trailing: VIconButton(
                    icon: Icons.refresh_rounded,
                    onTap: _load,
                  ),
                ),
                VCard(
                  background: bridge.state.value == 'ready' ? v.green : v.sky,
                  foreground: bridge.state.value == 'ready'
                      ? v.greenInk
                      : v.skyInk,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device?.name ?? '未记录设备',
                        style: VText.value.copyWith(
                          fontSize: 18,
                          color: (bridge.state.value == 'ready'
                              ? v.greenInk
                              : v.skyInk),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '当前状态：${bridge.state.value}　·　最后一次同步：${lastSync == null ? '尚无记录' : _full(DateTime.fromMillisecondsSinceEpoch(lastSync))}',
                        style: VText.label.copyWith(
                          fontSize: 10.5,
                          color:
                              (bridge.state.value == 'ready'
                                      ? v.greenInk
                                      : v.skyInk)
                                  .withValues(alpha: 0.8),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading && rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 120),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (rows.isEmpty)
                  const VEmpty(
                    title: '还没有连接日志',
                    subtitle: '日志来自原生连接与同步流程：发起一次连接或等一轮自动同步后，这里会出现逐条记录。',
                    icon: Icons.receipt_long_rounded,
                  )
                else ...[
                  VSectionHead(title: '按天展开', trailing: '${_logs.length} 条'),
                  for (final group in rows) ...[
                    VSectionHead(
                      title: _dayTitle(group.$1),
                      trailing: '${group.$2.length} 条',
                    ),
                    VCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Column(
                        children: [
                          for (final log in group.$2) _LogRow(log: log),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// (当天 0 点, 该天日志) 列表，日志本身已按时间倒序，分组后顺序自然保持。
  List<(DateTime, List<WatchLog>)> _groupByDay(List<WatchLog> logs) {
    final out = <DateTime, List<WatchLog>>{};
    for (final log in logs) {
      final d = DateTime.fromMillisecondsSinceEpoch(log.tsMs);
      final key = DateTime(d.year, d.month, d.day);
      (out[key] ??= []).add(log);
    }
    final entries = out.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return entries.map((e) => (e.key, e.value)).toList();
  }

  String _dayTitle(DateTime day) {
    final today = DateTime.now();
    final diff = DateTime(
      today.year,
      today.month,
      today.day,
    ).difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${day.month}月${day.day}日 ${weekday(day)}';
  }

  String _full(DateTime d) =>
      '${d.month}月${d.day}日 ${clock(d)}:${two(d.second)}';
}

/// 日志正文普遍比一行长，这里不省略，让它自然换行；左侧只放时分秒做时间轴。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.log});

  final WatchLog log;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final msg = log.msg;
    final bad = msg.contains('失败') || msg.contains('错误');
    final good = msg.startsWith('同步完成');
    final accent = bad ? v.heartInk : (good ? v.greenInk : v.blueInk);
    final at = DateTime.fromMillisecondsSinceEpoch(log.tsMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 46,
              child: Text(
                clock(at),
                style: VText.meta.copyWith(
                  fontSize: 11,
                  color: v.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Container(
              width: 2.5,
              margin: const EdgeInsets.only(right: 11, top: 2),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Text(
                msg,
                style: VText.body.copyWith(
                  fontSize: 12,
                  color: bad || good ? accent : v.ink2,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
