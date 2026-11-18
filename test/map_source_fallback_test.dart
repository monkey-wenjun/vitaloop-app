import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;
import 'package:vitaloop/data/map_display.dart';
import 'package:vitaloop/data/map_source_health.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/pmtiles_route_map.dart';

class _FallbackHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout = Duration.zero;
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FallbackHttpClientRequest(url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FallbackHttpClientRequest implements HttpClientRequest {
  _FallbackHttpClientRequest(this.url);

  final Uri url;
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;

  @override
  Future<HttpClientResponse> close() async =>
      _FallbackHttpClientResponse(url.host == 'tiles.openfreemap.org');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FallbackHttpClientResponse implements HttpClientResponse {
  _FallbackHttpClientResponse(this.ok);

  final bool ok;
  @override
  int get statusCode => ok ? 200 : 404;

  @override
  Future<E> drain<E>([E? futureValue]) async => futureValue as E;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    MapDisplaySettings.instance
      ..provider = MapBaseProvider.pmtiles
      ..pmtilesUrl = 'https://private.example';
    MapSourceHealth.instance.resetForTest();
  });

  tearDown(() {
    MapDisplaySettings.instance
      ..provider = MapBaseProvider.pmtiles
      ..pmtilesUrl = '';
  });

  testWidgets('配置地址不通时切到官方样式', (tester) async {
    maplibre.MapLibreMap? map;
    await HttpOverrides.runZoned(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Theme(
              data: ThemeData(extensions: const <ThemeExtension>[VColors.light]),
              child: Scaffold(
                body: SizedBox(
                  width: 320,
                  height: 240,
                  child: PmtilesRouteMap(points: const []),
                ),
              ),
            ),
          ),
        );
      },
      createHttpClient: (securityContext) => _FallbackHttpClient(),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
    map = tester.widget<maplibre.MapLibreMap>(
      find.byType(maplibre.MapLibreMap),
    );
    expect(map.styleString, contains('"openmaptiles"'));
    expect(map.styleString, contains('https://tiles.openfreemap.org'));
  });
}
