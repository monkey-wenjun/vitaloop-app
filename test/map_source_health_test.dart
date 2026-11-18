import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/map_source_health.dart';

class _ProbeHttpClient implements HttpClient {
  _ProbeHttpClient(this.status);

  final int status;

  @override
  Duration? connectionTimeout = Duration.zero;
  @override
  bool autoUncompress = true;

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ProbeHttpClientRequest(status);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeHttpClientRequest implements HttpClientRequest {
  _ProbeHttpClientRequest(this.status);

  final int status;
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;

  @override
  Future<HttpClientResponse> close() async => _ProbeHttpClientResponse(status);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeHttpClientResponse implements HttpClientResponse {
  _ProbeHttpClientResponse(this.status);

  final int status;

  @override
  int get statusCode => status;

  @override
  Future<E> drain<E>([E? futureValue]) async => futureValue as E;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    MapSourceHealth.instance.resetForTest();
  });

  test('空地址不通过', () async {
    expect(await MapSourceHealth.instance.isReachable(' '), isFalse);
  });

  test('XYZ 瓦片请求 200 判定可达', () async {
    HttpOverrides.runZoned(
      () async {
        expect(
          await MapSourceHealth.instance.isReachable('https://tiles.example'),
          isTrue,
        );
      },
      createHttpClient: (context) => _ProbeHttpClient(200),
    );
  });

  test('XYZ 瓦片请求失败判定不可达', () async {
    await HttpOverrides.runZoned(
      () async {
        expect(
          await MapSourceHealth.instance.isReachable('https://tiles.example'),
          isFalse,
        );
      },
      createHttpClient: (context) => _ProbeHttpClient(404),
    );
  });

  test('相同地址复用探测结果', () async {
    await HttpOverrides.runZoned(
      () async {
        await MapSourceHealth.instance.isReachable('https://tiles.example');
        expect(MapSourceHealth.instance.probeCountForTest, 1);
      },
      createHttpClient: (context) => _ProbeHttpClient(200),
    );
  });
}
