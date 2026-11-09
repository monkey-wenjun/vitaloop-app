import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/ui_translations.dart';
import 'package:vitaloop/l10n/localized_text.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../util/range_buckets.dart';

class VCard extends StatelessWidget {
  const VCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.background,
    this.foreground,
    this.margin = const EdgeInsets.only(bottom: 11),
    this.radius = 26,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? background;
  final Color? foreground;
  final EdgeInsets margin;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? v.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: background == null ? v.line : Colors.transparent,
        ),
      ),
      child: foreground == null
          ? child
          : DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: child,
              ),
            ),
    );
    if (onTap == null) return box;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: box,
    );
  }
}

class VSectionHead extends StatelessWidget {
  const VSectionHead({
    super.key,
    required this.title,
    this.trailing,
    this.onTrailing,
    this.padding = const EdgeInsets.fromLTRB(2, 8, 2, 10),
  });

  final String title;
  final String? trailing;
  final VoidCallback? onTrailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(title, style: VText.h2.copyWith(color: v.ink)),
          const Spacer(),
          if (trailing != null)
            GestureDetector(
              onTap: onTrailing,
              behavior: HitTestBehavior.opaque,
              child: Text(
                trailing!,
                style: VText.meta.copyWith(color: v.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class VIconBox extends StatelessWidget {
  const VIconBox({
    super.key,
    required this.icon,
    this.background,
    this.foreground,
    this.size = 38,
    this.radius = 13,
  });

  final IconData icon;
  final Color? background;
  final Color? foreground;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? v.tintGrey,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.52, color: foreground ?? v.ink2),
    );
  }
}

class VRowItem extends StatelessWidget {
  const VRowItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.badge,
    this.value,
    this.valueSub,
    this.iconBackground,
    this.iconColor,
    this.onTap,
    this.showChevron = false,
    this.trailing,
    this.color,
    this.padding = const EdgeInsets.symmetric(vertical: 12),
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final String? badge;
  final String? value;
  final String? valueSub;
  final Color? iconBackground;
  final Color? iconColor;
  final VoidCallback? onTap;
  final bool showChevron;
  final Widget? trailing;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          if (icon != null) ...[
            VIconBox(
              icon: icon!,
              background: iconBackground,
              foreground: iconColor,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: VText.h3.copyWith(color: color ?? v.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      style: VText.meta.copyWith(
                        color: v.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (badge != null)
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: v.tintGrey,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge!,
                      style: VText.label.copyWith(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: v.ink2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (value != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value!,
                  style: VText.meta.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: color ?? v.ink,
                  ),
                ),
                if (valueSub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      valueSub!,
                      style: VText.label.copyWith(fontSize: 10, color: v.muted),
                    ),
                  ),
              ],
            ),
          ?trailing,
          if (showChevron)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: v.muted,
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }
}

class VChip extends StatelessWidget {
  const VChip({
    super.key,
    required this.text,
    this.background,
    this.foreground,
    this.icon,
  });

  final String text;
  final Color? background;
  final Color? foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background ?? v.tintBlue,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground ?? v.blueInk),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: foreground ?? v.blueInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VTile extends StatelessWidget {
  const VTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.background,
    this.foreground,
    this.progress,
    this.onTap,
    this.height = 76,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final Color? background;
  final Color? foreground;
  final double? progress;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final fg = foreground ?? v.ink;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 准备度右侧只有 ~120dp，沿用大卡片的图标和间距会把「今日运动」
        // 挤成省略号。窄卡片单独用紧凑尺寸，但内容和进度填充保持一致。
        final compact = constraints.maxWidth < 150;
        final cardHeight = compact ? 66.0 : height;
        final iconSize = compact ? 28.0 : 36.0;
        final hPad = compact ? 9.0 : 12.0;
        final vPad = compact ? 8.0 : 11.0;
        return GestureDetector(
          onTap: onTap,
          child: Container(
            height: cardHeight,
            decoration: BoxDecoration(
              color: background ?? v.surface,
              borderRadius: BorderRadius.circular(21),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(21),
              child: Stack(
                children: [
                  // 进度做成整张卡底下从左往右的一层撞色填充：宽度就是完成度，
                  // 比右侧一个小环或底部 3px 细线都更直观，也不会被内容挤掉。
                  if (progress != null)
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progress!.clamp(0, 1).toDouble(),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: v.isDark ? 0.26 : 0.18),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: hPad,
                      vertical: vPad,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: iconSize,
                          height: iconSize,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: v.isDark ? 0.10 : 0.52,
                            ),
                            borderRadius: BorderRadius.circular(
                              compact ? 10 : 12,
                            ),
                          ),
                          child: Icon(
                            icon,
                            size: compact ? 15.5 : 19,
                            color: fg,
                          ),
                        ),
                        SizedBox(width: compact ? 7 : 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: VText.label.copyWith(
                                  fontSize: compact ? 10.5 : null,
                                  color: fg.withValues(alpha: 0.72),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: value,
                                      style: VText.value.copyWith(
                                        color: fg,
                                        fontSize: compact ? 15.5 : 17,
                                      ),
                                    ),
                                    if (unit != null)
                                      TextSpan(
                                        text: ' $unit',
                                        style: VText.label.copyWith(
                                          fontSize: compact ? 8.5 : 9.5,
                                          color: fg.withValues(alpha: 0.7),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class VMini extends StatelessWidget {
  const VMini({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.sub,
    this.background,
    this.foreground,
    this.onTap,
  });

  final String label;
  final String value;
  final String? unit;
  final String? sub;
  final Color? background;
  final Color? foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final fg = foreground ?? v.ink;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 78,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: background ?? v.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(
                height: 1.15,
                color: fg.withValues(alpha: 0.7),
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: VText.value.copyWith(
                      fontSize: 17,
                      height: 1.15,
                      color: fg,
                    ),
                  ),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: VText.label.copyWith(
                        fontSize: 9,
                        color: fg.withValues(alpha: 0.65),
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              sub ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VText.label.copyWith(
                fontSize: 9.5,
                height: 1.15,
                color: fg.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VStat extends StatelessWidget {
  const VStat({super.key, required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: v.tintGrey,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: VText.label.copyWith(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: v.muted,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: VText.value.copyWith(fontSize: 16, color: v.ink),
              ),
              if (unit != null) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(
                    unit!,
                    style: VText.label.copyWith(fontSize: 10, color: v.muted),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class VSegmented extends StatelessWidget {
  const VSegmented({
    super.key,
    required this.options,
    required this.index,
    required this.onChanged,
    this.margin = const EdgeInsets.symmetric(vertical: 10),
  });

  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: v.isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: i == index
                        ? (v.isDark ? const Color(0xFF223350) : Colors.white)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: i == index && !v.isDark
                        ? const [
                            BoxShadow(
                              color: Color(0x1A14203C),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    options[i],
                    style: VText.meta.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: i == index ? v.ink : v.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class VRangeBars extends StatelessWidget {
  const VRangeBars({
    super.key,
    required this.buckets,
    required this.color,
    this.height = 96,
  });

  final List<RangeBucket> buckets;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    if (buckets.isEmpty) {
      return SizedBox(
        height: 90,
        child: Center(
          child: Text('暂无趋势数据', style: VText.label.copyWith(color: v.muted)),
        ),
      );
    }
    // 刻度只按有数据的桶算：铺满窗口后空格会是一个个 0，把它们算进 min 会把
    // 体温这种「数值本身都差不多」的指标压成一根根等高柱。
    final measured = [
      for (final b in buckets)
        if (b.value > 0) b.value,
    ];
    final scaleValues = measured.isEmpty
        ? [for (final b in buckets) b.value]
        : measured;
    var min = scaleValues.first;
    var max = scaleValues.first;
    for (final value in scaleValues) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    final span = (max - min).abs() < 0.0001 ? 1.0 : max - min;
    final count = buckets.length;
    // 高亮给最近一次真的有数据的桶，而不是窗口最后一天——窗口末尾常常是空的。
    var highlight = -1;
    for (var i = count - 1; i >= 0; i--) {
      if (buckets[i].value > 0) {
        highlight = i;
        break;
      }
    }
    final barSpace = height - 20;
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < count; i++) ...[
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // 柱宽封顶：数据点少（如手动血压/体重）时避免 Expanded 撑成整块色板
                      Container(
                        constraints: const BoxConstraints(maxWidth: 18),
                        width: double.infinity,
                        // 无数据的桶只留一条底线，否则整排等高的实心柱会让人误以为有活动
                        height: buckets[i].value <= 0
                            ? 3
                            : 8 + barSpace * ((buckets[i].value - min) / span),
                        decoration: BoxDecoration(
                          color: i == highlight
                              ? color
                              : color.withValues(alpha: v.isDark ? 0.45 : 0.28),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ],
                  ),
                ),
                if (i != count - 1) SizedBox(width: count > 16 ? 2 : 5),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              buckets.first.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
            const Spacer(),
            Text(
              buckets.last.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
          ],
        ),
      ],
    );
  }
}

String _defaultChartValue(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

String _chartDateLabel(double x) {
  final d = DateTime.fromMillisecondsSinceEpoch(x.round());
  final date = '${d.month}/${d.day}';
  return d.hour == 0 && d.minute == 0 ? date : '$date ${clock(d)}';
}

/// 点选图表时浮在触点上方的数值气泡：第一行日期，后面是各序列的值。
class _ChartTipOverlay extends StatelessWidget {
  const _ChartTipOverlay({
    required this.x,
    required this.width,
    required this.lines,
  });

  final double x;
  final double width;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    const tipWidth = 136.0;
    final left = (x - tipWidth / 2)
        .clamp(0.0, math.max(0.0, width - tipWidth))
        .toDouble();
    return Positioned(
      left: left,
      top: 0,
      width: tipWidth,
      child: Align(
        alignment: Alignment.topCenter,
        child: _ChartTip(lines: lines),
      ),
    );
  }
}

class _ChartTip extends StatelessWidget {
  const _ChartTip({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: v.ink,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: v.isDark ? 0.35 : 0.14),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++)
            Text(
              lines[i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: i == 0 ? 9 : 11.5,
                height: 1.35,
                fontWeight: i == 0 ? FontWeight.w500 : FontWeight.w700,
                color: v.bg.withValues(alpha: i == 0 ? 0.62 : 1),
              ),
            ),
        ],
      ),
    );
  }
}

/// 连续指标的日/周/月趋势线。空桶断开而不是补 0，避免「那天没测」被画成
/// 「心率掉到 0」；x 轴仍按完整窗口铺开，所以稀疏数据的时间位置不会跑偏。
class VRangeLine extends StatefulWidget {
  const VRangeLine({
    super.key,
    required this.buckets,
    required this.color,
    this.height = 96,
    this.connectGaps = false,
    this.unit = '',
    this.valueFormat,
    this.dateLabel,
  });

  final List<RangeBucket> buckets;
  final Color color;
  final double height;

  /// 稀疏指标（如按月汇总的最大摄氧量）中间没有记录的月份不该把线截断。
  final bool connectGaps;
  final String unit;
  final String Function(double value)? valueFormat;
  final String Function(RangeBucket bucket)? dateLabel;

  @override
  State<VRangeLine> createState() => _VRangeLineState();
}

class _VRangeLineState extends State<VRangeLine> {
  int? _index;

  void _select(double dx, double width) {
    final count = widget.buckets.length;
    if (count == 0) return;
    final index = (((dx - 4) / math.max(1.0, width - 8)) * (count - 1))
        .round()
        .clamp(0, count - 1)
        .toInt();
    if (_index != index) setState(() => _index = index);
  }

  double _xOf(int index, double width) {
    if (widget.buckets.length <= 1) return width / 2;
    return 4 + index / (widget.buckets.length - 1) * (width - 8);
  }

  List<String> _tipLines(RangeBucket bucket) {
    final date =
        widget.dateLabel?.call(bucket) ??
        '${bucket.start.month}/${bucket.start.day}';
    final value = bucket.value > 0
        ? '${(widget.valueFormat ?? _defaultChartValue)(bucket.value)}${widget.unit.isEmpty ? '' : ' ${widget.unit}'}'
        : '无记录';
    return [date, value];
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final buckets = widget.buckets;
    if (buckets.isEmpty) {
      return SizedBox(
        height: 90,
        child: Center(
          child: Text('暂无趋势数据', style: VText.label.copyWith(color: v.muted)),
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: widget.height,
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final index = _index != null && _index! < buckets.length
                  ? _index
                  : null;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _select(d.localPosition.dx, width),
                      onHorizontalDragStart: (d) =>
                          _select(d.localPosition.dx, width),
                      onHorizontalDragUpdate: (d) =>
                          _select(d.localPosition.dx, width),
                      child: CustomPaint(
                        painter: _RangeLinePainter(
                          buckets: buckets,
                          color: widget.color,
                          grid: v.line,
                          connectGaps: widget.connectGaps,
                          highlightIndex: index,
                        ),
                      ),
                    ),
                  ),
                  if (index != null)
                    _ChartTipOverlay(
                      x: _xOf(index, width),
                      width: width,
                      lines: _tipLines(buckets[index]),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              buckets.first.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
            const Spacer(),
            Text(
              buckets.last.label,
              style: VText.label.copyWith(fontSize: 9, color: v.muted),
            ),
          ],
        ),
      ],
    );
  }
}

class _RangeLinePainter extends CustomPainter {
  _RangeLinePainter({
    required this.buckets,
    required this.color,
    required this.grid,
    required this.connectGaps,
    required this.highlightIndex,
  });

  final List<RangeBucket> buckets;
  final Color color;
  final Color grid;
  final bool connectGaps;
  final int? highlightIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final measured = <int, double>{
      for (var i = 0; i < buckets.length; i++)
        if (buckets[i].value > 0) i: buckets[i].value,
    };
    if (measured.isEmpty) return;

    var min = measured.values.first;
    var max = measured.values.first;
    for (final value in measured.values) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    if ((max - min).abs() < 0.0001) {
      min -= 1;
      max += 1;
    } else {
      final pad = (max - min) * 0.12;
      min -= pad;
      max += pad;
    }

    const left = 4.0;
    const right = 4.0;
    const top = 8.0;
    const bottom = 8.0;
    double nx(int i) => buckets.length <= 1
        ? size.width / 2
        : left + i / (buckets.length - 1) * (size.width - left - right);
    double ny(double value) =>
        top + (1 - (value - min) / (max - min)) * (size.height - top - bottom);

    final segments = <List<Offset>>[];
    if (connectGaps) {
      final points = <Offset>[
        for (var i = 0; i < buckets.length; i++)
          if (buckets[i].value > 0) Offset(nx(i), ny(buckets[i].value)),
      ];
      if (points.isNotEmpty) segments.add(points);
    } else {
      var current = <Offset>[];
      for (var i = 0; i < buckets.length; i++) {
        final value = buckets[i].value;
        if (value > 0) {
          current.add(Offset(nx(i), ny(value)));
        } else if (current.isNotEmpty) {
          segments.add(current);
          current = <Offset>[];
        }
      }
      if (current.isNotEmpty) segments.add(current);
    }

    for (final segment in segments) {
      if (segment.length >= 2) {
        final path = Path()..moveTo(segment.first.dx, segment.first.dy);
        for (var i = 1; i < segment.length; i++) {
          path.lineTo(segment[i].dx, segment[i].dy);
        }
        final fill = Path.from(path)
          ..lineTo(segment.last.dx, size.height - bottom)
          ..lineTo(segment.first.dx, size.height - bottom)
          ..close();
        canvas.drawPath(
          fill,
          Paint()
            ..shader =
                LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    color.withValues(alpha: 0.22),
                    color.withValues(alpha: 0),
                  ],
                ).createShader(
                  Rect.fromLTRB(0, top, size.width, size.height - bottom),
                ),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      } else if (segment.length == 1) {
        // 稀疏指标（体温/体重/血压…）经常整月只有一两个孤立记录。
        // 单点连不成线段，只画网格会让人以为完全没有数据。
        final p = segment.first;
        canvas.drawCircle(
          p,
          2.6,
          Paint()..color = color.withValues(alpha: 0.55),
        );
        canvas.drawCircle(p, 1.6, Paint()..color = color);
      }
    }
    if (highlightIndex != null &&
        highlightIndex! >= 0 &&
        highlightIndex! < buckets.length) {
      final x = nx(highlightIndex!);
      canvas.drawLine(
        Offset(x, top),
        Offset(x, size.height - bottom),
        Paint()
          ..color = color.withValues(alpha: 0.45)
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RangeLinePainter old) =>
      old.buckets != buckets ||
      old.color != color ||
      old.grid != grid ||
      old.connectGaps != connectGaps ||
      old.highlightIndex != highlightIndex;
}

class VNavBar extends StatelessWidget {
  const VNavBar({super.key, required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const _icons = [
    Icons.insights_rounded,
    Icons.directions_run_rounded,
    Icons.format_list_bulleted_rounded,
    Icons.settings_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final l10n = AppLocalizations.of(context);
    final labels = [
      l10n.navFitness,
      l10n.navSport,
      l10n.navRecords,
      l10n.navSettings,
    ];
    return Container(
      padding: EdgeInsets.only(
        top: 6,
        bottom: MediaQuery.of(context).padding.bottom + 6,
      ),
      decoration: BoxDecoration(
        color: v.isDark ? const Color(0xF20C1322) : const Color(0xF7FAFBFE),
        border: Border(
          top: BorderSide(
            color: v.isDark
                ? Colors.white.withValues(alpha: 0.07)
                : const Color(0x0F101318),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (var i = 0; i < _icons.length; i++)
            GestureDetector(
              onTap: () => onTap(i),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 74,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 46,
                      height: 27,
                      decoration: BoxDecoration(
                        color: i == index
                            ? (v.isDark
                                  ? const Color(0xFF1B2C50)
                                  : const Color(0xFFDCE7FE))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        _icons[i],
                        size: 20,
                        color: i == index
                            ? (v.isDark ? const Color(0xFF7D9BFF) : v.blue)
                            : (v.isDark
                                  ? const Color(0xFF9AA8BF)
                                  : const Color(0xFF5E6678)),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      labels[i],
                      style: VText.label.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: i == index
                            ? (v.isDark ? const Color(0xFF7D9BFF) : v.blue)
                            : (v.isDark
                                  ? const Color(0xFF7C8BA3)
                                  : const Color(0xFF7C8598)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class VPrimaryButton extends StatelessWidget {
  const VPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.expand = true,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final child = Material(
      color: v.blue,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: VText.h3.copyWith(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!expand) return child;
    return SizedBox(width: double.infinity, child: child);
  }
}

class VGhostButton extends StatelessWidget {
  const VGhostButton({super.key, required this.label, this.icon, this.onTap});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Material(
      color: v.isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: v.ink),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: VText.h3.copyWith(
                  color: v.ink,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VAvatar extends StatelessWidget {
  const VAvatar({
    super.key,
    this.initial = 'W',
    this.size = 38,
    this.blue = false,
    this.onTap,
  });

  final String initial;
  final double size;
  final bool blue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: blue ? v.blue : v.surface,
          shape: BoxShape.circle,
          border: Border.all(color: v.line),
        ),
        child: Text(
          initial.toUpperCase(),
          style: VText.h3.copyWith(
            color: blue ? Colors.white : v.ink,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class ReadinessRing extends StatelessWidget {
  const ReadinessRing({
    super.key,
    required this.score,
    required this.level,
    required this.trend,
    this.size = 206,
    this.onTap,
    this.hasData = true,
  });

  final int score;
  final String level;
  final int trend;
  final double size;
  final VoidCallback? onTap;
  final bool hasData;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final s = size / 206;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _RingPainter(score: score, v: v),
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: 6 * s),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: hasData ? '$score' : '--',
                            style: VText.num.copyWith(
                              fontSize: 41 * s,
                              color: v.ink,
                            ),
                          ),
                          if (hasData)
                            TextSpan(
                              text: '分',
                              style: VText.h3.copyWith(
                                fontSize: 19 * s,
                                color: v.ink,
                                letterSpacing: -0.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(height: 6 * s),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 26 * s),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          hasData
                              ? '$level · 较前一日 ${trend >= 0 ? '+' : ''}$trend'
                              : level,
                          maxLines: 1,
                          style: VText.label.copyWith(
                            fontSize: 10.5 * s,
                            fontWeight: FontWeight.w700,
                            color: v.ink2.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (hasData)
              Positioned(
                right: 0,
                bottom: 18 * s,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 9 * s,
                    vertical: 4 * s,
                  ),
                  decoration: BoxDecoration(
                    color: v.isDark
                        ? const Color(0xFF1D2C55)
                        : const Color(0xFFDCE4FE),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${trend >= 0 ? '+' : ''}$trend',
                    style: VText.label.copyWith(
                      fontSize: 10.5 * s,
                      fontWeight: FontWeight.w800,
                      color: v.isDark
                          ? const Color(0xFFA9BBFF)
                          : const Color(0xFF2B4ED0),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.score, required this.v});

  final int score;
  final VColors v;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 9;
    final stroke = 17.0 * size.width / 208;

    final hole = Paint()
      ..color = v.isDark ? const Color(0xFF0F1728) : const Color(0xFFF8F9FE);
    canvas.drawCircle(center, radius - stroke / 2 - 1, hole);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = v.blueTrack;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = v.blue;
    final sweep = 2 * math.pi * score.clamp(0, 100) / 100;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      arc,
    );

    _paintArcLabel(
      canvas,
      center,
      radius - stroke - 15 * size.width / 206,
      v,
      size.width / 206,
    );
  }

  void _paintArcLabel(
    Canvas canvas,
    Offset center,
    double radius,
    VColors v,
    double s,
  ) {
    final text = tr('准备度');
    final style = VText.label.copyWith(
      fontSize: 10.5 * s,
      fontWeight: FontWeight.w800,
      color: v.ink2,
      letterSpacing: 0,
    );
    final painters = [
      for (final ch in text.split(''))
        TextPainter(
          text: TextSpan(text: ch, style: style),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    final gap = 1.6 * s;
    final total =
        painters.fold<double>(0, (a, p) => a + p.width) +
        gap * (painters.length - 1);
    var cursor = -math.pi / 2 - (total / radius) / 2;
    for (final painter in painters) {
      final mid = cursor + (painter.width / 2) / radius;
      final pos = center + Offset(math.cos(mid), math.sin(mid)) * radius;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(mid + math.pi / 2);
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();
      cursor += (painter.width + gap) / radius;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.score != score || old.v != v;
}

class SparkBars extends StatelessWidget {
  const SparkBars({
    super.key,
    required this.values,
    this.height = 54,
    this.highlightLast = true,
    this.color,
    this.trackColor,
  });

  final List<double> values;
  final double height;
  final bool highlightLast;
  final Color? color;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    if (values.isEmpty) return SizedBox(height: height);
    final maxValue = values.reduce(math.max);
    final minValue = values.reduce(math.min);
    final span = math.max(1.0, maxValue - minValue);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++) ...[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    height: 8 + (height - 18) * ((values[i] - minValue) / span),
                    decoration: BoxDecoration(
                      color: (highlightLast && i == values.length - 1)
                          ? (color ?? v.blue)
                          : (trackColor ?? v.blueTrack),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ],
              ),
            ),
            if (i != values.length - 1) const SizedBox(width: 7),
          ],
        ],
      ),
    );
  }
}

class HeartRateCurve extends StatefulWidget {
  const HeartRateCurve({
    super.key,
    required this.points,
    this.height = 86,
    this.color,
    this.unit = '',
    this.valueFormat,
    this.xLabel,
  });

  final List<Offset> points;
  final double height;
  final Color? color;
  final String unit;
  final String Function(double value)? valueFormat;
  final String Function(double x)? xLabel;

  @override
  State<HeartRateCurve> createState() => _HeartRateCurveState();
}

class _HeartRateCurveState extends State<HeartRateCurve> {
  int? _index;

  void _select(double dx, double width) {
    final points = widget.points;
    if (points.isEmpty) return;
    var minX = points.first.dx;
    var maxX = points.first.dx;
    for (final p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
    }
    final xValue =
        minX + dx / math.max(1.0, width) * math.max(1.0, maxX - minX);
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < points.length; i++) {
      final distance = (points[i].dx - xValue).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (_index != best) setState(() => _index = best);
  }

  double _fractionOf(double x) {
    final points = widget.points;
    if (points.length < 2) return 0.5;
    var minX = points.first.dx;
    var maxX = points.first.dx;
    for (final p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
    }
    return ((x - minX) / math.max(1.0, maxX - minX)).clamp(0.0, 1.0);
  }

  List<String> _tipLines(Offset point) {
    final label = widget.xLabel?.call(point.dx) ?? _chartDateLabel(point.dx);
    final value =
        '${(widget.valueFormat ?? _defaultChartValue)(point.dy)}'
        '${widget.unit.isEmpty ? '' : ' ${widget.unit}'}';
    return [label, value];
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final points = widget.points;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final index = _index != null && _index! < points.length
              ? _index
              : null;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _select(d.localPosition.dx, width),
                  onHorizontalDragStart: (d) =>
                      _select(d.localPosition.dx, width),
                  onHorizontalDragUpdate: (d) =>
                      _select(d.localPosition.dx, width),
                  child: CustomPaint(
                    painter: _LinePainter(
                      points: points,
                      color: widget.color ?? v.heartInk,
                      grid: v.line,
                      highlightFraction: index == null
                          ? null
                          : _fractionOf(points[index].dx),
                    ),
                  ),
                ),
              ),
              if (index != null && index < points.length)
                _ChartTipOverlay(
                  x: _fractionOf(points[index].dx) * width,
                  width: width,
                  lines: _tipLines(points[index]),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 多序列折线图：所有序列共用同一 y 轴刻度，x 按全局范围归一。
/// 用于血压（收缩压+舒张压）这类需要同图对比的双指标场景。
class MultiLineChart extends StatefulWidget {
  const MultiLineChart({
    super.key,
    required this.series,
    this.height = 110,
    this.unit = '',
    this.xLabel,
  });

  final List<MultiLineSeries> series;
  final double height;
  final String unit;
  final String Function(double x)? xLabel;

  @override
  State<MultiLineChart> createState() => _MultiLineChartState();
}

class _MultiLineChartState extends State<MultiLineChart> {
  double? _x;

  void _select(double dx, double width) {
    final all = [for (final s in widget.series) ...s.points];
    if (all.isEmpty) return;
    var minX = all.first.dx;
    var maxX = all.first.dx;
    for (final p in all) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
    }
    final xValue =
        minX + dx / math.max(1.0, width) * math.max(1.0, maxX - minX);
    var best = all.first.dx;
    var bestDistance = double.infinity;
    for (final p in all) {
      final distance = (p.dx - xValue).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = p.dx;
      }
    }
    if (_x != best) setState(() => _x = best);
  }

  List<String> _tipLines(double x) {
    final lines = [widget.xLabel?.call(x) ?? _chartDateLabel(x)];
    for (final s in widget.series) {
      if (s.points.isEmpty) continue;
      var nearest = s.points.first;
      for (final p in s.points) {
        if ((p.dx - x).abs() < (nearest.dx - x).abs()) nearest = p;
      }
      final name = s.name.isEmpty ? '' : '${s.name} ';
      final unit = widget.unit.isEmpty ? '' : ' ${widget.unit}';
      lines.add('$name${_defaultChartValue(nearest.dy)}$unit');
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final x = _x;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _select(d.localPosition.dx, width),
                  onHorizontalDragStart: (d) =>
                      _select(d.localPosition.dx, width),
                  onHorizontalDragUpdate: (d) =>
                      _select(d.localPosition.dx, width),
                  child: CustomPaint(
                    painter: _MultiLinePainter(
                      series: widget.series,
                      grid: v.line,
                      highlightX: x,
                    ),
                  ),
                ),
              ),
              if (x != null)
                _ChartTipOverlay(
                  x: _fractionOf(x) * width,
                  width: width,
                  lines: _tipLines(x),
                ),
            ],
          );
        },
      ),
    );
  }

  double _fractionOf(double x) {
    final all = [for (final s in widget.series) ...s.points];
    if (all.length < 2) return 0.5;
    var minX = all.first.dx;
    var maxX = all.first.dx;
    for (final p in all) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
    }
    return ((x - minX) / math.max(1.0, maxX - minX)).clamp(0.0, 1.0);
  }
}

class MultiLineSeries {
  const MultiLineSeries({
    required this.points,
    required this.color,
    this.name = '',
  });

  final List<Offset> points;
  final Color color;
  final String name;
}

class _MultiLinePainter extends CustomPainter {
  _MultiLinePainter({
    required this.series,
    required this.grid,
    required this.highlightX,
  });

  final List<MultiLineSeries> series;
  final Color grid;
  final double? highlightX;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final all = [for (final s in series) ...s.points];
    if (all.length < 2) return;
    var minX = all.first.dx,
        maxX = all.first.dx,
        minY = all.first.dy,
        maxY = all.first.dy;
    for (final p in all) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    double nx(double dx) =>
        (dx - minX) / math.max(1.0, maxX - minX) * (size.width - 8) + 4;
    double ny(double dy) =>
        6 + (1 - (dy - minY) / math.max(1.0, maxY - minY)) * (size.height - 12);

    final paths = <(Path, Color)>[];
    for (final s in series) {
      if (s.points.isEmpty) continue;
      final pts = [for (final p in s.points) Offset(nx(p.dx), ny(p.dy))];
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 0; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      paths.add((path, s.color));
    }
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    for (final (path, color) in paths) {
      final fill = Path.from(path)
        ..lineTo(size.width - 4, size.height)
        ..lineTo(4, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }
    for (final (path, color) in paths) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (highlightX != null) {
      final x = nx(highlightX!);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = grid.withValues(alpha: 0.9)
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MultiLinePainter old) =>
      old.series != series || old.highlightX != highlightX;
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.color,
    required this.grid,
    required this.highlightFraction,
  });

  final List<Offset> points;
  final Color color;
  final Color grid;
  final double? highlightFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    if (points.length < 2) return;
    final normalized = _normalize(points, size);
    final path = _smoothPath(normalized);
    final fillPath = Path.from(path)
      ..lineTo(normalized.last.dx, size.height)
      ..lineTo(normalized.first.dx, size.height)
      ..close();
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (highlightFraction != null) {
      final x = highlightFraction! * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = color.withValues(alpha: 0.45)
          ..strokeWidth = 1.2,
      );
    }
  }

  List<Offset> _normalize(List<Offset> input, Size size) {
    var minX = input.first.dx, maxX = input.first.dx;
    var minY = input.first.dy, maxY = input.first.dy;
    for (final p in input) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    final spanX = math.max(1.0, maxX - minX);
    final spanY = math.max(1.0, maxY - minY);
    return [
      for (final p in input)
        Offset(
          (p.dx - minX) / spanX * size.width,
          6 + (1 - (p.dy - minY) / spanY) * (size.height - 12),
        ),
    ];
  }

  Path _smoothPath(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i];
      final p1 = pts[i + 1];
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.points != points ||
      old.color != color ||
      old.highlightFraction != highlightFraction;
}

class RouteMap extends StatelessWidget {
  const RouteMap({
    super.key,
    required this.points,
    this.height = 206,
    this.radius = 28,
    this.showChip = true,
  });

  /// (lat, lon) 序列。
  final List<Offset> points;
  final double height;
  final double radius;
  final bool showChip;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MapPainter(points: points, v: v),
              ),
            ),
            if (showChip)
              Positioned(
                left: 10,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: v.glass,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '轨迹 · 本地记录',
                    style: VText.label.copyWith(
                      fontSize: 9.5,
                      color: v.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({required this.points, required this.v});

  final List<Offset> points;
  final VColors v;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = v.mapThumb);
    final road = Paint()
      ..color = v.mapRoad
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    final thin = Paint()
      ..color = v.mapRoad.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final roads = [
      Offset(-20, size.height * 0.22),
      Offset(size.width * 0.28, size.height * 0.8),
      Offset(size.width * 0.62, size.height * 0.12),
      Offset(size.width * 0.4, size.height * 0.5),
      Offset(size.width * 0.85, size.height * 0.6),
    ];
    canvas.drawLine(
      Offset(-10, size.height * 0.2),
      Offset(size.width + 10, size.height * 0.55),
      road,
    );
    canvas.drawLine(
      Offset(size.width * 0.3, -10),
      Offset(size.width * 0.55, size.height + 10),
      road,
    );
    canvas.drawLine(
      Offset(-10, size.height * 0.78),
      Offset(size.width * 0.7, size.height * 0.35),
      thin,
    );
    canvas.drawLine(
      Offset(size.width * 0.82, -10),
      Offset(size.width * 0.55, size.height + 10),
      thin,
    );
    for (final r in roads) {
      canvas.drawCircle(r, 2, Paint()..color = v.mapRoad);
    }

    if (points.length < 2) return;
    var minLat = points.first.dx, maxLat = points.first.dx;
    var minLon = points.first.dy, maxLon = points.first.dy;
    for (final p in points) {
      minLat = math.min(minLat, p.dx);
      maxLat = math.max(maxLat, p.dx);
      minLon = math.min(minLon, p.dy);
      maxLon = math.max(maxLon, p.dy);
    }
    final pad = 26.0;
    final spanLat = math.max(1e-6, maxLat - minLat);
    final spanLon = math.max(1e-6, maxLon - minLon);
    final scale = math.min(
      (size.width - pad * 2) / spanLon,
      (size.height - pad * 2) / spanLat,
    );
    Offset project(Offset p) => Offset(
      size.width / 2 + (p.dy - (minLon + maxLon) / 2) * scale,
      size.height / 2 - (p.dx - (minLat + maxLat) / 2) * scale,
    );

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = project(points[i]);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = v.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final start = project(points.first);
    final end = project(points.last);
    canvas.drawCircle(start, 7, Paint()..color = Colors.white);
    canvas.drawCircle(start, 4, Paint()..color = v.blue);
    canvas.drawCircle(end, 7, Paint()..color = v.blue);
    canvas.drawCircle(end, 4, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.points != points || old.v != v;
}

class MiniZoneBar extends StatelessWidget {
  const MiniZoneBar({
    super.key,
    required this.label,
    required this.value,
    required this.fraction,
    this.trailing,
    this.color,
  });

  final String label;
  final String value;
  final double fraction;
  final String? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              label,
              style: VText.label.copyWith(
                fontSize: 10.5,
                color: v.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              value,
              style: VText.meta.copyWith(
                fontSize: 11,
                color: v.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction.clamp(0, 1),
                minHeight: 6,
                backgroundColor: v.barTrack,
                valueColor: AlwaysStoppedAnimation(color ?? v.blue),
              ),
            ),
          ),
          if (trailing != null)
            SizedBox(
              width: 38,
              child: Text(
                trailing!,
                textAlign: TextAlign.right,
                style: VText.label.copyWith(
                  fontSize: 10.5,
                  color: v.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 力量训练重量选择：按 5 kg 步进拖拽，0 表示自重。
class VWeightSlider extends StatelessWidget {
  const VWeightSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 300,
    this.step = 5,
    this.label = '重量',
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double step;
  final String label;

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final clamped = value.clamp(min, max).toDouble();
    final divisions = ((max - min) / step).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: VText.h3.copyWith(color: v.ink)),
            const Spacer(),
            Text(
              clamped <= 0 ? '自重' : '${_fmt(clamped)} kg',
              style: VText.value.copyWith(
                fontSize: 22,
                color: v.blueInk,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        Row(
          children: [
            _WeightStepButton(
              icon: Icons.remove_rounded,
              onTap: () => onChanged((clamped - step).clamp(min, max)),
            ),
            Expanded(
              child: Slider(
                value: clamped,
                min: min,
                max: max,
                divisions: divisions,
                label: clamped <= 0 ? '自重' : '${_fmt(clamped)} kg',
                activeColor: v.blue,
                onChanged: onChanged,
              ),
            ),
            _WeightStepButton(
              icon: Icons.add_rounded,
              onTap: () => onChanged((clamped + step).clamp(min, max)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 44),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('自重', style: VText.label.copyWith(color: v.muted)),
              Text(
                '${max.toInt()} kg',
                style: VText.label.copyWith(color: v.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeightStepButton extends StatelessWidget {
  const _WeightStepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: v.isDark ? Colors.white.withValues(alpha: 0.07) : v.grey,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 19, color: v.ink2),
      ),
    );
  }
}
