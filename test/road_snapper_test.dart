import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/road_snapper.dart';

void main() {
  test('OSRM GeoJSON 折线转成 GCJ-02 路线点', () {
    final points = RoadSnapper.parseOsrmGeometry(
      '{"code":"Ok","routes":[{"geometry":{"coordinates":'
      '[[121.4737,31.2304],[121.4740,31.2306],[121.4744,31.2309]]}}]}',
    );
    expect(points, isNotNull);
    expect(points!.length, 3);
    expect(points.first.lat, closeTo(31.22846, 0.00002));
    expect(points.first.lon, closeTo(121.47822, 0.00002));
  });

  test('OSRM 错误响应返回空', () {
    expect(RoadSnapper.parseOsrmGeometry('{"code":"NoRoute"}'), isNull);
    expect(RoadSnapper.parseOsrmGeometry('not json'), isNull);
  });

  test('OSRM 多条路线全部保留距离与耗时', () {
    final routes = RoadSnapper.parseOsrmRoutes(
      '{"code":"Ok","routes":['
      '{"distance":1200.5,"duration":360.2,"geometry":{"coordinates":'
      '[[121.4737,31.2304],[121.4744,31.2309]]}},'
      '{"distance":1450.0,"duration":390.0,"geometry":{"coordinates":'
      '[[121.4737,31.2304],[121.4750,31.2310],[121.4754,31.2314]]}}'
      ']}',
    );
    expect(routes, hasLength(2));
    expect(routes.first.distanceM, 1200.5);
    expect(routes.first.durationS, 360.2);
    expect(routes.first.points, hasLength(2));
    expect(routes.last.points, hasLength(3));
  });
}
