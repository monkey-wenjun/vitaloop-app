import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/coordinate.dart';

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
  });

  final String name;
  final String address;
  final double lat;
  final double lon;
}

/// 目的地搜索。默认用 Photon（国内网络可达），结果统一转成 GCJ-02。
class PlaceSearch {
  PlaceSearch._();

  static const defaultBase = 'https://photon.komoot.io';
  static const _timeout = Duration(seconds: 12);
  static String base = defaultBase;

  static Future<List<PlaceResult>> search(String query) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final uri = Uri.parse('$base/api')
        .replace(queryParameters: {'q': text, 'limit': '6'});
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'Vitaloop/0.1');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      return parse(body);
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  static List<PlaceResult> parse(String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (json is Map && json['features'] is List) {
      return _parsePhoton(json['features'] as List);
    }
    if (json is! List) return const [];
    return _parseNominatim(json);
  }

  static List<PlaceResult> _parsePhoton(List features) {
    final out = <PlaceResult>[];
    final seen = <String>{};
    for (final raw in features) {
      if (raw is! Map) continue;
      final properties = raw['properties'];
      final geometry = raw['geometry'];
      if (properties is! Map || geometry is! Map) continue;
      final coordinates = geometry['coordinates'];
      if (coordinates is! List || coordinates.length < 2) continue;
      final lon = double.tryParse('${coordinates[0]}');
      final lat = double.tryParse('${coordinates[1]}');
      if (lat == null || lon == null) continue;
      final (gcjLat, gcjLon) = Coordinate.wgs84ToGcj02(lat, lon);
      final name = '${properties['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final key = '$gcjLat,$gcjLon';
      if (!seen.add(key)) continue;
      final address =
          [
                properties['street'],
                properties['district'],
                properties['city'],
                properties['county'],
                properties['state'],
                properties['country'],
              ]
              .whereType<Object>()
              .map((v) => '$v'.trim())
              .where((v) => v.isNotEmpty)
              .toSet()
              .join(' · ');
      out.add(
        PlaceResult(
          name: name,
          address: address == name ? '' : address,
          lat: gcjLat,
          lon: gcjLon,
        ),
      );
      if (out.length >= 6) break;
    }
    return out;
  }

  static List<PlaceResult> _parseNominatim(List json) {
    final out = <PlaceResult>[];
    final seen = <String>{};
    for (final raw in json) {
      if (raw is! Map) continue;
      final lat = double.tryParse('${raw['lat']}');
      final lon = double.tryParse('${raw['lon']}');
      if (lat == null || lon == null) continue;
      final (gcjLat, gcjLon) = Coordinate.wgs84ToGcj02(lat, lon);
      final name = '${raw['name'] ?? raw['display_name'] ?? ''}'.trim();
      final address = '${raw['display_name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final key = '$gcjLat,$gcjLon';
      if (!seen.add(key)) continue;
      out.add(
        PlaceResult(
          name: name,
          address: address == name ? '' : address,
          lat: gcjLat,
          lon: gcjLon,
        ),
      );
      if (out.length >= 6) break;
    }
    return out;
  }
}
