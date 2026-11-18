import 'dart:async';
import 'dart:io';

const officialMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

class MapSourceHealth {
  MapSourceHealth._();

  static final instance = MapSourceHealth._();

  final _results = <String, Future<bool>>{};
  int _probeCount = 0;

  Future<bool> isReachable(String sourceUrl) {
    final normalized = sourceUrl.trim();
    if (normalized.isEmpty) return Future.value(false);
    return _results.putIfAbsent(normalized, () => _probe(normalized));
  }

  Future<bool> _probe(String sourceUrl) {
    _probeCount += 1;
    if (sourceUrl.contains('.pmtiles')) {
      return _request(sourceUrl, 'HEAD');
    }
    return _request('$sourceUrl/tiles/0/0/0.mvt', 'GET');
  }

  Future<bool> _request(String url, String method) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void resetForTest() {
    _results.clear();
    _probeCount = 0;
  }

  int get probeCountForTest => _probeCount;
}
