import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/api.dart';
import '../../data/ble_bridge.dart';
import '../../state/app_state.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/health_reference.dart';
import '../../util/range_buckets.dart';
import '../components.dart';
import '../metric_icon.dart';
import '../nav.dart';
import 'activity_rings_screen.dart';

import 'package:vitaloop/l10n/ui_translations.dart';

class MetricDetailScreen extends StatefulWidget {
  const MetricDetailScreen({
    super.key,
    required this.metric,
    this.title,
    this.color,
    this.days = 30,
    this.state,
  });

  final String metric;
  final String? title;
  final Color? color;
  final int days;
  final AppState? state;

  @override
  State<MetricDetailScreen> createState() => _MetricDetailScreenState();
}

class _MetricDetailScreenState extends State<MetricDetailScreen> {
  static const _sumMetrics = {
    'steps',
    'calories',
    'active_calories',
    'distance',
    'active_minutes',
    'exercise_minutes',
  };
  // 最大摄氧量按次估算，日粒度只会看到单次跑步的波动；至少按月才有参考价值。
  static const _vo2RangeLabels = ['周', '月', '半年', '年'];
  static const _vo2RangeDays = [7, 30, 182, 365];

  int _range = 2;
  late Future<MetricDetail> _future;
  List<BloodPressureEntry> _bp = const [];
  List<GlucoseEntry> _glucose = const [];
  List<WeightEntry> _weights = const [];
  MetricDetail? _resting;
  bool _showAllRecords = false;

  final _ble = BleBridge.instance;
  bool _scalePermissionDenied = false;
  bool _scaleConnecting = false;
  bool _scaleScanning = false;
  bool _scaleScanStarting = false;
  Timer? _scaleScanTimer;
  Timer? _scaleAutoConnectTimer;
  int _scaleLastAttemptMs = 0;

  int get _days =>
      widget.metric == 'vo2max' ? _vo2RangeDays[_range] : rangeDays[_range];

  /// 未裁剪时间窗的全量手动记录，用来区分「这个指标根本没数据」和「这个窗口里恰好没有」。
  /// 统一按时间倒序，`.first` 就是最近一次。
  List<(int, double)> get _allRecords => switch (widget.metric) {
    'bp' => _desc([
      for (final e in _bp) (e.timestampMs, e.systolic.toDouble()),
    ]),
    'glucose' => _desc([for (final e in _glucose) (e.timestampMs, e.value)]),
    'weight' => _desc([for (final e in _weights) (e.timestampMs, e.weightKg)]),
    _ => const [],
  };

  static List<(int, double)> _desc(List<(int, double)> items) =>
      items..sort((a, b) => b.$1.compareTo(a.$1));

  /// 手动记录之外（例如按次估算的最大摄氧量），Rust 侧会带回最近若干条采样。
  (int, double)? _lastKnown(MetricDetail detail) {
    if (_allRecords.isNotEmpty) return _allRecords.first;
    final samples = detail.samples;
    if (samples.isEmpty) return null;
    final newest = samples.reduce(
      (a, b) => a.timestampMs >= b.timestampMs ? a : b,
    );
    return (newest.timestampMs, newest.value);
  }

  DateTime get _rangeStart {
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: _days - 1));
  }

  @override
  void initState() {
    super.initState();
    if (widget.metric == 'vo2max') {
      final index = _vo2RangeDays.indexOf(widget.days);
      _range = index >= 0 ? index : 1;
    } else if (widget.metric == 'heart_rate' && widget.days >= 30) {
      // 心率从首页进来默认落到「日」：展示当天全部采样，而不是最近 10 次；
      // 30 天日均值会把刚测到的高心率稀释掉，大数字也容易和首页对不上。
      _range = 0;
    } else if (const {'weight', 'bp', 'glucose'}.contains(widget.metric)) {
      // 体重/血压/血糖都是稀疏的手动记录，旧版历史可能横跨大半年。
      // 默认只看 30 天会把迁移过来的数据藏起来，直接给一年视图。
      _range = 4;
    } else {
      final index = rangeDays.indexOf(widget.days);
      if (index >= 0) _range = index;
    }
    _future = _load();
    if (widget.metric == 'bp') {
      VitaloopApi.bloodPressure(limit: 500).then((v) {
        if (mounted) setState(() => _bp = v);
      });
    } else if (widget.metric == 'glucose') {
      VitaloopApi.glucose(limit: 500).then((v) {
        if (mounted) setState(() => _glucose = v);
      });
    } else if (widget.metric == 'weight') {
      VitaloopApi.weights(limit: 400).then((v) {
        if (mounted) setState(() => _weights = v);
      });
      final state = widget.state;
      if (state != null) {
        _ble.attach(state);
        state.addListener(_onAppStateChanged);
      }
      _ble.devices.addListener(_onScaleDevicesChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnectScale());
    }
    _loadResting();
  }

  @override
  void dispose() {
    _scaleScanTimer?.cancel();
    _scaleAutoConnectTimer?.cancel();
    _ble.devices.removeListener(_onScaleDevicesChanged);
    widget.state?.removeListener(_onAppStateChanged);
    if (_scaleScanning) {
      _ble.stopScan();
    }
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted || widget.metric != 'weight') return;
    unawaited(_reloadRecords());
  }

  /// 秤只有踩上去才广播。页面打开后一直保持扫描，并自动连上刚出现的秤，
  /// 否则用户站上去时扫描已经超时，页面就会一直显示旧读数。
  void _onScaleDevicesChanged() {
    if (!mounted || widget.metric != 'weight') return;
    if (_connectedScale != null) {
      _scaleAutoConnectTimer?.cancel();
      return;
    }
    if (_scaleConnecting) return;
    if (!_scaleScanning && !_scalePermissionDenied) {
      unawaited(_startScaleScan());
      return;
    }
    Map<String, dynamic>? candidate;
    for (final device in _ble.devices.value.values) {
      if (!_isScale(device)) continue;
      if (device['state'] == 'connected') continue;
      final address = device['address'] as String? ?? '';
      if (address.isEmpty) continue;
      candidate = device;
      break;
    }
    if (candidate == null) return;
    final address = candidate['address'] as String? ?? '';
    if (_scaleAutoConnectTimer?.isActive ?? false) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _scaleLastAttemptMs < 8000) return;
    _scaleAutoConnectTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || _connectedScale != null || _scaleConnecting) return;
      final device = _ble.devices.value[address];
      if (device == null || device['state'] == 'connected') return;
      _scaleLastAttemptMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(_connectScale(device));
    });
  }

  bool _isScale(Map<String, dynamic> device) {
    final kind = (device['kind'] as String? ?? '').toLowerCase();
    if (kind == 'scale' || kind == 'weight') return true;
    final name = (device['name'] as String? ?? '').toLowerCase();
    return name.contains('afu') ||
        name.contains('scale') ||
        name.contains('体脂') ||
        name.contains('体重秤');
  }

  Map<String, dynamic>? get _connectedScale {
    for (final device in _ble.devices.value.values) {
      if (device['state'] == 'connected' && _isScale(device)) return device;
    }
    return null;
  }

  Future<void> _autoConnectScale() async {
    if (!mounted || widget.metric != 'weight') return;
    if (_connectedScale != null) return;
    setState(() => _scaleConnecting = true);
    try {
      await _ble.refreshHistory();
      // 不能直接走 connectLast：它可能是上次连的心率带。只在历史记录里找体脂秤，
      // 否则体重页会误以为“已经自动连接”，实际连的却是心率设备。
      for (final entry in _ble.history.value.entries) {
        if (!_looksLikeScale(entry.value)) continue;
        if (await _ble.connect(entry.key, entry.value)) return;
      }
      for (final device in _ble.devices.value.values) {
        if (!_isScale(device) || device['state'] == 'connected') continue;
        final address = device['address'] as String? ?? '';
        if (address.isEmpty) continue;
        final name = device['name'] as String? ?? '体脂秤';
        if (await _ble.connect(address, name)) return;
      }
    } finally {
      if (mounted) setState(() => _scaleConnecting = false);
    }
    // 体脂秤踩上去才广播，历史地址连不上时直接进入扫描，用户站上秤即可发现。
    if (mounted && _connectedScale == null) await _startScaleScan();
  }

  bool _looksLikeScale(String name) {
    final lower = name.toLowerCase();
    return lower.contains('afu') ||
        lower.contains('scale') ||
        lower.contains('体脂') ||
        lower.contains('体重秤') ||
        lower.contains('weight');
  }

  Future<void> _startScaleScan() async {
    if (_scaleScanStarting || _scaleScanning) return;
    _scaleScanStarting = true;
    final granted = await _ble.requestPermissions();
    if (!mounted) return;
    setState(() => _scalePermissionDenied = !granted);
    if (!granted) {
      _scaleScanStarting = false;
      return;
    }
    _scaleScanTimer?.cancel();
    final ok = await _ble.startScan();
    _scaleScanStarting = false;
    if (!mounted) return;
    setState(() => _scaleScanning = ok);
    if (!ok) return;
    // 体脂秤不是一直广播，20 秒经常等不到用户站上秤；页面停留期间给 3 分钟，
    // 离开页面时 dispose 会立刻停掉扫描。
    _scaleScanTimer = Timer(const Duration(minutes: 3), () {
      if (mounted) setState(() => _scaleScanning = false);
      _ble.stopScan();
    });
  }

  Future<void> _stopScaleScan() async {
    _scaleScanTimer?.cancel();
    await _ble.stopScan();
    if (mounted) setState(() => _scaleScanning = false);
  }

  Future<void> _connectScale(Map<String, dynamic> device) async {
    if (_scaleConnecting) return;
    setState(() => _scaleConnecting = true);
    await _stopScaleScan();
    final address = device['address'] as String? ?? '';
    if (address.isEmpty) {
      if (mounted) setState(() => _scaleConnecting = false);
      return;
    }
    final name = (device['name'] as String? ?? '').trim();
    bool ok = false;
    try {
      ok = await _ble.connect(address, name.isEmpty ? '体脂秤' : name);
    } finally {
      if (mounted) setState(() => _scaleConnecting = false);
    }
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('连接失败：请确认体脂秤已唤醒并靠近手机')));
  }

  /// 心率页不能只给一条总心率曲线：白天的高心率多半来自活动，
  /// 真正能反映恢复情况的是静息心率，以前它在首页那张大卡上，现在挪到这里。
  void _loadResting() {
    if (widget.metric != 'heart_rate') return;
    // 今天的静息心率通常要到晚上才结算。心率页默认看「日」，
    // 只查 1 天会在白天整块消失；至少带 30 天，先展示最近一次已结算值。
    final days = _days < 30 ? 30 : _days;
    VitaloopApi.metricDetail('resting_hr', days: days).then((d) {
      if (mounted) setState(() => _resting = d);
    });
  }

  Future<MetricDetail> _load() =>
      VitaloopApi.metricDetail(widget.metric, days: _days);

  void _setRange(int index) {
    if (index == _range) return;
    setState(() {
      _range = index;
      _showAllRecords = false;
      _future = _load();
    });
    _loadResting();
  }

  bool get _canAdd => const {'bp', 'glucose', 'weight'}.contains(widget.metric);

  Future<void> _reloadRecords() async {
    if (widget.metric == 'bp') {
      _bp = await VitaloopApi.bloodPressure(limit: 500);
    } else if (widget.metric == 'glucose') {
      _glucose = await VitaloopApi.glucose(limit: 500);
    } else if (widget.metric == 'weight') {
      _weights = await VitaloopApi.weights(limit: 400);
    }
    if (!mounted) return;
    setState(() => _future = _load());
  }

  Future<void> _addRecord() async {
    final v = context.v;
    final first = TextEditingController();
    final second = TextEditingController();
    final third = TextEditingController();
    var glucoseType = 'random';
    var error = '';
    var saving = false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            2,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.metric == 'weight'
                    ? '记录体重'
                    : (widget.metric == 'bp' ? '记录血压' : '记录血糖'),
                style: VText.h2.copyWith(color: v.ink),
              ),
              const SizedBox(height: 12),
              if (widget.metric == 'weight') ...[
                TextField(
                  controller: first,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('体重 (kg)'),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: second,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('体脂率 %（可选）'),
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else if (widget.metric == 'bp') ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: first,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr('收缩压'),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: second,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: tr('舒张压'),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: third,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr('脉搏（可选）'),
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                TextField(
                  controller: first,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: tr('血糖 (mmol/L)'),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  children: [
                    for (final entry in const {
                      'random': '随机',
                      'fasting': '空腹',
                      'before_meal': '餐前',
                      'after_meal': '餐后',
                      'bedtime': '睡前',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: glucoseType == entry.key,
                        onSelected: (_) =>
                            setSheet(() => glucoseType = entry.key),
                      ),
                  ],
                ),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(error, style: VText.label.copyWith(color: v.danger)),
              ],
              const SizedBox(height: 16),
              VPrimaryButton(
                label: saving ? '保存中…' : '保存记录',
                icon: Icons.check_rounded,
                onTap: saving
                    ? null
                    : () async {
                        setSheet(() => saving = true);
                        try {
                          if (widget.metric == 'weight') {
                            final kg = double.tryParse(first.text.trim()) ?? 0;
                            final fat =
                                double.tryParse(second.text.trim()) ?? 0;
                            if (kg <= 0) throw Exception('请输入体重');
                            await VitaloopApi.addWeightRecord(
                              weightKg: kg,
                              bodyFatPercent: fat,
                            );
                          } else if (widget.metric == 'bp') {
                            final sys = int.tryParse(first.text.trim()) ?? 0;
                            final dia = int.tryParse(second.text.trim()) ?? 0;
                            final pulse = int.tryParse(third.text.trim()) ?? 0;
                            if (sys <= 0 || dia <= 0) {
                              throw Exception('请输入收缩压和舒张压');
                            }
                            await VitaloopApi.addBloodPressure(
                              systolic: sys,
                              diastolic: dia,
                              pulse: pulse,
                            );
                          } else {
                            final value =
                                double.tryParse(first.text.trim()) ?? 0;
                            if (value <= 0) throw Exception('请输入血糖');
                            await VitaloopApi.addBloodGlucose(
                              value: value,
                              measureType: glucoseType,
                            );
                          }
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          setSheet(() {
                            saving = false;
                            error = '$e'.replaceFirst('Exception: ', '');
                          });
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) await _reloadRecords();
  }

  Future<void> _recordActions({
    BloodPressureEntry? bp,
    GlucoseEntry? glucose,
    WeightEntry? weight,
  }) async {
    final v = context.v;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.edit_rounded, color: v.blueInk),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: v.danger),
              title: Text('删除', style: TextStyle(color: v.danger)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: v.surface,
          title: Text('删除这条记录？', style: VText.h2.copyWith(color: v.ink)),
          content: Text(
            '删除后不可恢复，云端已同步的快照不受影响。',
            style: VText.label.copyWith(color: v.muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('删除', style: TextStyle(color: v.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
      if (bp != null) await VitaloopApi.deleteBloodPressure(bp.id);
      if (glucose != null) await VitaloopApi.deleteBloodGlucose(glucose.id);
      if (weight != null) await VitaloopApi.deleteWeightRecord(weight.id);
      await _reloadRecords();
      return;
    }
    await _editRecord(bp: bp, glucose: glucose, weight: weight);
  }

  Future<void> _editRecord({
    BloodPressureEntry? bp,
    GlucoseEntry? glucose,
    WeightEntry? weight,
  }) async {
    final v = context.v;
    final first = TextEditingController(
      text: bp != null
          ? '${bp.systolic}'
          : glucose != null
          ? glucose.value.toStringAsFixed(1)
          : (weight?.weightKg ?? 0).toStringAsFixed(1),
    );
    final second = TextEditingController(
      text: bp != null
          ? '${bp.diastolic}'
          : (weight?.bodyFatPercent?.toStringAsFixed(1) ?? ''),
    );
    final third = TextEditingController(text: bp?.pulse?.toString() ?? '');
    var glucoseType = glucose?.measureType ?? 'random';
    var error = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: v.surface,
          title: Text('编辑记录', style: VText.h2.copyWith(color: v.ink)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (weight != null) ...[
                  TextField(
                    controller: first,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: tr('体重 (kg)'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: second,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: tr('体脂率 %（可选）'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ] else if (bp != null) ...[
                  TextField(
                    controller: first,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('收缩压'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: second,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('舒张压'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: third,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tr('脉搏（可选）'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: first,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: tr('血糖 (mmol/L)'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 7,
                    children: [
                      for (final entry in const {
                        'random': '随机',
                        'fasting': '空腹',
                        'before_meal': '餐前',
                        'after_meal': '餐后',
                        'bedtime': '睡前',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: glucoseType == entry.key,
                          onSelected: (_) =>
                              setDlg(() => glucoseType = entry.key),
                        ),
                    ],
                  ),
                ],
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(error, style: VText.label.copyWith(color: v.danger)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  if (weight != null) {
                    final kg = double.tryParse(first.text.trim()) ?? 0;
                    final fat = double.tryParse(second.text.trim()) ?? 0;
                    await VitaloopApi.updateWeightRecord(
                      id: weight.id,
                      weightKg: kg,
                      bodyFatPercent: fat,
                    );
                  } else if (bp != null) {
                    final sys = int.tryParse(first.text.trim()) ?? 0;
                    final dia = int.tryParse(second.text.trim()) ?? 0;
                    final pulse = int.tryParse(third.text.trim()) ?? 0;
                    await VitaloopApi.updateBloodPressure(
                      id: bp.id,
                      systolic: sys,
                      diastolic: dia,
                      pulse: pulse,
                    );
                  } else {
                    final value = double.tryParse(first.text.trim()) ?? 0;
                    await VitaloopApi.updateBloodGlucose(
                      id: glucose!.id,
                      value: value,
                      measureType: glucoseType,
                    );
                  }
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  setDlg(() => error = '$e'.replaceFirst('Exception: ', ''));
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    third.dispose();
    if (saved == true) await _reloadRecords();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<MetricDetail>(
          future: _future,
          builder: (context, snapshot) {
            final detail = snapshot.data;
            final accent = widget.color ?? v.blue;
            final known = detail == null ? null : _lastKnown(detail);
            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
              children: [
                VDetailHeader(
                  title: widget.title ?? detail?.label ?? '指标详情',
                  icon: metricIcon(widget.metric),
                  iconColor: accent,
                  trailing: _canAdd
                      ? TextButton(
                          onPressed: _addRecord,
                          child: const Text('记录'),
                        )
                      : null,
                ),
                // 旧版体温页可以在「体温 / 皮肤温度」之间切；新版的首页卡片
                // 只会优先打开核心体温，腕温数据仍要能在这里看到。
                if (widget.metric == 'body_temp' ||
                    widget.metric == 'skin_temp')
                  VSegmented(
                    options: const ['核心体温', '腕温'],
                    index: widget.metric == 'body_temp' ? 0 : 1,
                    onChanged: (i) {
                      final next = i == 0 ? 'body_temp' : 'skin_temp';
                      if (next == widget.metric) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) => MetricDetailScreen(
                            metric: next,
                            title: i == 0 ? '体温' : '腕温',
                            color: accent,
                            days: widget.days,
                            state: widget.state,
                          ),
                        ),
                      );
                    },
                    margin: const EdgeInsets.only(top: 2, bottom: 8),
                  ),
                VSegmented(
                  options: widget.metric == 'vo2max'
                      ? _vo2RangeLabels
                      : rangeLabels,
                  index: _range,
                  onChanged: _setRange,
                  margin: const EdgeInsets.only(top: 2, bottom: 12),
                ),
                if (detail == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 120),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  // 体脂秤入口和有没有历史体重无关：新用户第一次上秤也应该
                  // 能直接看到实时读数，而不是先被「暂无体重数据」挡住。
                  if (widget.metric == 'weight')
                    ValueListenableBuilder<Map<String, Map<String, dynamic>>>(
                      valueListenable: _ble.devices,
                      builder: (context, _, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _scaleSection(accent),
                      ),
                    ),
                  if (!detail.hasData) ...[
                    VCard(
                      child: Column(
                        children: [
                          Icon(
                            metricIcon(widget.metric),
                            size: 34,
                            color: v.muted,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            known == null
                                ? '暂无${detail.label}数据'
                                : '$_rangeTitle没有${detail.label}记录',
                            style: VText.h3.copyWith(color: v.ink),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            // 首页写着「5.6 mmol · 最近一次」，点进来却说「暂无血糖数据」，等于自己否认自己
                            known == null
                                ? '从旧版导入历史数据，或等待手表同步后即可查看趋势。'
                                : '最近一次记录在 ${relativeDay(DateTime.fromMillisecondsSinceEpoch(known.$1))}（${_valueLabel(detail, known.$2)} ${_unit(detail)}），切到更长的时间范围即可查看。',
                            textAlign: TextAlign.center,
                            style: VText.label.copyWith(
                              color: v.muted,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VSectionHead(title: '说明'),
                    VCard(
                      child: Text(
                        detail.description,
                        style: VText.body.copyWith(color: v.ink2, height: 1.6),
                      ),
                    ),
                  ] else ...[
                    VCard(
                      background: v.surface,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            detail.label,
                            style: VText.meta.copyWith(
                              color: v.muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _big(detail, detail.latest),
                                style: VText.h1.copyWith(
                                  fontSize: 40,
                                  color: v.ink,
                                ),
                              ),
                              if (_unit(detail).isNotEmpty) ...[
                                const SizedBox(width: 6),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 7),
                                  child: Text(
                                    _unit(detail),
                                    style: VText.meta.copyWith(
                                      color: v.muted,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                              const Spacer(),
                              if (detail.trend != null &&
                                  !_isCategorical(detail))
                                _trendChip(detail, detail.trend!),
                            ],
                          ),
                          if (_range > 0) ...[
                            const SizedBox(height: 12),
                            if (_isCategorical(detail))
                              Row(children: _categoricalStats(detail))
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: VStat(
                                      label: '平均',
                                      value: _fmt(detail, detail.average),
                                      unit: _unit(detail),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: VStat(
                                      label: '最低',
                                      value: _fmt(detail, detail.minimum),
                                      unit: _unit(detail),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: VStat(
                                      label: '最高',
                                      value: _fmt(detail, detail.maximum),
                                      unit: _unit(detail),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                          if (detail.goal != null && detail.goal! > 0) ...[
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: ((detail.latest ?? 0) / detail.goal!)
                                    .clamp(0, 1),
                                minHeight: 7,
                                backgroundColor: accent.withValues(alpha: 0.14),
                                valueColor: AlwaysStoppedAnimation(accent),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '目标 ${_fmt(detail, detail.goal)} ${_unit(detail)}',
                              style: VText.label.copyWith(
                                fontSize: 9.5,
                                color: v.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.metric == 'active_calories') ...[
                      const VSectionHead(title: '活动三环'),
                      const ActivityRingsSection(),
                      const SizedBox(height: 11),
                    ],
                    ..._trendSection(detail, accent),
                    ..._restingSection(),
                    ..._referenceSection(),
                    if (_recordCount(detail) > 0) ...[
                      VSectionHead(
                        title: widget.metric == 'heart_rate' ? '最近采样' : '全部记录',
                        trailing: _showAllRecords
                            ? '收起'
                            : '${_recordCount(detail)} 条 · 展开',
                        onTrailing: () =>
                            setState(() => _showAllRecords = !_showAllRecords),
                      ),
                      if (_showAllRecords)
                        VCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: Column(children: _recordRows(detail)),
                        ),
                    ],
                    const SizedBox(height: 10),
                    VCard(
                      background: v.tintGrey,
                      child: Text(
                        detail.description,
                        style: VText.label.copyWith(
                          color: v.muted,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _restingSection() {
    final v = context.v;
    final resting = _resting;
    if (resting == null || !resting.hasData) return const [];
    final buckets = bucketSeries(resting.days, _range);
    final filled = buckets.where((b) => b.value > 0).length;
    final updated = resting.updatedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resting.updatedMs!);
    return [
      const VSectionHead(title: '静息心率'),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  resting.latest == null ? '--' : '${resting.latest!.round()}',
                  style: VText.h1.copyWith(fontSize: 28, color: v.ink),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    updated == null
                        ? 'bpm · 最近一次'
                        : 'bpm · ${relativeDay(updated)}',
                    style: VText.label.copyWith(color: v.muted),
                  ),
                ),
                const Spacer(),
                if (resting.baseline != null)
                  Text(
                    '基线 ${resting.baseline!.round()} bpm',
                    style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (filled >= 2)
              VRangeLine(
                buckets: buckets,
                color: v.heartInk,
                unit: 'bpm',
                valueFormat: (value) => value.round().toString(),
              )
            else
              Text(
                '静息心率每天只结算一次，切到周 / 月 / 半年 / 年就能看到趋势。',
                style: VText.label.copyWith(color: v.muted, height: 1.5),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _referenceSection() => switch (widget.metric) {
    'bp' => _bpReferenceSection(),
    'glucose' => _glucoseReferenceSection(),
    'weight' => _weightReferenceSection(),
    _ => const [],
  };

  List<Widget> _bpReferenceSection() {
    final v = context.v;
    final latest = _bp.isEmpty
        ? null
        : ([
            ..._bp,
          ]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs))).first;
    final level = latest == null
        ? null
        : bpLevel(latest.systolic, latest.diastolic);
    return [
      VSectionHead(title: '参考标准'),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('血压参考标准', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                if (level != null)
                  _referenceBadge(bpLevelLabel(level), _bpLevelColor(level)),
              ],
            ),
            if (latest != null) ...[
              const SizedBox(height: 5),
              Text(
                '最近一次 ${latest.systolic}/${latest.diastolic} mmHg · '
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(latest.timestampMs))} '
                '${clock(DateTime.fromMillisecondsSinceEpoch(latest.timestampMs))}',
                style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
              ),
            ],
            const SizedBox(height: 12),
            for (final row in bpReferenceRows)
              _referenceRow(
                color: _bpLevelColor(row.level),
                label: row.label,
                value: '${row.systolic}/${row.diastolic}',
                current: level == row.level,
              ),
            const SizedBox(height: 8),
            Text(
              '静息状态下测量；收缩压或舒张压任一达到更高一级，即按更高一级计。',
              style: VText.label.copyWith(
                fontSize: 9.5,
                color: v.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _glucoseReferenceSection() {
    final v = context.v;
    final latest = _glucose.isEmpty
        ? null
        : ([
            ..._glucose,
          ]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs))).first;
    final standard = latest == null
        ? null
        : glucoseStandardFor(latest.measureType);
    final level = latest == null
        ? null
        : glucoseLevel(latest.value, latest.measureType);
    final levelLabel = latest == null
        ? null
        : glucoseLevelLabel(latest.value, latest.measureType);
    return [
      VSectionHead(title: '参考标准'),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('血糖参考标准 (mmol/L)', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                if (level != null && levelLabel != null)
                  _referenceBadge(levelLabel, _glucoseLevelColor(level)),
              ],
            ),
            if (latest != null) ...[
              const SizedBox(height: 5),
              Text(
                '最近一次 ${latest.value.toStringAsFixed(1)} mmol/L'
                '（${_glucoseType(latest.measureType)}）· '
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(latest.timestampMs))} '
                '${clock(DateTime.fromMillisecondsSinceEpoch(latest.timestampMs))}',
                style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
              ),
              if (standard == null) ...[
                const SizedBox(height: 3),
                Text(
                  '随机血糖没有固定时点，不按上面的空腹 / 餐后标准分级。',
                  style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                ),
              ],
            ],
            const SizedBox(height: 12),
            Text(
              '空腹血糖',
              style: VText.label.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: v.ink2,
              ),
            ),
            const SizedBox(height: 4),
            for (final row in fastingGlucoseRows)
              _referenceRow(
                color: _glucoseLevelColor(row.level),
                label: row.label,
                value: row.range,
                current:
                    standard == GlucoseStandard.fasting && level == row.level,
              ),
            const SizedBox(height: 10),
            Text(
              '餐后2小时血糖',
              style: VText.label.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: v.ink2,
              ),
            ),
            const SizedBox(height: 4),
            for (final row in afterMealGlucoseRows)
              _referenceRow(
                color: _glucoseLevelColor(row.level),
                label: row.label,
                value: row.range,
                current:
                    standard == GlucoseStandard.afterMeal && level == row.level,
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _weightReferenceSection() {
    final v = context.v;
    if (_weights.isEmpty) return const [];
    final latest = ([
      ..._weights,
    ]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs))).first;
    final height = latest.heightCm ?? widget.state?.profile?.heightCm;
    final bmi =
        latest.bmi ??
        (height != null && height > 0
            ? latest.weightKg / ((height / 100.0) * (height / 100.0))
            : null);
    final level = bmi == null ? null : bmiLevel(bmi);
    return [
      VSectionHead(title: '身体数据'),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('BMI 参考标准', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                if (level != null)
                  _referenceBadge(bmiLevelLabel(level), _bmiLevelColor(level)),
              ],
            ),
            const SizedBox(height: 11),
            Row(
              children: [
                Expanded(
                  child: VStat(
                    label: '身高',
                    value: height == null ? '--' : height.toStringAsFixed(0),
                    unit: 'cm',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: VStat(
                    label: '体重',
                    value: latest.weightKg.toStringAsFixed(1),
                    unit: 'kg',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: VStat(
                    label: 'BMI',
                    value: bmi == null ? '--' : bmi.toStringAsFixed(1),
                    unit: level == null ? null : bmiLevelLabel(level),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final row in bmiReferenceRows)
              _referenceRow(
                color: _bmiLevelColor(row.level),
                label: row.label,
                value: row.range,
                current: level == row.level,
              ),
          ],
        ),
      ),
    ];
  }

  Widget _referenceRow({
    required Color color,
    required String label,
    required String value,
    bool current = false,
  }) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: VText.label.copyWith(
              color: v.ink,
              fontWeight: current ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (current) ...[
            const SizedBox(width: 6),
            _referenceBadge('当前', color),
          ],
          const Spacer(),
          Text(value, style: VText.label.copyWith(color: v.muted)),
        ],
      ),
    );
  }

  Widget _referenceBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: VText.label.copyWith(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Color _bpLevelColor(BpLevel level) => switch (level) {
    BpLevel.normal => context.v.greenInk,
    BpLevel.elevated => context.v.warnInk,
    BpLevel.stage1 => context.v.peachInk,
    BpLevel.stage2 => context.v.danger,
  };

  Color _glucoseLevelColor(GlucoseLevel level) => switch (level) {
    GlucoseLevel.low => context.v.blueInk,
    GlucoseLevel.normal => context.v.greenInk,
    GlucoseLevel.impaired => context.v.warnInk,
    GlucoseLevel.diabetes => context.v.danger,
  };

  Color _bmiLevelColor(BmiLevel level) => switch (level) {
    BmiLevel.underweight => context.v.blueInk,
    BmiLevel.normal => context.v.greenInk,
    BmiLevel.overweight => context.v.warnInk,
    BmiLevel.obese => context.v.danger,
  };

  List<Widget> _scaleSection(Color accent) {
    final v = context.v;
    final connected = _connectedScale;
    // 体脂秤唤醒后偶尔会换 BLE 随机地址，旧地址的扫描结果还留在内存里。
    // 同名设备只保留信号最强的一条，否则页面会显示两个“体脂秤”。
    final byName = <String, Map<String, dynamic>>{};
    for (final device in _ble.devices.value.values) {
      if (!_isScale(device) || device['state'] == 'connected') continue;
      final name = (device['name'] as String? ?? '').trim().toLowerCase();
      final key = name.isEmpty ? (device['address'] as String? ?? '') : name;
      final existing = byName[key];
      if (existing == null ||
          (device['rssi'] as int? ?? -999) >
              (existing['rssi'] as int? ?? -999)) {
        byName[key] = device;
      }
    }
    final nearby = byName.values.toList()
      ..sort(
        (a, b) =>
            (b['rssi'] as int? ?? -999).compareTo(a['rssi'] as int? ?? -999),
      );
    final kg = (connected?['weightKg'] as num?)?.toDouble();
    final fat = (connected?['bodyFatPercent'] as num?)?.toDouble();
    final battery = (connected?['battery'] as num?)?.toInt() ?? -1;
    final charging = connected?['charging'] == true;
    final name = (connected?['name'] as String? ?? '').trim();
    final composition = connected == null
        ? const <Widget>[]
        : _liveScaleComposition(connected);
    return [
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                VIconBox(
                  icon: Icons.monitor_weight_rounded,
                  background: v.tintSky,
                  foreground: v.skyInk,
                  size: 34,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '蓝牙体脂秤',
                        style: VText.h3.copyWith(fontSize: 13, color: v.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connected == null
                            ? '连接后称重自动保存，不用手动输入'
                            : '${name.isEmpty ? '体脂秤' : name} · 已连接',
                        style: VText.label.copyWith(
                          fontSize: 10,
                          color: v.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (connected != null)
                  TextButton(
                    onPressed: () =>
                        _ble.disconnect(connected['address'] as String? ?? ''),
                    child: const Text('断开'),
                  )
                else if (_scaleConnecting)
                  Text('自动连接中…', style: VText.label.copyWith(color: v.muted))
                else if (_scaleScanning)
                  TextButton(onPressed: _stopScaleScan, child: const Text('停止'))
                else
                  TextButton(
                    onPressed: _startScaleScan,
                    child: const Text('搜索'),
                  ),
              ],
            ),
            if (_scalePermissionDenied) ...[
              const SizedBox(height: 10),
              Text(
                '需要「附近的设备」权限才能连接体脂秤，请在系统设置里允许后重试。',
                style: VText.label.copyWith(color: v.warnInk, height: 1.5),
              ),
            ],
            if (connected != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: VStat(
                      label: '当前读数',
                      value: kg == null ? '--' : kg.toStringAsFixed(1),
                      unit: 'kg',
                    ),
                  ),
                  if (fat != null && fat > 0) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: '体脂率',
                        value: fat.toStringAsFixed(1),
                        unit: '%',
                      ),
                    ),
                  ],
                  if (battery >= 0) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: VStat(
                        label: charging ? '充电中' : '电量',
                        value: '$battery',
                        unit: '%',
                      ),
                    ),
                  ],
                ],
              ),
              if (composition.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: v.tintGrey,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(children: composition),
                ),
              ],
              const SizedBox(height: 9),
              Text(
                '站稳后会自动保存；体脂、肌肉、水分等体成分会随这次称重一起写入历史记录。',
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: v.muted,
                  height: 1.5,
                ),
              ),
            ] else if (nearby.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final device in nearby)
                VRowItem(
                  icon: Icons.bluetooth_rounded,
                  iconBackground: v.tintSky,
                  iconColor: v.skyInk,
                  title: (device['name'] as String? ?? '').trim().isEmpty
                      ? '体脂秤'
                      : device['name'] as String,
                  subtitle: device['address'] as String? ?? '',
                  value: '连接',
                  onTap: () => _connectScale(device),
                ),
            ] else ...[
              const SizedBox(height: 10),
              Text(
                _scaleScanning
                    ? '正在搜索附近的体脂秤，请站上秤唤醒它…'
                    : '把体脂秤开机并靠近手机，点「搜索」即可连接测试。',
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: v.muted,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 2),
    ];
  }

  /// 体脂秤实时回传的人体成分，和旧版连接页一样把百分比和 kg 放在一行。
  List<Widget> _liveScaleComposition(Map<String, dynamic> device) {
    final rows = <Widget>[];
    void add(String label, String percentKey, String massKey) {
      final percent = (device[percentKey] as num?)?.toDouble();
      final mass = (device[massKey] as num?)?.toDouble();
      final parts = <String>[
        if (percent != null && percent > 0) '${percent.toStringAsFixed(1)}%',
        if (mass != null && mass > 0) '${mass.toStringAsFixed(1)} kg',
      ];
      if (parts.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Text(
                label,
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: context.v.muted,
                ),
              ),
              const Spacer(),
              Text(
                parts.join(' · '),
                style: VText.label.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.v.ink2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    add('体脂', 'bodyFatPercent', 'fatMassKg');
    add('肌肉', 'musclePercent', 'muscleMassKg');
    add('水分', 'waterPercent', 'waterMassKg');
    add('蛋白质', 'proteinPercent', 'proteinMassKg');
    add('骨量', 'bonePercent', 'boneMassKg');
    add('骨骼肌', 'skeletalMusclePercent', 'skeletalMuscleMassKg');
    add('皮下脂肪', 'subcutaneousFatPercent', 'subcutaneousFatMassKg');
    final resistance = (device['resistanceOhm'] as num?)?.toDouble();
    if (resistance != null && resistance > 0) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Text(
                '阻抗',
                style: VText.label.copyWith(
                  fontSize: 10,
                  color: context.v.muted,
                ),
              ),
              const Spacer(),
              Text(
                '${resistance.toStringAsFixed(0)} Ω',
                style: VText.label.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.v.ink2,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  /// 情绪只有三档编码，画柱状图等于把「平静=3」说成比「紧张=1」大 3 倍——
  /// 那是编码不是量。改成一天一个色块的时间线，再配三档占比。
  List<Widget> _emotionSection(MetricDetail detail) {
    final v = context.v;
    final days = detail.days;
    if (days.isEmpty) return const [];
    final counts = <int, int>{};
    for (final p in days) {
      counts.update(p.value.round(), (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      const SizedBox(height: 10),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                Text(
                  '${days.length} 天有检测',
                  style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [
                for (final p in days) _emotionCell(p.value.round(), v),
              ],
            ),
            const SizedBox(height: 14),
            for (final status in _emotionOrder)
              if ((counts[status] ?? 0) > 0)
                _emotionBar(status, counts[status]!, days.length, v),
            const SizedBox(height: 6),
            Text(
              '每个方块一天，取当天最后一次检测；颜色按愉悦度分平静 / 一般 / 紧张。',
              style: VText.label.copyWith(
                fontSize: 9.5,
                color: v.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  static const _emotionOrder = [3, 2, 1];

  Widget _emotionCell(int status, VColors v) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(
      color: _emotionTint(status, v).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(2.5),
    ),
  );

  Widget _emotionBar(int status, int count, int total, VColors v) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(
            emotionLabel(status),
            style: VText.label.copyWith(color: v.ink2),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: count / total,
              minHeight: 7,
              backgroundColor: v.tintGrey,
              valueColor: AlwaysStoppedAnimation(_emotionTint(status, v)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 42,
          child: Text(
            '$count 天',
            textAlign: TextAlign.right,
            style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
          ),
        ),
      ],
    ),
  );

  Color _emotionTint(int status, VColors v) =>
      switch (emotionPolarity(status)) {
        1 => v.greenInk,
        -1 => v.warnInk,
        _ => v.muted,
      };

  List<Widget> _trendSection(MetricDetail detail, Color accent) {
    final v = context.v;
    if (_isCategorical(detail)) return _emotionSection(detail);
    if (detail.metric == 'vo2max') return _vo2MonthlySection(detail, accent);
    if (_range == 0) {
      final startMs = _rangeStart.millisecondsSinceEpoch;
      final endMs = DateTime(
        _rangeStart.year,
        _rangeStart.month,
        _rangeStart.day + 1,
      ).millisecondsSinceEpoch;
      final samples =
          detail.samples
              .where((s) => s.timestampMs >= startMs && s.timestampMs < endMs)
              .toList()
            ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      if (samples.length < 2) return const [];
      return [
        const SizedBox(height: 10),
        VCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('今日采样', style: VText.h3.copyWith(color: v.ink)),
                  const Spacer(),
                  Text(
                    '${samples.length} 个采样',
                    style: VText.label.copyWith(color: v.muted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              HeartRateCurve(
                points: [
                  for (final s in samples)
                    Offset(s.timestampMs.toDouble(), s.value),
                ],
                color: accent,
                height: 108,
                unit: _unit(detail),
                valueFormat: (value) => _fmt(detail, value),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    clock(
                      DateTime.fromMillisecondsSinceEpoch(
                        samples.first.timestampMs,
                      ),
                    ),
                    style: VText.label.copyWith(fontSize: 9, color: v.muted),
                  ),
                  const Spacer(),
                  Text(
                    clock(
                      DateTime.fromMillisecondsSinceEpoch(
                        samples.last.timestampMs,
                      ),
                    ),
                    style: VText.label.copyWith(fontSize: 9, color: v.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ];
    }
    final recordChart = _recordTrendSection();
    if (recordChart.isNotEmpty) return recordChart;
    final buckets = bucketSeries(
      detail.days,
      _range,
      sum: _sumMetrics.contains(detail.metric),
    );
    // 铺满窗口后桶数恒定，判「够不够画趋势」要看真的有数据的桶，不能再看桶总数。
    final filled = buckets.where((b) => b.value > 0).length;
    if (filled == 0) {
      return [
        const SizedBox(height: 10),
        VCard(
          background: v.tintGrey,
          child: Text(
            '$_rangeTitle还没有任何记录。',
            style: VText.label.copyWith(color: v.muted, height: 1.5),
          ),
        ),
      ];
    }
    return [
      const SizedBox(height: 10),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                if (detail.baseline != null && !_isCategorical(detail))
                  Text(
                    '基线 ${_fmt(detail, detail.baseline)} ${_unit(detail)}'
                        .trim(),
                    style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            VRangeLine(
              buckets: buckets,
              color: accent,
              unit: _unit(detail),
              valueFormat: (value) => _fmt(detail, value),
            ),
          ],
        ),
      ),
    ];
  }

  /// 最大摄氧量是「跑完一次估一次」的稀疏值：按天画，没跑的日子全是空档，
  /// 中间只有单点也连不成线。这里固定按自然月取均值，跨越空月份也连起来。
  List<Widget> _vo2MonthlySection(MetricDetail detail, Color accent) {
    final v = context.v;
    final months = <int, List<double>>{};
    for (final s in detail.samples) {
      final d = DateTime.fromMillisecondsSinceEpoch(s.timestampMs);
      months.putIfAbsent(d.year * 100 + d.month, () => []).add(s.value);
    }
    final keys = months.keys.toList()..sort();
    if (keys.length < 2) {
      return [
        const SizedBox(height: 10),
        VCard(
          background: v.tintGrey,
          child: Text(
            '至少需要两个月的跑步估算才能画出趋势。最大摄氧量按次产生，单日或单次的变化参考意义不大，建议按月看。',
            style: VText.label.copyWith(color: v.muted, height: 1.55),
          ),
        ),
      ];
    }
    final first = DateTime(keys.first ~/ 100, keys.first % 100);
    final last = DateTime(keys.last ~/ 100, keys.last % 100);
    final buckets = <RangeBucket>[];
    for (
      var m = DateTime(first.year, first.month);
      !m.isAfter(last);
      m = DateTime(m.year, m.month + 1)
    ) {
      final values = months[m.year * 100 + m.month];
      buckets.add(
        RangeBucket(
          start: m,
          value: values == null
              ? 0
              : values.reduce((a, b) => a + b) / values.length,
          label: '${m.month}月',
        ),
      );
    }
    final measured = buckets.where((b) => b.value > 0).length;
    return [
      const SizedBox(height: 10),
      VCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('月度趋势', style: VText.h3.copyWith(color: v.ink)),
                const Spacer(),
                Text(
                  '$measured 个月 · 月均',
                  style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            VRangeLine(
              buckets: buckets,
              color: accent,
              height: 120,
              connectGaps: true,
              unit: 'ml/kg/min',
              valueFormat: (value) => value.toStringAsFixed(1),
              dateLabel: (bucket) =>
                  '${bucket.start.year}/${bucket.start.month}',
            ),
            const SizedBox(height: 6),
            Text(
              '按自然月把当月所有跑步估算取平均；日粒度受单次状态影响太大，不作为趋势依据。',
              style: VText.label.copyWith(
                fontSize: 9.5,
                color: v.muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// 血压/血糖/体重：基于逐条记录的日均值折线，比按天柱状更适合稀疏的手动记录。
  List<Widget> _recordTrendSection() {
    final v = context.v;
    final startMs = _rangeStart.millisecondsSinceEpoch;
    switch (widget.metric) {
      case 'bp':
        final inRange = _bp.where((e) => e.timestampMs >= startMs).toList();
        final sys = _plotPoints([
          for (final e in inRange)
            (timestampMs: e.timestampMs, value: e.systolic.toDouble()),
        ]);
        final dia = _plotPoints([
          for (final e in inRange)
            (timestampMs: e.timestampMs, value: e.diastolic.toDouble()),
        ]);
        if (sys.points.length < 2) return const [];
        return [
          const SizedBox(height: 10),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
                    const Spacer(),
                    _legendDot(v.heartInk, '收缩压'),
                    const SizedBox(width: 10),
                    _legendDot(v.blue, '舒张压'),
                  ],
                ),
                const SizedBox(height: 12),
                MultiLineChart(
                  series: [
                    MultiLineSeries(
                      points: sys.points,
                      color: v.heartInk,
                      name: '收缩压',
                    ),
                    MultiLineSeries(
                      points: dia.points,
                      color: v.blue,
                      name: '舒张压',
                    ),
                  ],
                  height: 120,
                  unit: 'mmHg',
                ),
              ],
            ),
          ),
        ];
      case 'glucose':
        final inRange = _glucose
            .where((e) => e.timestampMs >= startMs)
            .toList();
        final pts = _plotPoints([
          for (final e in inRange) (timestampMs: e.timestampMs, value: e.value),
        ]);
        if (pts.points.length < 2) return const [];
        return [
          const SizedBox(height: 10),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
                    const Spacer(),
                    Text(
                      '${pts.mode} · mmol/L',
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: v.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                HeartRateCurve(
                  points: pts.points,
                  color: v.limeInk,
                  height: 110,
                  unit: 'mmol/L',
                  valueFormat: (value) => value.toStringAsFixed(1),
                ),
              ],
            ),
          ),
        ];
      case 'weight':
        final inRange = _weights
            .where((e) => e.timestampMs >= startMs)
            .toList();
        final pts = _plotPoints([
          for (final e in inRange)
            (timestampMs: e.timestampMs, value: e.weightKg),
        ]);
        final latestComp = _latestBodyComposition();
        if (pts.points.length < 2) {
          return [if (latestComp != null) _bodyCompositionCard(latestComp)];
        }
        return [
          const SizedBox(height: 10),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_rangeTitle, style: VText.h3.copyWith(color: v.ink)),
                    const Spacer(),
                    Text(
                      '${pts.mode} · kg',
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        color: v.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                HeartRateCurve(
                  points: pts.points,
                  color: v.skyInk,
                  height: 110,
                  unit: 'kg',
                  valueFormat: (value) => value.toStringAsFixed(1),
                ),
              ],
            ),
          ),
          if (latestComp != null) _bodyCompositionCard(latestComp),
        ];
      default:
        return const [];
    }
  }

  WeightEntry? _latestBodyComposition() {
    for (final e in _weights) {
      if (e.bodyFatPercent != null) return e;
    }
    return null;
  }

  Widget _bodyCompositionCard(WeightEntry e) {
    final v = context.v;
    final tiles = <Widget>[
      if (e.bodyFatPercent != null)
        VStat(
          label: '体脂率',
          value: e.bodyFatPercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.fatMassKg != null)
        VStat(label: '脂肪量', value: e.fatMassKg!.toStringAsFixed(1), unit: 'kg'),
      if (e.musclePercent != null)
        VStat(
          label: '肌肉率',
          value: e.musclePercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.muscleMassKg != null)
        VStat(
          label: '肌肉量',
          value: e.muscleMassKg!.toStringAsFixed(1),
          unit: 'kg',
        ),
      if (e.waterPercent != null)
        VStat(
          label: '水分',
          value: e.waterPercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.proteinPercent != null)
        VStat(
          label: '蛋白质',
          value: e.proteinPercent!.toStringAsFixed(1),
          unit: '%',
        ),
      // 旧版骨量显示的是 kg（boneMassKg），不是百分比；体脂秤没回传 kg 时
      // 才退回百分比，避免把 3.2% 当成 3.2 kg。
      if (e.boneMassKg != null)
        VStat(label: '骨量', value: e.boneMassKg!.toStringAsFixed(1), unit: 'kg')
      else if (e.bonePercent != null)
        VStat(
          label: '骨量率',
          value: e.bonePercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.skeletalMusclePercent != null)
        VStat(
          label: '骨骼肌',
          value: e.skeletalMusclePercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.subcutaneousFatPercent != null)
        VStat(
          label: '皮下脂肪',
          value: e.subcutaneousFatPercent!.toStringAsFixed(1),
          unit: '%',
        ),
      if (e.resistanceOhm != null)
        VStat(
          label: '阻抗',
          value: e.resistanceOhm!.toStringAsFixed(0),
          unit: 'Ω',
        ),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近一次体成分', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              Text(
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))}',
                style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
              ),
            ],
          ),
          if (e.bodyCompositionModel != null &&
              e.bodyCompositionModel!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              e.bodyCompositionModel!,
              style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
            ),
          ],
          const SizedBox(height: 11),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tile in tiles) SizedBox(width: width, child: tile),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    final v = context.v;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: VText.label.copyWith(fontSize: 9.5, color: v.muted)),
      ],
    );
  }

  /// 同一天测了三次也只会均出一个点，窗口只剩一天时就没图了；
  /// 这时直接按每次测量画——用户明明有 3 条记录却看不到图说不过去。
  ({List<Offset> points, String mode}) _plotPoints(
    List<({int timestampMs, double value})> items,
  ) {
    if (items.length < 2) return (points: const <Offset>[], mode: '');
    final daily = _dailyAveraged(items);
    if (daily.length >= 2) return (points: daily, mode: '按日平均');
    return (
      points: [
        for (final e in items) Offset(e.timestampMs.toDouble(), e.value),
      ],
      mode: '每次测量',
    );
  }

  List<Offset> _dailyAveraged(List<({int timestampMs, double value})> items) {
    final buckets = <int, List<double>>{};
    for (final e in items) {
      final day = DateTime.fromMillisecondsSinceEpoch(e.timestampMs);
      final key = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
      buckets.putIfAbsent(key, () => []).add(e.value);
    }
    final keys = buckets.keys.toList()..sort();
    return [
      for (final k in keys)
        Offset(
          k.toDouble(),
          buckets[k]!.reduce((a, b) => a + b) / buckets[k]!.length,
        ),
    ];
  }

  String get _rangeTitle => widget.metric == 'vo2max'
      ? switch (_range) {
          0 => '近 7 天',
          1 => '近 30 天',
          2 => '近半年',
          _ => '近一年',
        }
      : switch (_range) {
          0 => '今日',
          1 => '近 7 天',
          2 => '近 30 天',
          3 => '近半年',
          _ => '近一年',
        };

  int _recordCount(MetricDetail detail) {
    final startMs = _rangeStart.millisecondsSinceEpoch;
    return switch (widget.metric) {
      'heart_rate' =>
        detail.samples.where((s) => s.timestampMs >= startMs).length,
      'bp' => _bp.where((e) => e.timestampMs >= startMs).length,
      'glucose' => _glucose.where((e) => e.timestampMs >= startMs).length,
      'weight' => _weights.where((e) => e.timestampMs >= startMs).length,
      _ => 0,
    };
  }

  List<Widget> _recordRows(MetricDetail detail) {
    final v = context.v;
    final startMs = _rangeStart.millisecondsSinceEpoch;
    if (widget.metric == 'heart_rate') {
      final samples = detail.samples
          .where((s) => s.timestampMs >= startMs)
          .toList();
      // 心率一天可能上千个采样；列表只给最近 10 次，趋势看上面的曲线。
      final capped = samples.length > 10
          ? samples.sublist(samples.length - 10)
          : samples;
      return [
        for (final s in capped.reversed)
          VRowItem(
            icon: Icons.favorite_rounded,
            iconBackground: v.tintHeart,
            iconColor: v.heartInk,
            title: '${s.value.round()} bpm',
            subtitle:
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(s.timestampMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(s.timestampMs))}',
          ),
        if (samples.length > capped.length)
          VRowItem(
            icon: Icons.info_outline_rounded,
            iconBackground: v.tintGrey,
            iconColor: v.muted,
            title: '仅显示最近 ${capped.length} 条',
            subtitle: '当前范围共 ${samples.length} 条采样',
          ),
      ];
    }
    if (_bp.isNotEmpty) {
      return [
        for (final e in _bp.where((e) => e.timestampMs >= startMs).take(30))
          VRowItem(
            icon: Icons.favorite_rounded,
            iconBackground: v.tintHeart,
            iconColor: v.heartInk,
            title: '${e.systolic}/${e.diastolic} mmHg',
            subtitle:
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} · 脉搏 ${e.pulse ?? '--'}',
            onTap: () => _recordActions(bp: e),
          ),
      ];
    }
    if (_glucose.isNotEmpty) {
      return [
        for (final e
            in _glucose.where((e) => e.timestampMs >= startMs).take(30))
          VRowItem(
            icon: Icons.bloodtype_rounded,
            iconBackground: v.tintGreen,
            iconColor: v.greenInk,
            title: '${_fmt(detail, e.value)} mmol/L',
            subtitle:
                '${relativeDay(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} · ${_glucoseType(e.measureType)}',
            onTap: () => _recordActions(glucose: e),
          ),
      ];
    }
    return [
      for (final e in _weights.where((e) => e.timestampMs >= startMs).take(30))
        VRowItem(
          icon: Icons.monitor_weight_rounded,
          iconBackground: v.tintSky,
          iconColor: v.skyInk,
          title: '${_fmt(detail, e.weightKg)} kg',
          subtitle:
              '${relativeDay(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))} ${clock(DateTime.fromMillisecondsSinceEpoch(e.timestampMs))}'
              '${e.bodyFatPercent == null ? '' : ' · 体脂 ${e.bodyFatPercent!.toStringAsFixed(1)}%'}',
          value: e.source == 'scale' ? '体脂秤' : '手动',
          onTap: () => _recordActions(weight: e),
        ),
    ];
  }

  String _glucoseType(String type) => switch (type) {
    'fasting' => '空腹',
    'before_meal' => '餐前',
    'after_meal' => '餐后',
    'bedtime' => '睡前',
    _ => '随机',
  };

  String _unit(MetricDetail d) => d.unit;
  String _fmt(MetricDetail d, double? value, {bool compact = false}) {
    if (value == null) return '--';
    if (d.metric == 'sleep' || d.metric == 'deep_sleep') {
      return fmtSleep(value.round());
    }
    if (d.metric == 'distance') {
      return compact ? value.toStringAsFixed(1) : value.toStringAsFixed(2);
    }
    if (d.metric == 'vo2max') {
      return value.toStringAsFixed(1);
    }
    if (d.metric == 'weight' ||
        d.metric == 'glucose' ||
        d.metric.startsWith('skin_temp') ||
        d.metric == 'body_temp') {
      return value.toStringAsFixed(1);
    }
    if (d.metric == 'steps' ||
        d.metric == 'calories' ||
        d.metric == 'active_calories') {
      return fmtInt(value);
    }
    return value.round().toString();
  }

  /// 情绪是分类编码，直接报数字（「3」）没人看得懂。
  String _valueLabel(MetricDetail d, double value) =>
      d.metric == 'emotion' ? emotionLabel(value.round()) : _fmt(d, value);

  String _big(MetricDetail d, double? value) {
    if (value == null) return '--';
    if (d.metric == 'emotion') return emotionLabel(value.round());
    if (d.metric == 'sleep' || d.metric == 'deep_sleep') {
      return fmtSleep(value.round());
    }
    // 首页写的是「108/68」，点进来只剩一个 108 会让人以为舒张压丢了
    if (d.metric == 'bp' && _bp.isNotEmpty) {
      final latest = _bp.first;
      return '${latest.systolic}/${latest.diastolic}';
    }
    return _fmt(d, value);
  }

  /// 情绪是分类编码，对它求平均/最低/最高会得到一个从没出现过的状态，只能按出现次数汇总。
  bool _isCategorical(MetricDetail d) => d.metric == 'emotion';

  /// 趋势的颜色回答的是「这件事算不算好」，不是「数字变大了还是变小了」。
  /// 一律把上涨涂绿，会让 +6.7 °C 的皮肤温度看起来像一件好事。
  Widget _trendChip(MetricDetail detail, double trend) {
    final v = context.v;
    final text = trend == 0
        ? '持平'
        : '${trend > 0 ? '↑' : '↓'} ${_fmt(detail, trend.abs(), compact: true)}';
    final dir = _trendDirection(detail.metric);
    if (trend == 0 || dir == 0) {
      return VChip(text: text, background: v.tintGrey, foreground: v.muted);
    }
    final good = (trend > 0) == (dir > 0);
    return VChip(
      text: text,
      background: good ? v.tintGreen : v.tintPeach,
      foreground: good ? v.greenInk : v.warnInk,
    );
  }

  List<Widget> _categoricalStats(MetricDetail detail) {
    final days = detail.days;
    if (days.isEmpty) {
      return [
        Expanded(
          child: VStat(label: '记录', value: '0 天', unit: ''),
        ),
      ];
    }
    final counts = <int, int>{};
    for (final p in days) {
      counts.update(p.value.round(), (n) => n + 1, ifAbsent: () => 1);
    }
    final ranked = counts.keys.toList()
      ..sort(
        (a, b) => counts[b]! != counts[a]!
            ? counts[b]!.compareTo(counts[a]!)
            : a.compareTo(b),
      );
    final positive = days
        .where((p) => emotionPolarity(p.value.round()) > 0)
        .length;
    final negative = days
        .where((p) => emotionPolarity(p.value.round()) < 0)
        .length;
    return [
      Expanded(
        child: VStat(label: '最常见', value: emotionLabel(ranked.first), unit: ''),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: VStat(label: '偏积极', value: '$positive', unit: '天'),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: VStat(label: '偏消极', value: '$negative', unit: '天'),
      ),
    ];
  }
}

/// +1 = 数值越高越好，-1 = 越低越好，0 = 说不清好坏（只描述，不评价）。
int _trendDirection(String metric) {
  if (_higherIsBetter.contains(metric)) return 1;
  if (_lowerIsBetter.contains(metric)) return -1;
  return 0;
}

const Set<String> _higherIsBetter = {
  'steps',
  'calories',
  'active_calories',
  'distance',
  'active_minutes',
  'exercise_minutes',
  'hrv',
  'sleep',
  'deep_sleep',
  'spo2',
  'vo2max',
};

const Set<String> _lowerIsBetter = {
  'resting_hr',
  'stress',
  'skin_temp',
  'temperature',
  'body_temp',
  'bp',
  'glucose',
};
