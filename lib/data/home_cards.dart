import 'dart:convert';

enum HomeCardSize { half, mini, full }

class HomeCardSpec {
  const HomeCardSpec(this.id, this.title, this.size);

  final String id;
  final String title;
  final HomeCardSize size;
}

/// 首页卡片顺序与显隐。只存 id，具体数值每次从 AppState 重新取。
class HomeCardLayout {
  const HomeCardLayout({required this.order, required this.hidden});

  final List<String> order;
  final Set<String> hidden;

  static const specs = <HomeCardSpec>[
    HomeCardSpec('advice', '今日训练建议', HomeCardSize.full),
    HomeCardSpec('readiness', '身心准备度', HomeCardSize.half),
    HomeCardSpec('steps', '步数', HomeCardSize.half),
    HomeCardSpec('workout', '今日运动', HomeCardSize.half),
    HomeCardSpec('sleep', '今日睡眠', HomeCardSize.half),
    HomeCardSpec('calories', '消耗卡数', HomeCardSize.half),
    HomeCardSpec('minutes', '运动时长', HomeCardSize.half),
    HomeCardSpec('weekly_workouts', '本周运动', HomeCardSize.half),
    HomeCardSpec('weekly_load', '训练负荷', HomeCardSize.half),
    HomeCardSpec('active_hours', '活动小时数', HomeCardSize.half),
    HomeCardSpec('running_index', '跑力指数', HomeCardSize.half),
    HomeCardSpec('heart_rate', '心率', HomeCardSize.mini),
    HomeCardSpec('spo2', '血氧', HomeCardSize.mini),
    HomeCardSpec('respiration', '呼吸率', HomeCardSize.mini),
    HomeCardSpec('stress', '压力', HomeCardSize.mini),
    HomeCardSpec('temp', '腕温/体温', HomeCardSize.mini),
    HomeCardSpec('weight', '体重', HomeCardSize.mini),
    HomeCardSpec('bp', '血压', HomeCardSize.mini),
    HomeCardSpec('glucose', '血糖', HomeCardSize.mini),
    HomeCardSpec('hrv', 'HRV', HomeCardSize.mini),
    HomeCardSpec('emotion', '情绪', HomeCardSize.mini),
    HomeCardSpec('vo2max', '最大摄氧量', HomeCardSize.mini),
    HomeCardSpec('arrhythmia', '心律', HomeCardSize.mini),
    HomeCardSpec('ecg', '心电', HomeCardSize.mini),
  ];

  static final List<String> defaultOrder = [for (final spec in specs) spec.id];

  static final Set<String> knownIds = {for (final spec in specs) spec.id};

  static HomeCardSpec specOf(String id) =>
      specs.firstWhere((spec) => spec.id == id, orElse: () => specs.first);

  static HomeCardLayout get defaults =>
      HomeCardLayout(order: [...defaultOrder], hidden: <String>{});

  static HomeCardLayout parse(String raw) {
    if (raw.trim().isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      final map = decoded is Map ? decoded : <String, dynamic>{};
      final rawOrder = map['order'];
      final rawHidden = map['hidden'];
      final order = <String>[];
      if (rawOrder is List) {
        for (final id in rawOrder) {
          if (id is String && knownIds.contains(id) && !order.contains(id)) {
            order.add(id);
          }
        }
      }
      // 新版本加的卡片自动补到末尾，不丢；首次使用也走这里得到默认顺序。
      for (final id in defaultOrder) {
        if (!order.contains(id)) order.add(id);
      }
      final hidden = <String>{
        if (rawHidden is List)
          for (final id in rawHidden)
            if (id is String && knownIds.contains(id)) id,
      };
      return HomeCardLayout(order: order, hidden: hidden);
    } catch (_) {
      return defaults;
    }
  }

  String encode() =>
      jsonEncode({'order': order, 'hidden': hidden.toList()..sort()});

  HomeCardLayout copyWith({List<String>? order, Set<String>? hidden}) =>
      HomeCardLayout(order: order ?? this.order, hidden: hidden ?? this.hidden);

  /// 把 [from] 插到 [to] 前面；[to] 为空表示放到末尾。
  static List<String> move(List<String> order, String from, String? to) {
    if (from == to) return [...order];
    final next = [...order];
    if (!next.remove(from)) return next;
    final index = to == null ? next.length : next.indexOf(to);
    next.insert(index < 0 ? next.length : index, from);
    return next;
  }
}
