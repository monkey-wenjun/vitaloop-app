import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';

import '../../data/api.dart';
import '../../data/export_bridge.dart';
import '../../data/official_splits.dart';
import '../../data/watch_bridge.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/coordinate.dart';
import '../../util/format.dart';
import '../amap_route_map.dart';
import '../components.dart';
import '../nav.dart';
import '../scroll_capture.dart';
import '../sport_style.dart';
import '../workout_dynamics_analysis.dart';

/// 保存成路线时保留的轨迹点上限，沿用旧版 heart_sync 的取值。
const _maxRoutePoints = 4000;
const _detailSheetInitialSize = 0.44;
const _detailSheetMaxSize = 0.94;

const _zoneColors = [
  Color(0xFF8FB2F6),
  Color(0xFF6FCF97),
  Color(0xFFF2C94C),
  Color(0xFFF2994A),
  Color(0xFFEB5757),
];

const _statExtendLabels = <int, String>{
  300010035: '乳酸阈心率',
  300010036: '乳酸阈配速',
  300010038: '恢复时间',
  300010039: '有氧训练时间',
  300010040: '节奏训练时间',
  300010041: '无氧耐力训练时间',
  300010042: '最大摄氧量训练时间',
  300010043: '无氧训练时间',
  300010044: '冲刺训练时间',
  300010051: '平均触地时间',
  300010052: '平均腾空时间',
  300010058: '左右触地平衡',
  300010059: '垂直振幅',
  300010119: '耐力能力',
  300010120: '耐力能力评级',
  300010121: '耐力时间能力',
  300010122: '耐力时间能力评级',
  300010159: '活动热量',
  300010202: '平均坡度',
  300010203: '最大坡度',
  300010204: '最小坡度',
  300010205: '平均功率（推算）',
  300010206: '平均功率',
  300010207: '最大功率',
  300010208: '平均踏频',
  300010209: '最大踏频',
  300010212: '平均踏频（推算）',
  300010220: '跑力指数',
  300010221: '跑力指数变化',
  300010222: '有氧训练负荷峰值',
  300010223: '无氧训练负荷峰值',
  300010224: '最大功率（推算）',
  300010232: '训练负荷等级',
  300010247: '总训练量',
  300010249: '训练重量',
  300010250: '运动自觉强度(RPE)',
  300010300: '训练负荷峰值',
  300010345: '心率区间 1',
  300010346: '心率区间 2',
  300010347: '心率区间 3',
  300010348: '心率区间 4',
  300010349: '心率区间 5',
  900001: '平均功率（推算）',
  900002: '最大功率（推算）',
  900003: '标准化功率',
  900004: 'FTP（推算）',
  900005: '强度系数 IF',
  900006: '训练压力 TSS',
  900007: '功率区间',
};

const _statExtendOrder = <int>[
  300010220,
  300010221,
  300010035,
  300010036,
  300010300,
  300010222,
  300010223,
  300010232,
  300010051,
  300010052,
  300010058,
  300010059,
  300010159,
  300010206,
  300010205,
  300010207,
  300010224,
  300010208,
  300010212,
  300010209,
  300010202,
  300010203,
  300010204,
  300010345,
  300010346,
  300010347,
  300010348,
  300010349,
  900001,
  900002,
  900003,
  900004,
  900005,
  900006,
  900007,
];

class WorkoutDetailScreen extends StatefulWidget {
  const WorkoutDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<WorkoutDetailScreen> createState() => _WorkoutDetailScreenState();
}

class _WorkoutDetailScreenState extends State<WorkoutDetailScreen> {
  final GlobalKey _shareKey = GlobalKey();
  // 详情页有两种布局（有轨迹=面板内滚动，无轨迹=整页滚动），长截图只认这一个
  // 真正承载内容的 ListView，两种情况都挂在它身上。
  final GlobalKey _listKey = GlobalKey();
  final ScrollController _plainListController = ScrollController();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  ScrollController? _sheetListController;
  bool _sharing = false;
  late final Future<_WorkoutView?> _future = _load();
  bool _savingRoute = false;
  late final Future<List<StrengthSet>> _setsFuture = VitaloopApi.strengthSets(
    widget.id,
  );

  @override
  void dispose() {
    _plainListController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  Future<_WorkoutView?> _load() async {
    var detail = await VitaloopApi.workout(widget.id);
    if (detail == null) return null;
    final profile = await VitaloopApi.profile();
    await _ensureDerivedPower(detail, profile.weightKg);
    detail = await VitaloopApi.workout(widget.id) ?? detail;
    final values = await Future.wait([
      VitaloopApi.setting('max_hr', ''),
      VitaloopApi.setting('max_hr_auto', '1'),
    ]);
    final saved = int.tryParse(values[0]) ?? 0;
    if (values[1] == '0' && saved > 0) {
      return _WorkoutView.parse(detail, saved);
    }
    return _WorkoutView.parse(detail, estimatedMaxHr(profile.birthDate));
  }

  /// 旧版记录由手机按 GPS 轨迹现场估算骑行功率，数据库里没有功率曲线。
  /// 迁移后第一次打开详情时补算一次，之后直接读入库结果。
  Future<void> _ensureDerivedPower(
    WorkoutDetail detail,
    double weightKg,
  ) async {
    final sport = detail.summary.sport;
    final cycling = sport.contains('cycling') || sport.contains('spinning');
    if (!cycling) return;
    if ((detail.trackJson ?? '').isEmpty) return;
    final hasPower =
        (detail.statExtendJson ?? '').contains('"900001"') ||
        (detail.dynamicsJson ?? '').contains('"pwr"');
    if (hasPower) return;
    await VitaloopApi.analyzeCyclingWorkout(
      widget.id,
      riderWeightKg: weightKg > 0 ? weightKg : 65,
      bikeWeightKg: 10,
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: RepaintBoundary(
        key: _shareKey,
        child: SafeArea(
          bottom: false,
          child: FutureBuilder<_WorkoutView?>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final view = snapshot.data;
              if (view == null) {
                return const Center(child: Text('记录不存在'));
              }
              return _content(view);
            },
          ),
        ),
      ),
    );
  }

  Widget _content(_WorkoutView view) {
    final v = context.v;
    final w = view.w;
    final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final isCycling =
        w.sport.contains('cycling') || w.sport.contains('spinning');
    final pace = fmtPace(w.distanceM, w.durationSec);
    final speed = w.durationSec > 0
        ? (w.distanceM / 1000) / (w.durationSec / 3600)
        : 0.0;
    final avgKmh = w.durationSec > 0
        ? (w.distanceM / 1000) / (w.durationSec / 3600)
        : 0.0;
    final maxKmh = view.speed.isEmpty
        ? avgKmh
        : view.speed.map((p) => p.y).reduce(math.max);
    final maxAltitudeM = view.detail.maxAltitude ?? view.altitude.max;
    final minAltitudeM = view.detail.minAltitude ?? view.altitude.min;

    final body = <Widget>[
      VCard(
        margin: const EdgeInsets.only(top: 0, bottom: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: sportTint(context, w.sport),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    sportIcon(w.sport),
                    size: 19,
                    color: sportInk(context, w.sport),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sportName(w.sport),
                        style: VText.value.copyWith(fontSize: 17, color: v.ink),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${relativeDay(start)} ${clock(start)}',
                        style: VText.meta.copyWith(color: v.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '距离',
                        style: VText.label.copyWith(
                          fontSize: 10,
                          color: v.muted,
                        ),
                      ),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: (w.distanceM / 1000).toStringAsFixed(2),
                              style: VText.big.copyWith(
                                fontSize: 44,
                                color: v.ink,
                              ),
                            ),
                            TextSpan(
                              text: ' km',
                              style: VText.label.copyWith(
                                fontSize: 12,
                                color: v.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '用时',
                      style: VText.label.copyWith(fontSize: 10, color: v.muted),
                    ),
                    Text(
                      fmtDuration(w.durationSec),
                      style: VText.value.copyWith(fontSize: 24, color: v.ink),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: VStat(
                    label: isCycling ? '平均速度' : '平均配速',
                    value: isCycling ? speed.toStringAsFixed(1) : pace,
                    unit: isCycling ? ' km/h' : '/km',
                  ),
                ),
                if (w.avgHr > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '平均心率',
                      value: '${w.avgHr}',
                      unit: ' bpm',
                    ),
                  ),
                ],
                if (w.maxHr > 0) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '最高心率',
                      value: '${w.maxHr}',
                      unit: ' bpm',
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
      Row(
        children: [
          Expanded(
            child: VMini(
              label: '卡路里',
              value: fmtInt(w.calories),
              sub: 'kcal',
              background: v.peach,
              foreground: v.peachInk,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: VMini(
              label: '训练负荷',
              value: '${w.load}',
              sub: '负荷',
              background: v.sky,
              foreground: v.skyInk,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: VMini(
              label: '步数',
              value: fmtInt(w.steps),
              sub: '步',
              background: v.mint,
              foreground: v.mintInk,
            ),
          ),
        ],
      ),
      if (w.sport.contains('力量') ||
          w.sport.contains('strength') ||
          w.sport.contains('free_training'))
        _strengthSetsCard(),
      const SizedBox(height: 11),
      if (view.hasEffect) _effectCard(view),
      if (view.watchStats.isNotEmpty) _watchStatsCard(view),
      if (view.paceZones.isNotEmpty) _paceZonesCard(view),
      if (view.hr.length > 1)
        _chartCard(
          title: '心率曲线',
          trailing: '平均 ${w.avgHr} bpm',
          points: [
            for (var i = 0; i < view.hr.length; i++)
              Offset(i.toDouble(), view.hr[i].y),
          ],
          color: v.heartInk,
          height: 92,
          unit: 'bpm',
          xLabel: (x) => '第 ${x.round() + 1} 个采样',
          caption: '最低 ${view.hrMin} · 平均 ${w.avgHr} · 最高 ${view.hrMax} bpm',
          extra: [
            if (view.zones.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final z in view.zones)
                MiniZoneBar(
                  label: z.label,
                  value: '${z.minutes.round()} 分',
                  fraction: z.percent / 100,
                  trailing: '${z.percent.round()}%',
                  color: z.color,
                ),
              const SizedBox(height: 4),
              Text(
                '心率区间按最大 ${view.maxHr} bpm 计算。',
                style: VText.label.copyWith(fontSize: 10, color: v.muted),
              ),
            ],
          ],
        ),
      if (view.recovery.length > 1) _recoveryCard(view),
      if (view.speed.length > 1)
        _chartCard(
          title: '速度曲线',
          trailing: '平均 ${avgKmh.toStringAsFixed(1)} km/h',
          points: [for (final p in view.speed) Offset(p.x, p.y)],
          color: v.blue,
          unit: 'km/h',
          valueFormat: (value) => value.toStringAsFixed(1),
          xLabel: (x) => '${x.toStringAsFixed(2)} km',
          caption: isCycling
              ? '最快 ${maxKmh.toStringAsFixed(1)} km/h · 全程 ${(w.distanceM / 1000).toStringAsFixed(2)} km'
              : '最快 ${maxKmh.toStringAsFixed(1)} km/h · 平均配速 $pace/km',
        ),
      if (view.swimSegments.isNotEmpty) _swimSegmentsCard(view),
      if (view.altitude.points.length > 1)
        _chartCard(
          title: '海拔变化',
          trailing: maxAltitudeM == null
              ? null
              : '最高 ${maxAltitudeM.round()} m',
          points: [
            for (var i = 0; i < view.altitude.points.length; i++)
              Offset(i.toDouble(), view.altitude.points[i].y),
          ],
          color: v.peachInk,
          unit: 'm',
          xLabel: (x) => '第 ${x.round() + 1} 个采样',
          caption:
              '最高 ${maxAltitudeM?.round() ?? '--'} m · 最低 ${minAltitudeM?.round() ?? '--'} m'
              ' · 累计爬升 ${view.gain.round()} m · 下降 ${view.loss.round()} m',
        ),
      if (view.cadence.length > 1 ||
          view.power.length > 1 ||
          view.dynamicExtras.isNotEmpty)
        _dynamicsCard(view, isCycling: isCycling),
      if (view.splits.isNotEmpty) _splitsCard(view),
      VCard(
        child: Column(
          children: [
            _KvRow(
              label: '同步时间',
              value: '${relativeDay(start)} ${clock(start)}',
            ),
            _KvRow(label: '训练负荷', value: '${w.load}'),
            if (view.detail.startTempC != null)
              _KvRow(
                label: '环境温度',
                value: '${view.detail.startTempC!.toStringAsFixed(1)} °C',
              ),
            if (view.detail.startHumidity != null)
              _KvRow(label: '环境湿度', value: '${view.detail.startHumidity}%'),
            if (view.detail.maxMet != null)
              _KvRow(
                label: '最大 MET',
                value: view.detail.maxMet!.toStringAsFixed(1),
              ),
            if (view.detail.vo2Max != null)
              _KvRow(
                label: '最大摄氧量',
                value: '${view.detail.vo2Max!.toStringAsFixed(1)} ml/kg/min',
              ),
          ],
        ),
      ),
      if (!_sharing) ...[
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: VGhostButton(
                label: '分享长图',
                icon: Icons.share_rounded,
                onTap: () => _chooseShareMode(view),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: VPrimaryButton(
                label: '导出文件',
                icon: Icons.file_download_outlined,
                onTap: () => _export(context, w),
              ),
            ),
          ],
        ),
      ],
    ];

    final header = VDetailHeader(
      title: '运动详情',
      trailing: _sharing
          ? const SizedBox.shrink()
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (view.hasTrack) ...[
                  _CircleButton(
                    icon: _savingRoute
                        ? Icons.hourglass_top_rounded
                        : Icons.bookmark_add_rounded,
                    tooltip: '保存为路线',
                    onTap: _savingRoute ? null : () => _askSaveRoute(view),
                  ),
                  const SizedBox(width: 8),
                ],
                _CircleButton(
                  icon: Icons.ios_share_rounded,
                  tooltip: '分享长图',
                  onTap: () => _chooseShareMode(view),
                ),
              ],
            ),
    );

    if (!view.hasTrack) {
      return ListView(
        key: _listKey,
        controller: _plainListController,
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
        children: [header, ...body],
      );
    }

    // 旧版运动详情是「全屏地图 + 底部上拉面板」；这里保持同样结构，
    // 地图不再被压成一张 226dp 的缩略图。
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        Positioned.fill(
          child: AmapRouteMap(
            points: view.trackLatLng,
            height: null,
            radius: 0,
            // 旧版迁移与手表轨迹入库时已经是 GCJ-02；新版手机 GPS 手动记录
            // 才是 WGS-84。旧版 AMap 也是按这个规则直接绘制的。
            wgs84: workoutTrackIsWgs84(w.source),
            fitInsets: EdgeInsets.only(bottom: screenHeight * 0.46),
          ),
        ),
        Positioned(
          left: 14,
          right: 14,
          top: 0,
          child: SafeArea(bottom: false, child: header),
        ),
        DraggableScrollableSheet(
          controller: _sheetController,
          initialChildSize: _detailSheetInitialSize,
          minChildSize: _detailSheetInitialSize,
          maxChildSize: _detailSheetMaxSize,
          snap: true,
          builder: (context, controller) {
            _sheetListController = controller;
            return Container(
              decoration: BoxDecoration(
                color: v.bg,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 18,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ListView(
                key: _listKey,
                controller: controller,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: v.muted.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...body,
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _chartCard({
    required String title,
    String? trailing,
    required List<Offset> points,
    required Color color,
    double height = 86,
    String unit = '',
    String Function(double value)? valueFormat,
    String Function(double x)? xLabel,
    String? caption,
    List<Widget> extra = const [],
  }) {
    final v = context.v;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: VText.h3.copyWith(color: v.ink)),
              ),
              if (trailing != null)
                Text(trailing, style: VText.label.copyWith(color: v.muted)),
            ],
          ),
          const SizedBox(height: 10),
          HeartRateCurve(
            points: points,
            height: height,
            color: color,
            unit: unit,
            valueFormat: valueFormat ?? (value) => value.round().toString(),
            xLabel: xLabel,
          ),
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(
              caption,
              style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
            ),
          ],
          ...extra,
        ],
      ),
    );
  }

  Widget _strengthSetsCard() {
    final v = context.v;
    return FutureBuilder<List<StrengthSet>>(
      future: _setsFuture,
      builder: (context, snapshot) {
        final sets = snapshot.data ?? const <StrengthSet>[];
        if (sets.isEmpty) return const SizedBox.shrink();
        final groups = <String, List<StrengthSet>>{};
        for (final s in sets) {
          groups.putIfAbsent(s.exerciseName, () => []).add(s);
        }
        var volume = 0.0;
        var reps = 0;
        for (final s in sets) {
          volume += s.weightKg * s.reps;
          reps += s.reps;
        }
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('力量训练详情', style: VText.h3.copyWith(color: v.ink)),
                    const Spacer(),
                    Text(
                      '${sets.length} 组 · $reps 次',
                      style: VText.meta.copyWith(color: v.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final entry in groups.entries) ...[
                  Text(
                    entry.key,
                    style: VText.h3.copyWith(fontSize: 12.5, color: v.ink2),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in entry.value)
                        VChip(
                          text:
                              '${s.setNumber}. ${s.weightKg > 0 ? '${_num(s.weightKg)}kg × ' : ''}${s.reps}',
                          background: v.tintGrey,
                          foreground: v.ink2,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (volume > 0)
                  Text(
                    '总容量 ${_num(volume)} kg',
                    style: VText.label.copyWith(color: v.muted),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _num(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  Widget _effectCard(_WorkoutView view) {
    final v = context.v;
    final d = view.detail;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('训练效果', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              if (d.recoveryTimeMin > 0)
                VChip(
                  text: '建议恢复 ${_recoveryLabel(d.recoveryTimeMin)}',
                  background: v.tintGrey,
                  foreground: v.ink2,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _EffectTile(
                  label: '有氧效果',
                  value: d.aerobicEffect,
                  accent: v.blue,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _EffectTile(
                  label: '无氧效果',
                  value: d.anaerobicEffect,
                  accent: v.peachInk,
                ),
              ),
            ],
          ),
          if (d.maxMet != null ||
              d.vo2Max != null ||
              d.recoveryTimeMin > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (d.recoveryTimeMin > 0)
                  Expanded(
                    child: VStat(
                      label: '恢复时间',
                      value: _recoveryLabel(d.recoveryTimeMin),
                    ),
                  ),
                if (d.maxMet != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '最大 MET',
                      value: d.maxMet!.toStringAsFixed(1),
                    ),
                  ),
                ],
                if (d.vo2Max != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: VStat(
                      label: '最大摄氧量',
                      value: d.vo2Max!.toStringAsFixed(1),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _watchStatsCard(_WorkoutView view) {
    final v = context.v;
    final items = view.watchStats;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('手表统计', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              Text(
                '${items.length} 项',
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < items.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(child: _StatCell(item: items[i])),
                  const SizedBox(width: 8),
                  Expanded(
                    child: i + 1 < items.length
                        ? _StatCell(item: items[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _paceZonesCard(_WorkoutView view) {
    final v = context.v;
    final zones = view.paceZones;
    final total = zones.fold<int>(0, (sum, z) => sum + (z.seconds ?? 0));
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('配速区间', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              Text('手表官方', style: VText.label.copyWith(color: v.muted)),
            ],
          ),
          const SizedBox(height: 8),
          for (final z in zones)
            MiniZoneBar(
              label: 'Z${z.zone}',
              value: _paceZoneRange(z),
              fraction: total == 0 ? 0 : (z.seconds ?? 0) / total,
              trailing: z.seconds == null
                  ? '--'
                  : fmtDuration(z.seconds!.round()),
              color: _zoneColors[(z.zone - 1).clamp(0, 4).toInt()],
            ),
          const SizedBox(height: 4),
          Text(
            total == 0 ? '手表没有返回各区间用时。' : '按手表返回的配速边界与区间用时展示。',
            style: VText.label.copyWith(fontSize: 10, color: v.muted),
          ),
        ],
      ),
    );
  }

  String _paceZoneRange(_PaceZone zone) {
    final slow = zone.minSec;
    final fast = zone.maxSec;
    if (zone.zone == 1 && slow != null) {
      return '≥ ${_formatPace(slow.toDouble())}';
    }
    if (fast != null && slow != null) {
      return '${_formatPace(fast.toDouble())}–${_formatPace(slow.toDouble())}';
    }
    if (slow != null) return '≥ ${_formatPace(slow.toDouble())}';
    if (fast != null) return '≤ ${_formatPace(fast.toDouble())}';
    return '--';
  }

  Widget _splitsCard(_WorkoutView view) {
    final v = context.v;
    final splits = view.splits;
    final paces = [
      for (final s in splits)
        if (s.seconds > 0 && s.distanceM > 0) s.seconds / (s.distanceM / 1000),
    ];
    final minPace = paces.isEmpty ? 0.0 : paces.reduce(math.min);
    final maxPace = paces.isEmpty ? 0.0 : paces.reduce(math.max);
    final hasPartial = splits.last.partial;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('每公里分段', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              Text(
                '${splits.length} 段',
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final s in splits)
            MiniZoneBar(
              label: s.partial
                  ? '${(s.distanceM / 1000).toStringAsFixed(1)}k'
                  : '${s.index} km',
              value: _formatPace(
                s.distanceM > 0 ? s.seconds / (s.distanceM / 1000) : 0,
              ),
              fraction: maxPace > minPace
                  ? 0.25 +
                        0.75 *
                            ((maxPace -
                                        (s.distanceM > 0
                                            ? s.seconds / (s.distanceM / 1000)
                                            : maxPace)) /
                                    (maxPace - minPace))
                                .clamp(0.0, 1.0)
                  : 0.7,
              trailing: s.avgHr == null ? '--' : '${s.avgHr}',
              color: v.blue,
            ),
          const SizedBox(height: 4),
          Text(
            hasPartial ? '最后一段不足 1 公里，右列为该段平均心率。' : '右列为该公里平均心率。',
            style: VText.label.copyWith(fontSize: 10, color: v.muted),
          ),
        ],
      ),
    );
  }

  Widget _dynamicsCard(_WorkoutView view, {required bool isCycling}) {
    final v = context.v;
    final avgCad = view.avgCadence;
    final maxCad = view.cadence.isEmpty
        ? 0.0
        : view.cadence.map((p) => p.y).reduce(math.max);
    final avgPower = view.avgPower;
    final cadPoints = [
      for (var i = 0; i < view.cadence.length; i++)
        Offset(i.toDouble(), view.cadence[i].y),
    ];
    final powerPoints = [
      for (var i = 0; i < view.power.length; i++)
        Offset(i.toDouble(), view.power[i].y),
    ];
    final extras = view.dynamicExtras;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isCycling ? '踏频与功率' : '跑步动态',
                style: VText.h3.copyWith(color: v.ink),
              ),
              const Spacer(),
              if (avgCad > 0)
                Text(
                  '平均 ${avgCad.round()} ${isCycling ? 'rpm' : 'spm'}',
                  style: VText.label.copyWith(color: v.muted),
                ),
            ],
          ),
          if (view.cadence.length > 1) ...[
            const SizedBox(height: 10),
            HeartRateCurve(
              points: cadPoints,
              height: 78,
              color: v.greenInk,
              unit: isCycling ? 'rpm' : 'spm',
              valueFormat: (value) => value.round().toString(),
              xLabel: (x) => '第 ${x.round() + 1} 个采样',
            ),
            const SizedBox(height: 8),
            Text(
              '最高 ${maxCad.round()} ${isCycling ? 'rpm' : 'spm'}',
              style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
            ),
          ],
          if (view.power.length > 1) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '功率',
                  style: VText.label.copyWith(
                    color: v.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (avgPower > 0)
                  Text(
                    '平均 ${avgPower.round()} W · 最高 ${view.power.map((p) => p.y).reduce(math.max).round()} W',
                    style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            HeartRateCurve(
              points: powerPoints,
              height: 72,
              color: v.skyInk,
              unit: 'W',
              valueFormat: (value) => value.round().toString(),
              xLabel: (x) => '第 ${x.round() + 1} 个采样',
            ),
          ],
          for (var i = 0; i < extras.length; i++) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  extras[i].label,
                  style: VText.label.copyWith(
                    color: v.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  _dynamicSummary(extras[i]),
                  style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            HeartRateCurve(
              points: [
                for (var p = 0; p < extras[i].points.length; p++)
                  Offset(p.toDouble(), extras[i].points[p].y),
              ],
              height: 70,
              color: _zoneColors[i % _zoneColors.length],
              unit: extras[i].unit,
              valueFormat: (value) => value.toStringAsFixed(extras[i].decimals),
              xLabel: (x) => '第 ${x.round() + 1} 个采样',
            ),
            if (_dynamicAssessment(extras[i]) case final assessment?)
              _DynamicsAssessmentPanel(
                assessment: assessment,
                unitColor: _zoneColors[i % _zoneColors.length],
              ),
          ],
        ],
      ),
    );
  }

  Widget _swimSegmentsCard(_WorkoutView view) {
    final v = context.v;
    final segments = view.swimSegments;
    return VCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('游泳分段', style: VText.h3.copyWith(color: v.ink)),
              const Spacer(),
              Text(
                '${segments.length} 段',
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final s in segments)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '#${s.segment}',
                      style: VText.label.copyWith(color: v.muted),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${s.distanceM.round()} m',
                      style: VText.label.copyWith(color: v.ink2),
                    ),
                  ),
                  Text(
                    _formatSwimPace(s.paceSecPer100m),
                    style: VText.label.copyWith(
                      color: v.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(
                    width: 74,
                    child: Text(
                      '划水 ${s.strokes > 0 ? s.strokes : '--'}',
                      textAlign: TextAlign.right,
                      style: VText.label.copyWith(color: v.ink2),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: Text(
                      'SWOLF ${s.swolf > 0 ? s.swolf : '--'}',
                      textAlign: TextAlign.right,
                      style: VText.label.copyWith(color: v.muted),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatSwimPace(int secondsPer100m) {
    if (secondsPer100m <= 0) return '--';
    final m = secondsPer100m ~/ 60;
    final s = secondsPer100m % 60;
    return "$m'${s.toString().padLeft(2, '0')}\"/100m";
  }

  String _dynamicSummary(_DynamicSeries series) {
    if (series.points.isEmpty) return '--';
    final values = series.points.map((p) => p.y);
    final min = values.reduce(math.min);
    final max = values.reduce(math.max);
    final avg = values.reduce((a, b) => a + b) / series.points.length;
    String fmt(double value) => value.toStringAsFixed(series.decimals);
    return '平均 ${fmt(avg)} · 最低 ${fmt(min)} · 最高 ${fmt(max)} ${series.unit}';
  }

  DynamicsAssessment? _dynamicAssessment(_DynamicSeries series) {
    final average = _dynamicAverage(series);
    final assessment = assessRunningDynamics(
      label: series.label,
      average: average,
    );
    if (assessment == null || series.label != '左右触地平衡') {
      return assessment;
    }
    return DynamicsAssessment(
      grade: assessment.grade,
      headline: assessment.headline,
      advice:
          '左 ${average.toStringAsFixed(1)}% / 右 ${(100 - average).toStringAsFixed(1)}%；${assessment.advice}',
    );
  }

  double _dynamicAverage(_DynamicSeries series) =>
      series.points.map((p) => p.y).reduce((a, b) => a + b) /
      series.points.length;

  Widget _recoveryCard(_WorkoutView view) {
    final v = context.v;
    final first = view.recovery.first;
    final last = view.recovery.last;
    final drop = first - last;
    return _chartCard(
      title: '恢复心率曲线',
      trailing: '下降 ${drop >= 0 ? drop : -drop} bpm',
      points: [
        for (var i = 0; i < view.recovery.length; i++)
          Offset(i.toDouble(), view.recovery[i].toDouble()),
      ],
      color: v.heartInk,
      height: 78,
      unit: 'bpm',
      xLabel: (x) => '第 ${x.round() + 1} 个采样',
      caption:
          '运动后心率由 $first bpm 降至 $last bpm，共记录 ${view.recovery.length} 个采样点。',
    );
  }

  String _formatPace(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return '--';
    final total = seconds.round();
    return "${total ~/ 60}'${(total % 60).toString().padLeft(2, '0')}\"";
  }

  String _recoveryLabel(int minutes) {
    if (minutes >= 60) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      return m == 0 ? '$h 小时' : '$h 小时 $m 分';
    }
    return '$minutes 分钟';
  }

  /// 把这次运动的轨迹存成可复用的路线，和旧版一样可以顺手推送到手表。
  Future<void> _askSaveRoute(_WorkoutView view) async {
    final points = _routePoints(view);
    if (points.length < 2 || _savingRoute) return;
    final start = DateTime.fromMillisecondsSinceEpoch(view.w.startMs);
    final choice = await showDialog<_RouteSaveChoice>(
      context: context,
      builder: (_) => _RouteSaveDialog(
        defaultName: '${sportName(view.w.sport)} ${monthDay(start)}',
        pointCount: points.length,
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _savingRoute = true);
    try {
      await VitaloopApi.saveRoute(id: '', name: choice.name, points: points);
      if (!mounted) return;
      if (!choice.pushToWatch) {
        _snack('路线已保存，可在「运动 → 已保存路线」推送到手表');
        return;
      }
      _snack('路线已保存，正在发送到手表…');
      final result = await WatchBridge.instance.pushRoute(
        name: choice.name,
        distanceMeters: view.w.distanceM.toDouble(),
        points: points,
      );
      if (!mounted) return;
      _snack(result['message'] as String? ?? '路线发送完成');
    } catch (e) {
      if (mounted) _snack('保存路线失败：$e');
    } finally {
      if (mounted) setState(() => _savingRoute = false);
    }
  }

  void _snack(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  /// 轨迹点和已保存路线统一用 GCJ-02（手表下发与地图绘制都按它算）；
  /// 只有新版手机手动记录的轨迹入库才是 WGS-84。上限 4000 点沿用旧版，
  /// 免得一次几小时的运动把路线表撑爆。
  static List<GeoPoint> _routePoints(_WorkoutView view) {
    final wgs84 = workoutTrackIsWgs84(view.w.source);
    final points = <GeoPoint>[];
    for (final p in _downsample(view.track, _maxRoutePoints)) {
      if (wgs84) {
        final (lat, lon) = Coordinate.wgs84ToGcj02(p.lat, p.lon);
        points.add(GeoPoint(lat: lat, lon: lon));
      } else {
        points.add(GeoPoint(lat: p.lat, lon: p.lon));
      }
    }
    return points;
  }

  Future<void> _chooseShareMode(_WorkoutView view) async {
    final v = context.v;
    final mode = await showModalBottomSheet<_ShareMode>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_rounded, color: ctx.v.blueInk),
              title: const Text('长图'),
              subtitle: const Text('从顶部自动滚动拼接全部数据，包含地图'),
              onTap: () => Navigator.pop(ctx, _ShareMode.long),
            ),
            ListTile(
              leading: Icon(Icons.phone_android_rounded, color: ctx.v.greenInk),
              title: const Text('当前页'),
              subtitle: const Text('只保存和分享当前屏幕'),
              onTap: () => Navigator.pop(ctx, _ShareMode.currentPage),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    await _share(view, long: mode == _ShareMode.long);
  }

  Future<void> _share(_WorkoutView view, {required bool long}) async {
    if (_sharing) return;
    final w = view.w;
    setState(() => _sharing = true);
    try {
      // 等操作按钮先从页面移除，再截取和测量滚动内容。
      await _capturePause(milliseconds: 100);
      if (!mounted) return;
      final boundary =
          _shareKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('页面还没准备好');
      final ratio = math.min(MediaQuery.devicePixelRatioOf(context), 3.0);
      final image = long
          ? await _captureLong(view, boundary, ratio) ??
                await boundary.toImage(pixelRatio: ratio)
          : await boundary.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('截图编码失败');
      final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      final stamp =
          '${start.year}${start.month.toString().padLeft(2, '0')}${start.day.toString().padLeft(2, '0')}-'
          '${start.hour.toString().padLeft(2, '0')}${start.minute.toString().padLeft(2, '0')}';
      final bytes = data.buffer.asUint8List();
      final suffix = long ? 'long' : 'screen';
      final saved = await ExportBridge.instance.saveBytes(
        fileName: 'vitaloop-${w.sport}-$stamp-$suffix.png',
        mimeType: 'image/png',
        bytes: bytes,
      );
      final ok = await ExportBridge.instance.shareBytes(
        fileName: 'vitaloop-${w.sport}-$stamp-$suffix.png',
        mimeType: 'image/png',
        bytes: bytes,
      );
      if (!mounted) return;
      if (saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('长图已保存到相册 · Pictures/Vitaloop')),
        );
      }
      if (!ok) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('截图分享失败，请重试')));
      }
      return;
    } catch (_) {
      // 极少数机型的离屏合成失败时，退回复制成绩摘要，不让分享入口失灵。
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
    final text =
        '${sportName(w.sport)} ${(w.distanceM / 1000).toStringAsFixed(2)} km · ${fmtDuration(w.durationSec)} · ${fmtPace(w.distanceM, w.durationSec)}/km · ${w.calories} kcal — Vitaloop 元环';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('成绩摘要已复制')));
  }

  /// 逐屏滚动 + 按各自滚动量贴回一张长图。
  ///
  /// 有轨迹时地图和页头是固定的，面板内部才是可滚内容，所以第 2 屏起只取
  /// 面板那一条（顶部再让开圆角和拖拽条，否则它会在长图中间反复出现），
  /// 贴到 `cropTop + offset` 处。相邻屏故意重叠也没关系：画的是同一份内容，
  /// 后一屏覆盖前一屏，最后一屏不会留缝。
  Future<ui.Image?> _captureLong(
    _WorkoutView view,
    RenderRepaintBoundary boundary,
    double ratio,
  ) async {
    final listContext = _listKey.currentContext;
    if (listContext == null) return null;
    final controller = view.hasTrack
        ? _sheetListController
        : _plainListController;
    final scroll =
        controller?.position ?? findDescendantScrollPosition(listContext);
    if (scroll == null ||
        !scroll.hasContentDimensions ||
        scroll.maxScrollExtent < 8) {
      return null;
    }
    final screenH = MediaQuery.sizeOf(context).height;
    final sheet = view.hasTrack && _sheetController.isAttached
        ? _sheetController
        : null;
    final restoreSheetSize = sheet?.size;
    final restore = scroll.pixels;
    final pages = <(ui.Image, double)>[];
    var drawn = 0;
    ui.Image? mapImage;
    try {
      // 先让可拖面板保持正常高度，记录地图可见区域。
      scroll.jumpTo(0);
      if (sheet != null) sheet.jumpTo(_detailSheetInitialSize);
      await _capturePause(milliseconds: 220);
      if (!mounted || !listContext.mounted) return null;
      final listBox = listContext.findRenderObject() as RenderBox;
      final mapBottom = view.hasTrack
          ? listBox.localToGlobal(Offset.zero).dy
          : 0.0;

      // 展开面板并完整走到底，让懒加载卡片把真实 maxScrollExtent 撑开。
      scroll.jumpTo(0);
      await _capturePause();
      if (sheet != null) {
        sheet.jumpTo(_detailSheetMaxSize);
        await _capturePause(milliseconds: 220);
      }
      if (!mounted || !listContext.mounted) return null;
      final expandedBox = listContext.findRenderObject() as RenderBox;
      final cropTop = view.hasTrack
          ? expandedBox.localToGlobal(Offset.zero).dy + 26
          : 0.0;
      final viewport = math.max(screenH - cropTop, 1.0);
      // 留 24px 重叠，避免懒加载/字体布局造成页缝。
      final step = math.max(viewport - 24, 1.0);
      final finalMax = await _measureScrollExtent(scroll, step);

      final sourceWidth = boundary.size.width;
      final sourceHeight = view.hasTrack
          ? mapBottom + viewport + finalMax
          : screenH + finalMax;
      final pixelBudgetRatio = math.sqrt(
        18000000 / math.max(1.0, sourceWidth * sourceHeight),
      );
      final outputRatio = math.min(ratio, pixelBudgetRatio);

      if (view.hasTrack && sheet != null) {
        scroll.jumpTo(0);
        sheet.jumpTo(_detailSheetInitialSize);
        await _capturePause(milliseconds: 320);
        mapImage = await boundary.toImage(pixelRatio: outputRatio);
      }

      scroll.jumpTo(0);
      if (sheet != null) sheet.jumpTo(_detailSheetMaxSize);
      await _capturePause(milliseconds: 240);
      for (var offset = 0.0; offset <= finalMax + 0.5;) {
        scroll.jumpTo(offset);
        await _capturePause();
        pages.add((await boundary.toImage(pixelRatio: outputRatio), offset));
        if (offset >= finalMax - 0.5) break;
        offset = math.min(offset + step, finalMax);
      }
      if (pages.isEmpty) return null;
      final width = pages.first.$1.width.toDouble();
      final mapHeight = (mapBottom * outputRatio).round();
      final detailHeight = ((viewport + finalMax) * outputRatio).round();
      final height = mapHeight + detailHeight;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.clipRect(ui.Rect.fromLTWH(0, 0, width, height.toDouble()));
      if (mapImage != null && mapHeight > 0) {
        canvas.drawImageRect(
          mapImage,
          ui.Rect.fromLTWH(0, 0, width, mapHeight.toDouble()),
          ui.Rect.fromLTWH(0, 0, width, mapHeight.toDouble()),
          ui.Paint(),
        );
      }
      for (final (image, offset) in pages) {
        if (!view.hasTrack && drawn == 0) {
          canvas.drawImage(image, ui.Offset.zero, ui.Paint());
        } else {
          final srcTop = cropTop * outputRatio;
          final dstTop = mapHeight + offset * outputRatio;
          canvas.drawImageRect(
            image,
            ui.Rect.fromLTRB(
              0,
              srcTop,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            ui.Rect.fromLTRB(
              0,
              dstTop,
              image.width.toDouble(),
              dstTop + image.height - srcTop,
            ),
            ui.Paint(),
          );
        }
        image.dispose();
        drawn++;
      }
      final picture = recorder.endRecording();
      final long = await picture.toImage(width.round(), height);
      picture.dispose();
      return long;
    } finally {
      mapImage?.dispose();
      for (var i = drawn; i < pages.length; i++) {
        pages[i].$1.dispose();
      }
      scroll.jumpTo(restore);
      if (sheet != null && sheet.isAttached && restoreSheetSize != null) {
        sheet.jumpTo(restoreSheetSize);
      }
    }
  }

  Future<void> _capturePause({int milliseconds = 140}) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<double> _measureScrollExtent(
    ScrollPosition scroll,
    double step,
  ) async {
    scroll.jumpTo(0);
    await _capturePause();
    var offset = 0.0;
    for (var page = 0; page < 80; page++) {
      final max = scroll.maxScrollExtent;
      if (offset >= max - 0.5) {
        await _capturePause(milliseconds: 220);
        final refreshed = scroll.maxScrollExtent;
        if (refreshed <= max + 0.5) return refreshed;
      }
      offset = math.min(offset + step, scroll.maxScrollExtent);
      scroll.jumpTo(offset);
      await _capturePause();
    }
    return scroll.maxScrollExtent;
  }

  Future<void> _export(BuildContext context, WorkoutSummary w) async {
    final v = context.v;
    final format = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: v.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.route_rounded, color: ctx.v.greenInk),
              title: const Text('GPX 轨迹'),
              subtitle: const Text('通用 GPS 轨迹格式'),
              onTap: () => Navigator.pop(ctx, 'gpx'),
            ),
            ListTile(
              leading: Icon(Icons.monitor_heart_rounded, color: ctx.v.heartInk),
              title: const Text('TCX 训练'),
              subtitle: const Text('含心率、距离和海拔，兼容 Garmin / Strava'),
              onTap: () => Navigator.pop(ctx, 'tcx'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (format == null || !context.mounted) return;
    try {
      final content = format == 'tcx'
          ? await VitaloopApi.tcx(w.id)
          : await VitaloopApi.gpx(w.id);
      final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
      final stamp =
          '${start.year}${start.month.toString().padLeft(2, '0')}${start.day.toString().padLeft(2, '0')}-'
          '${start.hour.toString().padLeft(2, '0')}${start.minute.toString().padLeft(2, '0')}';
      final ok = await ExportBridge.instance.shareTextFile(
        fileName: 'vitaloop-${w.sport}-$stamp.$format',
        mimeType: format == 'tcx'
            ? 'application/vnd.garmin.tcx+xml'
            : 'application/gpx+xml',
        content: content,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ok ? '已打开分享面板' : '导出失败，请重试')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }
}

class _EffectTile extends StatelessWidget {
  const _EffectTile({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final double value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: VText.label.copyWith(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: v.ink2,
            ),
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value.toStringAsFixed(1),
                  style: VText.value.copyWith(fontSize: 22, color: accent),
                ),
                TextSpan(
                  text: ' / 5.0',
                  style: VText.label.copyWith(fontSize: 10.5, color: v.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _effectName(value),
            style: VText.label.copyWith(
              fontSize: 10,
              color: v.ink2.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

String _effectName(double value) {
  if (value <= 0) return '无数据';
  if (value < 1) return '轻微';
  if (value < 2) return '维持';
  if (value < 3) return '提升';
  if (value < 4) return '明显提升';
  if (value < 5) return '大幅提升';
  return '过度训练';
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: v.surface,
            shape: BoxShape.circle,
            border: Border.all(color: v.line),
          ),
          child: Icon(icon, size: 16, color: v.ink),
        ),
      ),
    );
  }
}

/// 「保存并推送」/「仅保存」的选择结果，对应旧版 RouteSaveDialog 的两个按钮。
class _RouteSaveChoice {
  const _RouteSaveChoice(this.name, this.pushToWatch);

  final String name;
  final bool pushToWatch;
}

class _RouteSaveDialog extends StatefulWidget {
  const _RouteSaveDialog({required this.defaultName, required this.pointCount});

  final String defaultName;
  final int pointCount;

  @override
  State<_RouteSaveDialog> createState() => _RouteSaveDialogState();
}

class _RouteSaveDialogState extends State<_RouteSaveDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit(bool pushToWatch) {
    final name = _name.text.trim();
    Navigator.pop(
      context,
      _RouteSaveChoice(name.isEmpty ? widget.defaultName : name, pushToWatch),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存为路线'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: tr('路线名称'),
                counterText: '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '共 ${widget.pointCount} 个轨迹点，保存后可在「运动 → 已保存路线」中推送到手表。',
              style: VText.label.copyWith(color: context.v.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _submit(false), child: const Text('仅保存')),
        FilledButton(
          onPressed: () => _submit(true),
          child: const Text('保存并推送'),
        ),
      ],
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: VText.meta.copyWith(color: v.muted)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: VText.meta.copyWith(
                color: v.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DynamicsAssessmentPanel extends StatelessWidget {
  const _DynamicsAssessmentPanel({
    required this.assessment,
    required this.unitColor,
  });

  final DynamicsAssessment assessment;
  final Color unitColor;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final (background, foreground) = switch (assessment.grade) {
      DynamicsGrade.excellent => (v.tintGreen, v.greenInk),
      DynamicsGrade.good => (v.tintBlue, v.blueInk),
      DynamicsGrade.average => (v.tintPeach, v.peachInk),
      DynamicsGrade.high => (v.tintHeart, v.heartInk),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: foreground,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${assessment.grade.label} · ${assessment.headline}',
                  style: VText.label.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Icon(Icons.insights_rounded, size: 15, color: unitColor),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${assessment.advice} 参考常见跑步动态范围，仅用于趋势观察，不作伤病判断。',
            style: VText.label.copyWith(fontSize: 10.5, color: foreground),
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.item});

  final _StatItem item;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: v.tintGrey,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: item.help ?? '',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: VText.label.copyWith(
                      fontSize: 10,
                      color: v.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (item.help != null) ...[
                  const SizedBox(width: 3),
                  Icon(Icons.info_outline_rounded, size: 12, color: v.muted),
                ],
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: item.value,
                  style: VText.value.copyWith(fontSize: 17, color: v.ink),
                ),
                if (item.unit.isNotEmpty)
                  TextSpan(
                    text: ' ${item.unit}',
                    style: VText.label.copyWith(fontSize: 9.5, color: v.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem {
  const _StatItem(this.label, this.value, this.unit, {this.help});

  final String label;
  final String value;
  final String unit;
  final String? help;
}

class _WorkoutView {
  _WorkoutView._({
    required this.detail,
    required this.track,
    required this.hr,
    required this.hrFull,
    required this.speed,
    required this.altitude,
    required this.cadence,
    required this.power,
    required this.dynamicExtras,
    required this.recovery,
    required this.splits,
    required this.swimSegments,
    required this.zones,
    required this.paceZones,
    required this.watchStats,
    required this.maxHr,
    required this.gain,
    required this.loss,
    required this.avgCadence,
    required this.avgPower,
  });

  final WorkoutDetail detail;
  final List<_TrackPoint> track;
  final List<_SeriesPoint> hr;
  // 曲线画的是抽稀后的点，最值必须回到原始采样，否则会和上方汇总里的「最高心率」打架
  final List<_SeriesPoint> hrFull;
  final List<_SeriesPoint> speed;
  final _Altitude altitude;
  final List<_SeriesPoint> cadence;
  final List<_SeriesPoint> power;
  final List<_DynamicSeries> dynamicExtras;
  final List<int> recovery;
  final List<_Split> splits;
  final List<_SwimSegment> swimSegments;
  final List<_Zone> zones;
  final List<_PaceZone> paceZones;
  final List<_StatItem> watchStats;
  final int maxHr;
  final double gain;
  final double loss;
  final double avgCadence;
  final double avgPower;

  WorkoutSummary get w => detail.summary;
  bool get hasTrack => track.length > 1;
  // 每次读都新建一份的话，地图那侧每帧都以为轨迹换了（provider 重建 + 折线重画）。
  // track 是 final 的，缓存一次即可。
  late final List<Offset> trackLatLng = [
    for (final p in track) Offset(p.lat, p.lon),
  ];
  int get hrMin =>
      hrFull.isEmpty ? 0 : hrFull.map((p) => p.y).reduce(math.min).round();
  int get hrMax => math.max(
    hrFull.isEmpty ? 0 : hrFull.map((p) => p.y).reduce(math.max).round(),
    w.maxHr,
  );
  bool get hasEffect =>
      detail.aerobicEffect > 0 ||
      detail.anaerobicEffect > 0 ||
      detail.recoveryTimeMin > 0 ||
      detail.maxMet != null ||
      detail.vo2Max != null;

  static _WorkoutView parse(WorkoutDetail detail, int maxHrSetting) {
    final w = detail.summary;
    final track = _parseTrack(detail.trackJson, w.durationSec);
    final totalKm = track.isEmpty ? w.distanceM / 1000 : track.last.km;
    final hrFull = _parseHr(detail.samplesJson);
    final hr = _downsample(hrFull, 240);
    final speed = _downsample(_speedSeries(track), 180);
    final altitude = _parseAltitude(detail.altitudeJson, track);
    final dynamics = _parseDynamics(detail.dynamicsJson);
    final recovery = _parseRecovery(detail.recoveryJson);
    final officialSplits = _parseOfficialSplits(
      detail.splitsJson,
      track,
      totalKm,
      hr,
    );
    final splits = officialSplits.isNotEmpty
        ? officialSplits
        : _computeSplits(track, totalKm, w.durationSec, hr);
    final swimSegments = _parseSwimSegments(detail.swimSegmentsJson);
    final paceZones = _parsePaceZones(detail.runPaceZonesJson);
    final watchStats = _watchStats(detail);

    final observedMax = hrFull.isEmpty
        ? 0
        : hrFull.map((p) => p.y).reduce(math.max).round();
    final maxHr = maxHrSetting > 90
        ? maxHrSetting
        : (observedMax > 140 ? observedMax : 190);
    final zones = _computeZones(hr, w.durationSec, maxHr);

    var gain = detail.elevationGain ?? 0;
    var loss = detail.elevationLoss ?? 0;
    if (gain <= 0 && loss <= 0 && altitude.points.length > 1) {
      gain = altitude.gain;
      loss = altitude.loss;
    }

    return _WorkoutView._(
      detail: detail,
      track: track,
      hr: hr,
      hrFull: hrFull,
      speed: speed,
      altitude: altitude,
      cadence: _downsample(dynamics.cadence, 160),
      power: _downsample(dynamics.power, 160),
      dynamicExtras: [
        for (final series in dynamics.extras)
          _DynamicSeries(
            label: series.label,
            unit: series.unit,
            decimals: series.decimals,
            points: _downsample(series.points, 160),
          ),
      ],
      recovery: recovery,
      splits: splits,
      swimSegments: swimSegments,
      zones: zones,
      paceZones: paceZones,
      watchStats: watchStats,
      maxHr: maxHr,
      gain: gain,
      loss: loss,
      avgCadence: detail.cadence ?? dynamics.avgCadence,
      avgPower: dynamics.avgPower,
    );
  }

  static List<_TrackPoint> _parseTrack(String? json, int durationSec) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final lats = <double>[];
    final lons = <double>[];
    final times = <int>[];
    final alts = <double?>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final lat = item['lat'];
      final lon = item['lon'];
      if (lat is! num || lon is! num) continue;
      final la = lat.toDouble();
      final lo = lon.toDouble();
      if (la.abs() > 90 ||
          lo.abs() > 180 ||
          (la.abs() < 0.0001 && lo.abs() < 0.0001)) {
        continue;
      }
      lats.add(la);
      lons.add(lo);
      final t = item['t'];
      times.add(t is num ? t.toInt() : 0);
      final alt = item['alt'];
      alts.add(alt is num ? alt.toDouble() : null);
    }
    if (lats.length < 2) return const [];

    final km = <double>[0];
    for (var i = 1; i < lats.length; i++) {
      km.add(
        km.last + _distance(lats[i - 1], lons[i - 1], lats[i], lons[i]) / 1000,
      );
    }
    final totalKm = km.last;

    int? base;
    for (final t in times) {
      if (t > 100000000000) {
        base = t;
        break;
      }
    }
    final sec = List<double>.filled(lats.length, -1);
    if (base != null) {
      for (var i = 0; i < times.length; i++) {
        if (times[i] > 0) sec[i] = math.max(0, (times[i] - base) / 1000);
      }
      var last = 0.0;
      for (var i = 0; i < sec.length; i++) {
        if (sec[i] < 0 || sec[i] < last) {
          sec[i] = last;
        } else {
          last = sec[i];
        }
      }
    }
    if (base == null || sec.last <= 1) {
      for (var i = 0; i < sec.length; i++) {
        sec[i] = totalKm > 0.01
            ? km[i] / totalKm * durationSec
            : durationSec * i / (sec.length - 1);
      }
    }

    return [
      for (var i = 0; i < lats.length; i++)
        _TrackPoint(
          lat: lats[i],
          lon: lons[i],
          km: km[i],
          sec: sec[i],
          alt: alts[i],
        ),
    ];
  }

  static List<_SeriesPoint> _parseHr(String? json) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final out = <_SeriesPoint>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final value = item['hr'];
      if (value is! num) continue;
      final y = value.toDouble();
      if (y <= 20 || y >= 240) continue;
      out.add(_SeriesPoint(x: out.length.toDouble(), y: y));
    }
    return out;
  }

  static _Dynamics _parseDynamics(String? json) {
    if (json == null || json.isEmpty) return const _Dynamics.empty();
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const _Dynamics.empty();
    }
    if (decoded is! List) return const _Dynamics.empty();
    final cadence = <double>[];
    final power = <double>[];
    final rawExtras = <String, List<double>>{
      'sl': [],
      'gct': [],
      'ht': [],
      'vo': [],
      'gtb': [],
      'vr': [],
      'spo2': [],
      'spd': [],
    };
    var cadSum = 0.0;
    var cadCount = 0;
    var powerSum = 0.0;
    var powerCount = 0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final cad = item['cad'];
      if (cad is num && cad > 0) {
        cadence.add(cad.toDouble());
        cadSum += cad;
        cadCount++;
      }
      final pwr = item['pwr'];
      if (pwr is num && pwr > 0) {
        power.add(pwr.toDouble());
        powerSum += pwr;
        powerCount++;
      }
      for (final entry in rawExtras.entries) {
        final value = item[entry.key];
        if (value is num && value > 0) {
          entry.value.add(value.toDouble());
        }
      }
    }
    List<_DynamicSeries> buildExtras() {
      _DynamicSeries? make(
        String key,
        String label,
        String unit,
        int decimals,
      ) {
        final values = rawExtras[key]!;
        if (values.length < 2) return null;
        return _DynamicSeries(
          label: label,
          unit: unit,
          decimals: decimals,
          points: [
            for (var i = 0; i < values.length; i++)
              _SeriesPoint(x: i.toDouble(), y: values[i]),
          ],
        );
      }

      return [
        ?make('sl', '步幅', 'cm', 0),
        ?make('gct', '触地时间', 'ms', 0),
        ?make('ht', '腾空时间', 'ms', 0),
        ?make('vo', '垂直振幅', 'cm', 1),
        ?make('gtb', '左右触地平衡', '%', 1),
        ?make('vr', '垂直步频比', '%', 1),
        ?make('spo2', '血氧', '%', 0),
        ?make('spd', '速度', 'km/h', 1),
      ];
    }

    return _Dynamics(
      cadence: [
        for (var i = 0; i < cadence.length; i++)
          _SeriesPoint(x: i.toDouble(), y: cadence[i]),
      ],
      power: [
        for (var i = 0; i < power.length; i++)
          _SeriesPoint(x: i.toDouble(), y: power[i]),
      ],
      avgCadence: cadCount == 0 ? 0 : cadSum / cadCount,
      avgPower: powerCount == 0 ? 0 : powerSum / powerCount,
      extras: buildExtras(),
    );
  }

  static List<_PaceZone> _parsePaceZones(String? json) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final out = <_PaceZone>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final zone = item['zone'];
      if (zone is! num) continue;
      out.add(
        _PaceZone(
          zone: zone.toInt(),
          minSec: item['min'] is num ? (item['min'] as num).toInt() : null,
          maxSec: item['max'] is num ? (item['max'] as num).toInt() : null,
          seconds: item['time'] is num ? (item['time'] as num).toInt() : null,
        ),
      );
    }
    out.sort((a, b) => a.zone.compareTo(b.zone));
    return out;
  }

  static List<_StatItem> _watchStats(WorkoutDetail detail) {
    final items = <_StatItem>[];
    final trainingPoints = detail.trainingPoints;
    if (trainingPoints != null && trainingPoints > 0) {
      items.add(
        _StatItem(
          '训练积分',
          '$trainingPoints',
          '',
          help: '手表上报的训练点数，不是训练负荷、EPOC 或卡路里；目前不做高低评级。',
        ),
      );
    }
    final epoc = detail.epoc;
    if (epoc != null && epoc > 0) {
      items.add(_StatItem('EPOC', '$epoc', ''));
    }
    items.addAll(_parseStatExtend(detail.statExtendJson));
    return items;
  }

  static List<_StatItem> _parseStatExtend(String? json) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final values = <int, String>{};
    for (final entry in decoded.entries) {
      final id = int.tryParse('${entry.key}');
      if (id == null) continue;
      values[id] = '${entry.value}';
    }
    final ordered =
        [
          for (final id in _statExtendOrder)
            if (values.containsKey(id)) id,
          for (final id in values.keys.where(
            (id) => !_statExtendOrder.contains(id),
          ))
            id,
        ]..sort((a, b) {
          if (a == b) return 0;
          final ai = _statExtendOrder.indexOf(a);
          final bi = _statExtendOrder.indexOf(b);
          if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
          if (ai >= 0) return -1;
          if (bi >= 0) return 1;
          return a.compareTo(b);
        });
    final out = <_StatItem>[];
    for (final id in ordered) {
      final raw = values[id]!;
      final item = _formatStatExtend(id, raw);
      if (item != null) out.add(item);
    }
    return out;
  }

  static _StatItem? _formatStatExtend(int id, String raw) {
    final label = _statExtendLabels[id];
    if (label == null) return null;
    final value = raw.trim();
    switch (id) {
      case 300010036:
        return _StatItem(label, _statPace(value), '/公里');
      case 300010035:
        return _StatItem(label, value, '次/分');
      case 300010051:
      case 300010052:
        return _StatItem(label, value, '毫秒');
      case 300010058:
        return _StatItem(label, _statDecimal(value), '%');
      case 300010059:
        return _StatItem(label, _statDecimal(value), '厘米');
      case 300010159:
        return _StatItem(label, _statCalories(value), '千卡');
      case 300010345:
      case 300010346:
      case 300010347:
      case 300010348:
      case 300010349:
        return _StatItem(label, _statMinutes(value), '分钟');
      case 300010202:
      case 300010203:
      case 300010204:
        return _StatItem(label, _statSlope(value), '%');
      case 300010206:
      case 300010205:
      case 300010207:
      case 300010224:
        return _StatItem(label, value, '瓦');
      case 300010208:
      case 300010212:
      case 300010209:
        return _StatItem(label, value, '转/分');
      case 900001:
      case 900002:
      case 900003:
      case 900004:
        return _StatItem(label, value, '瓦');
      case 900006:
        return _StatItem(label, value, '');
      default:
        return _StatItem(label, value, '');
    }
  }

  static _Altitude _parseAltitude(String? json, List<_TrackPoint> track) {
    var points = <_SeriesPoint>[];
    if (json != null && json.isNotEmpty) {
      dynamic decoded;
      try {
        decoded = jsonDecode(json);
      } catch (_) {
        decoded = null;
      }
      if (decoded is List) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final alt = item['alt'];
          if (alt is! num) continue;
          points.add(
            _SeriesPoint(x: points.length.toDouble(), y: alt.toDouble()),
          );
        }
      }
    }
    if (points.length < 2) {
      final alts = [
        for (final p in track)
          if (p.alt != null && p.alt! > -100) p.alt!,
      ];
      if (alts.length >= 2) {
        points = [
          for (var i = 0; i < alts.length; i++)
            _SeriesPoint(x: i.toDouble(), y: alts[i]),
        ];
      }
    }
    if (points.length < 2) {
      return const _Altitude(
        points: [],
        gain: 0,
        loss: 0,
        max: null,
        min: null,
      );
    }
    var gain = 0.0;
    var loss = 0.0;
    var maxAlt = points.first.y;
    var minAlt = points.first.y;
    for (var i = 1; i < points.length; i++) {
      final delta = points[i].y - points[i - 1].y;
      if (delta > 0.5) gain += delta;
      if (delta < -0.5) loss -= delta;
      maxAlt = math.max(maxAlt, points[i].y);
      minAlt = math.min(minAlt, points[i].y);
    }
    return _Altitude(
      points: points,
      gain: gain,
      loss: loss,
      max: maxAlt,
      min: minAlt,
    );
  }

  static List<int> _parseRecovery(String? json) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is num && item > 20 && item < 240) item.round(),
    ];
  }

  static List<_SeriesPoint> _speedSeries(List<_TrackPoint> track) {
    final out = <_SeriesPoint>[];
    for (var i = 1; i < track.length; i++) {
      final dt = track[i].sec - track[i - 1].sec;
      final ds = (track[i].km - track[i - 1].km) * 1000;
      if (dt <= 0.5 || ds <= 0) continue;
      final kmh = ds / dt * 3.6;
      if (kmh <= 0.5 || kmh > 70) continue;
      out.add(_SeriesPoint(x: track[i].km, y: kmh));
    }
    return out;
  }

  /// 游泳分段：WorkoutSwimSegments 每段的距离、配速、划水次数和 SWOLF。
  static List<_SwimSegment> _parseSwimSegments(String? json) {
    if (json == null || json.isEmpty) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final out = <_SwimSegment>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final segment = (item['segment'] as num?)?.toInt() ?? out.length + 1;
      final distance = (item['distance'] as num?)?.toDouble() ?? 0;
      if (distance <= 0) continue;
      out.add(
        _SwimSegment(
          segment: segment,
          distanceM: distance,
          paceSecPer100m: (item['pace'] as num?)?.toInt() ?? 0,
          strokes: (item['strokes'] as num?)?.toInt() ?? 0,
          swolf: (item['swolf'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    out.sort((a, b) => a.segment.compareTo(b.segment));
    return out;
  }

  /// 手表 0x0c 的官方分段优先于 GPS 推算。type=0 是整公里，
  /// type=1 是整英里；页面统一按公里展示，所以只取 type=0。
  static List<_Split> _parseOfficialSplits(
    String? json,
    List<_TrackPoint> track,
    double totalKm,
    List<_SeriesPoint> hr,
  ) {
    final entries = parseOfficialSplitEntries(json);
    if (entries.isEmpty) return const [];

    final officialM = entries.fold<double>(0, (sum, e) => sum + e.distanceM);
    final denom = officialM > 0 ? officialM : math.max(1.0, totalKm * 1000);
    var cumulative = 0.0;
    final out = <_Split>[];
    for (final e in entries) {
      final from = (cumulative / denom).clamp(0.0, 1.0);
      cumulative += e.distanceM;
      final to = (cumulative / denom).clamp(0.0, 1.0);
      out.add(
        _Split(
          index: out.length + 1,
          distanceM: e.distanceM,
          seconds: e.paceSecondsPerKm * e.distanceM / 1000.0,
          avgHr: _avgHr(hr, from, to),
          gain: _gainBetweenFraction(track, from, to),
          partial: e.partial || e.distanceM < 999,
        ),
      );
    }
    return out;
  }

  static List<_Split> _computeSplits(
    List<_TrackPoint> track,
    double totalKm,
    int durationSec,
    List<_SeriesPoint> hr,
  ) {
    if (track.length < 2 || totalKm < 0.05) return const [];
    final splits = <_Split>[];
    var lastKm = 0.0;
    var lastSec = 0.0;
    var nextKm = 1.0;
    var segStart = 0;
    for (var i = 1; i < track.length; i++) {
      final prev = track[i - 1];
      final cur = track[i];
      while (nextKm <= totalKm + 1e-9 && cur.km >= nextKm - 1e-9) {
        final spanKm = cur.km - prev.km;
        final fraction = spanKm <= 1e-9
            ? 1.0
            : ((nextKm - prev.km) / spanKm).clamp(0.0, 1.0);
        final secAt = prev.sec + (cur.sec - prev.sec) * fraction;
        splits.add(
          _Split(
            index: splits.length + 1,
            distanceM: 1000,
            seconds: math.max(0, secAt - lastSec),
            avgHr: _avgHr(hr, lastKm / totalKm, nextKm / totalKm),
            gain: _gainBetween(track, segStart, i),
            partial: false,
          ),
        );
        lastKm = nextKm;
        lastSec = math.max(lastSec, secAt);
        nextKm += 1;
        segStart = i;
      }
    }
    final remainKm = totalKm - lastKm;
    if (remainKm > 0.03) {
      final endSec = math.max(lastSec, track.last.sec);
      splits.add(
        _Split(
          index: splits.length + 1,
          distanceM: remainKm * 1000,
          seconds: math.max(0, endSec - lastSec),
          avgHr: _avgHr(hr, lastKm / totalKm, 1),
          gain: _gainBetween(track, segStart, track.length - 1),
          partial: true,
        ),
      );
    }
    return splits;
  }

  static int? _avgHr(List<_SeriesPoint> hr, double from, double to) {
    if (hr.isEmpty) return null;
    final a = (from.clamp(0.0, 1.0) * hr.length).floor().clamp(
      0,
      hr.length - 1,
    );
    final b = (to.clamp(0.0, 1.0) * hr.length).ceil().clamp(a + 1, hr.length);
    var sum = 0.0;
    for (var i = a; i < b; i++) {
      sum += hr[i].y;
    }
    return (sum / (b - a)).round();
  }

  static double _gainBetween(List<_TrackPoint> track, int from, int to) {
    var gain = 0.0;
    double? prev;
    for (var i = from; i <= to && i < track.length; i++) {
      final alt = track[i].alt;
      if (alt == null) continue;
      if (prev != null && alt - prev > 0.5) gain += alt - prev;
      prev = alt;
    }
    return gain;
  }

  static double _gainBetweenFraction(
    List<_TrackPoint> track,
    double from,
    double to,
  ) {
    if (track.length < 2) return 0;
    final last = track.length - 1;
    final start = (from * last).floor().clamp(0, last);
    final end = (to * last).ceil().clamp(start, last);
    return _gainBetween(track, start, end);
  }

  static List<_Zone> _computeZones(
    List<_SeriesPoint> hr,
    int durationSec,
    int maxHr,
  ) {
    if (hr.isEmpty || maxHr <= 0) return const [];
    final counts = List<int>.filled(5, 0);
    for (final p in hr) {
      final ratio = p.y / maxHr;
      var zone = 1;
      if (ratio >= 0.9) {
        zone = 5;
      } else if (ratio >= 0.8) {
        zone = 4;
      } else if (ratio >= 0.7) {
        zone = 3;
      } else if (ratio >= 0.6) {
        zone = 2;
      }
      counts[zone - 1]++;
    }
    final minutes = durationSec / 60;
    return [
      for (var i = 0; i < 5; i++)
        _Zone(
          label: 'Z${i + 1}',
          minutes: minutes * counts[i] / hr.length,
          percent: counts[i] * 100 / hr.length,
          color: _zoneColors[i],
        ),
    ];
  }

  static double _distance(double lat1, double lon1, double lat2, double lon2) {
    const radius = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * radius * math.asin(math.min(1.0, math.sqrt(a.toDouble())));
  }
}

class _TrackPoint {
  const _TrackPoint({
    required this.lat,
    required this.lon,
    required this.km,
    required this.sec,
    required this.alt,
  });

  final double lat;
  final double lon;
  final double km;
  final double sec;
  final double? alt;
}

class _SeriesPoint {
  const _SeriesPoint({required this.x, required this.y});

  final double x;
  final double y;
}

enum _ShareMode { long, currentPage }

class _Split {
  const _Split({
    required this.index,
    required this.distanceM,
    required this.seconds,
    required this.avgHr,
    required this.gain,
    required this.partial,
  });

  final int index;
  final double distanceM;
  final double seconds;
  final int? avgHr;
  final double gain;
  final bool partial;
}

class _SwimSegment {
  const _SwimSegment({
    required this.segment,
    required this.distanceM,
    required this.paceSecPer100m,
    required this.strokes,
    required this.swolf,
  });

  final int segment;
  final double distanceM;
  final int paceSecPer100m;
  final int strokes;
  final int swolf;
}

class _Zone {
  const _Zone({
    required this.label,
    required this.minutes,
    required this.percent,
    required this.color,
  });

  final String label;
  final double minutes;
  final double percent;
  final Color color;
}

class _Dynamics {
  const _Dynamics({
    required this.cadence,
    required this.power,
    required this.extras,
    required this.avgCadence,
    required this.avgPower,
  });

  const _Dynamics.empty()
    : cadence = const [],
      power = const [],
      extras = const [],
      avgCadence = 0,
      avgPower = 0;

  final List<_SeriesPoint> cadence;
  final List<_SeriesPoint> power;
  final List<_DynamicSeries> extras;
  final double avgCadence;
  final double avgPower;
}

class _DynamicSeries {
  const _DynamicSeries({
    required this.label,
    required this.unit,
    required this.decimals,
    required this.points,
  });

  final String label;
  final String unit;
  final int decimals;
  final List<_SeriesPoint> points;
}

class _PaceZone {
  const _PaceZone({
    required this.zone,
    required this.minSec,
    required this.maxSec,
    required this.seconds,
  });

  final int zone;
  final int? minSec;
  final int? maxSec;
  final int? seconds;
}

class _Altitude {
  const _Altitude({
    required this.points,
    required this.gain,
    required this.loss,
    required this.max,
    required this.min,
  });

  final List<_SeriesPoint> points;
  final double gain;
  final double loss;
  final double? max;
  final double? min;
}

List<T> _downsample<T>(List<T> input, int max) {
  if (input.length <= max) return input;
  final out = <T>[];
  final step = (input.length - 1) / (max - 1);
  for (var i = 0; i < max; i++) {
    out.add(input[(i * step).round().clamp(0, input.length - 1)]);
  }
  return out;
}

String _statPace(String raw) {
  final seconds = int.tryParse(raw);
  if (seconds == null || seconds <= 0) return raw;
  return "${seconds ~/ 60}'${(seconds % 60).toString().padLeft(2, '0')}\"";
}

String _statCalories(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return raw;
  return (value / 1000).round().toString();
}

String _statMinutes(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return raw;
  return (value / 60000).round().toString();
}

String _statSlope(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return raw;
  return (value / 10).toStringAsFixed(1);
}

String _statDecimal(String raw) {
  final value = double.tryParse(raw);
  if (value == null) return raw;
  return value.toStringAsFixed(1);
}
