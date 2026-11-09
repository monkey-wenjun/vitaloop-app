import 'dart:convert';

class OfficialSplitEntry {
  const OfficialSplitEntry({
    required this.index,
    required this.distanceM,
    required this.paceSecondsPerKm,
    required this.partial,
  });

  final int index;
  final double distanceM;
  final double paceSecondsPerKm;
  final bool partial;

  double get seconds => paceSecondsPerKm * distanceM / 1000;
}

/// 解析手表 0x0c 官方分段。只取 type=0（整公里），type=1 是英里段。
/// correction 的单位是 0.1 米，4900 => 490 米。
List<OfficialSplitEntry> parseOfficialSplitEntries(String? json) {
  if (json == null || json.isEmpty) return const [];
  dynamic decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];

  final entries = <OfficialSplitEntry>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    if ((item['type'] as num?)?.toInt() != 0) continue;
    final pace = (item['pace'] as num?)?.toDouble() ?? 0;
    if (pace < 30 || pace > 3600) continue;
    final correction = (item['corr'] as num?)?.toDouble();
    final partial = correction != null && correction > 0;
    final distanceM = partial ? correction * 0.1 : 1000.0;
    if (distanceM < 10) continue;
    entries.add(
      OfficialSplitEntry(
        index: (item['i'] as num?)?.toInt() ?? entries.length,
        distanceM: distanceM,
        paceSecondsPerKm: pace,
        partial: partial,
      ),
    );
  }
  entries.sort((a, b) => a.index.compareTo(b.index));
  return entries;
}
