import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 把手表同步来的健康指标可选地推送到自托管的 blogapi 兼容服务。
///
/// 该功能默认关闭：必须同时通过 --dart-define 提供 BLOGAPI_URL 和
/// BLOGAPI_TOKEN 才会启用。服务端按 (user_id, timestamp) 去重，重复推送安全。
class BlogHrApi {
  static const base = String.fromEnvironment(
    'BLOGAPI_URL',
    defaultValue: '',
  );

  /// sk_ 开头的 API Token（需 write 权限），通过 --dart-define=BLOGAPI_TOKEN= 注入。
  static const token = String.fromEnvironment('BLOGAPI_TOKEN');

  static bool get enabled => token.isNotEmpty && base.isNotEmpty;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// 按时间顺序逐条 POST [path]，body 为各点 payload，返回最后一个成功写入的
  /// 时间戳；任何失败立即停，未推完的点靠调用方游标在下轮同步补回。
  static Future<int?> pushMetric(
    String path,
    List<({int tsMs, Map<String, dynamic> body})> points, {
    int limit = 500,
  }) async {
    if (!enabled || points.isEmpty) return null;
    final batch = points.length > limit
        ? points.sublist(points.length - limit)
        : points;
    int? lastOk;
    for (final p in batch) {
      try {
        final req = await _client.postUrl(Uri.parse('$base/api/v1/$path'));
        req.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
          ..contentType = ContentType.json;
        req.write(jsonEncode(p.body));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        await resp.drain<void>();
        if (resp.statusCode >= 400) break;
        lastOk = p.tsMs;
      } catch (_) {
        // 网络/服务异常：数据已在本机入库，下轮同步按游标补推
        break;
      }
    }
    return lastOk;
  }
}
