import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/place_search.dart';

void main() {
  test('目的地搜索结果转成 GCJ-02', () {
    final results = PlaceSearch.parse(
      '[{"name":"外滩","display_name":"外滩, 上海市","lat":"31.2353356","lon":"121.4876320"}]',
    );
    expect(results, hasLength(1));
    expect(results.first.name, '外滩');
    expect(results.first.lat, closeTo(31.233356, 0.00002));
    expect(results.first.lon, closeTo(121.492108, 0.00002));
  });

  test('Photon FeatureCollection 能解析名称、地址和坐标', () {
    final results = PlaceSearch.parse(
      '{"type":"FeatureCollection","features":[{"type":"Feature",'
      '"properties":{"name":"外滩","street":"中山东一路","city":"上海市",'
      '"state":"上海市","country":"中国"},'
      '"geometry":{"type":"Point","coordinates":[121.4876320,31.2353356]}}]}',
    );
    expect(results, hasLength(1));
    expect(results.first.name, '外滩');
    expect(results.first.address, contains('上海市'));
    expect(results.first.lat, closeTo(31.233356, 0.00002));
    expect(results.first.lon, closeTo(121.492108, 0.00002));
  });

  test('非法搜索结果安全跳过', () {
    expect(PlaceSearch.parse('not json'), isEmpty);
    expect(
      PlaceSearch.parse('[{"name":"x","lat":"bad","lon":"121"}]'),
      isEmpty,
    );
  });
}
