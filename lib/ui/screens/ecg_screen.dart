import 'package:flutter/material.dart' hide Text;

import '../../l10n/localized_text.dart';
import '../../src/rust/api/types.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../components.dart';
import '../nav.dart';

/// 手表 ECG 记录列表。波形数据已入库，详情页先保持只读摘要，
/// 避免在还没有确认采样率/标定时把波形画错。
class EcgScreen extends StatelessWidget {
  const EcgScreen({super.key, required this.records});

  final List<EcgEntry> records;

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
              title: '心电',
              icon: Icons.monitor_heart_outlined,
              iconColor: v.heartInk,
            ),
            if (records.isEmpty)
              const VEmpty(
                title: '暂无心电记录',
                subtitle: '在手表上完成一次 ECG 测量并同步后，结果会显示在这里。',
                icon: Icons.monitor_heart_outlined,
              )
            else ...[
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      records.first.arrhythmiaType == null
                          ? '--'
                          : arrhythmiaLabel(records.first.arrhythmiaType!),
                      style: VText.h1.copyWith(fontSize: 30),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '最近测量 '
                      '${relativeDay(DateTime.fromMillisecondsSinceEpoch(records.first.startMs))} '
                      '${clock(DateTime.fromMillisecondsSinceEpoch(records.first.startMs))}',
                      style: VText.label.copyWith(color: v.muted),
                    ),
                  ],
                ),
              ),
              const VSectionHead(title: '全部记录'),
              VCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Column(
                  children: [
                    for (final record in records)
                      VRowItem(
                        icon: Icons.monitor_heart_outlined,
                        iconBackground: v.tintHeart,
                        iconColor: v.heartInk,
                        title: record.arrhythmiaType == null
                            ? '未知'
                            : arrhythmiaLabel(record.arrhythmiaType!),
                        subtitle:
                            '${relativeDay(DateTime.fromMillisecondsSinceEpoch(record.startMs))} '
                            '${clock(DateTime.fromMillisecondsSinceEpoch(record.startMs))}',
                        value: record.avgHeartRate == null
                            ? '--'
                            : '${record.avgHeartRate}',
                        valueSub:
                            'bpm · ${(record.sampleCount / 500).round()} 秒',
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
