import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../src/rust/api/types.dart';
import '../util/coordinate.dart';

class RoadSnapResult {
  const RoadSnapResult({
    required this.points,
    required this.straightLegs,
    required this.source,
    this.options = const [],
  });

  final List<GeoPoint> points;
  final int straightLegs;
  final String source;
  final List<RoadRouteOption> options;

  bool get snapped => straightLegs == 0 && source.isNotEmpty;
}

class RoadRouteOption {
  const RoadRouteOption({
    required this.points,
    required this.distanceM,
    required this.durationS,
  });

  final List<GeoPoint> points;
  final double distanceM;
  final double durationS;
}

/// 把点选的途经点吸附到真实道路。
///
/// 默认使用 OSRM 公共路线服务；单段失败只退回
/// 那一段直线，整条路线不会因为一个点没路网而丢掉。
class RoadSnapper {
  RoadSnapper._();

  static const defaultBase = 'https://routing.openstreetmap.de';
  static const _timeout = Duration(seconds: 12);
  static const _legTimeout = Duration(seconds: 8);

  static Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final addresses = await InternetAddress.lookup(uri.host);
    addresses.sort((a, b) {
      final a4 = a.type == InternetAddressType.IPv4 ? 0 : 1;
      final b4 = b.type == InternetAddressType.IPv4 ? 0 : 1;
      return a4.compareTo(b4);
    });
    Object? lastError;
    for (final address in addresses) {
      try {
        final raw = await Socket.connect(
          address,
          uri.port,
          timeout: const Duration(seconds: 5),
        );
        final socket = uri.scheme == 'https'
            ? await SecureSocket.secure(raw, host: uri.host).timeout(_timeout)
            : raw;
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      } catch (e) {
        lastError = e;
      }
    }
    throw SocketException('无法连接 ${uri.host}: ${lastError ?? "没有可用地址"}');
  }

  static Future<HttpClient> _newClient() async {
    return HttpClient()
      ..connectionTimeout = _legTimeout
      ..connectionFactory = _connect;
  }

  static Future<RoadSnapResult> snap(
    List<GeoPoint> waypoints, {
    required bool ride,
    int alternativeCount = 0,
  }) async {
    if (waypoints.length < 2) {
      return RoadSnapResult(points: waypoints, straightLegs: 0, source: '');
    }
    final profile = ride ? 'bike' : 'foot';
    final requestAlternatives = alternativeCount > 0 && waypoints.length == 2;
    final out = <GeoPoint>[waypoints.first];
    List<RoadRouteOption> options = const [];
    var straightLegs = 0;
    for (var i = 1; i < waypoints.length; i++) {
      final legs = await _snapLegRoutes(
        waypoints[i - 1],
        waypoints[i],
        profile,
        alternatives: requestAlternatives ? alternativeCount : 0,
      );
      if (legs == null || legs.isEmpty) {
        straightLegs++;
        out.add(waypoints[i]);
      } else {
        if (requestAlternatives) options = legs;
        final leg = legs.first.points;
        if (leg.isNotEmpty && _same(out.last, leg.first)) {
          out.addAll(leg.skip(1));
        } else {
          out.addAll(leg);
        }
      }
    }
    return RoadSnapResult(
      points: out,
      straightLegs: straightLegs,
      source: defaultBase,
      options: options,
    );
  }

  static Future<List<RoadRouteOption>?> _snapLegRoutes(
    GeoPoint from,
    GeoPoint to,
    String profile, {
    required int alternatives,
  }) async {
    final (fromLat, fromLon) = Coordinate.gcj02ToWgs84(from.lat, from.lon);
    final (toLat, toLon) = Coordinate.gcj02ToWgs84(to.lat, to.lon);
    final alternativesQuery = alternatives > 0
        ? '&alternatives=$alternatives'
        : '';
    final uri = Uri.parse(
      '$defaultBase/routed-$profile/route/v1/driving/'
      '${fromLon.toStringAsFixed(6)},${fromLat.toStringAsFixed(6)};'
      '${toLon.toStringAsFixed(6)},${toLat.toStringAsFixed(6)}'
      '?overview=full&geometries=geojson&steps=false$alternativesQuery',
    );
    final client = await _newClient();
    try {
      final request = await client.getUrl(uri).timeout(_legTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'Vitaloop/0.1');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_legTimeout);
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_legTimeout);
      final routes = parseOsrmRoutes(body);
      return routes.isEmpty ? null : routes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static bool _same(GeoPoint a, GeoPoint b) =>
      (a.lat - b.lat).abs() < 1e-9 && (a.lon - b.lon).abs() < 1e-9;

  /// OSRM 返回 WGS-84，界面和保存路线统一转成 GCJ-02。
  static List<GeoPoint>? parseOsrmGeometry(String body) {
    final routes = parseOsrmRoutes(body);
    return routes.isEmpty ? null : routes.first.points;
  }

  static List<RoadRouteOption> parseOsrmRoutes(String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (json is! Map || json['code'] != 'Ok') return const [];
    final rawRoutes = json['routes'];
    if (rawRoutes is! List || rawRoutes.isEmpty) return const [];
    final routes = <RoadRouteOption>[];
    for (final route in rawRoutes) {
      if (route is! Map) continue;
      final geometry = route['geometry'];
      if (geometry is! Map) continue;
      final coords = geometry['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final points = <GeoPoint>[];
      for (final raw in coords) {
        if (raw is! List || raw.length < 2) continue;
        final lon = (raw[0] as num).toDouble();
        final lat = (raw[1] as num).toDouble();
        final (gcjLat, gcjLon) = Coordinate.wgs84ToGcj02(lat, lon);
        points.add(GeoPoint(lat: gcjLat, lon: gcjLon));
      }
      if (points.length < 2) continue;
      routes.add(
        RoadRouteOption(
          points: points,
          distanceM: (route['distance'] as num?)?.toDouble() ?? 0,
          durationS: (route['duration'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    return routes;
  }
}
