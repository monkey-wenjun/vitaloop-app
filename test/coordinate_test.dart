import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/util/coordinate.dart';

void main() {
  test('WGS-84 转 GCJ-02 使用高德坐标偏移', () {
    final (lat, lon) = Coordinate.wgs84ToGcj02(31.2304, 121.4737);
    expect(lat, closeTo(31.2284577, 0.000001));
    expect(lon, closeTo(121.4782231, 0.000001));
  });

  test('GCJ-02 转回 WGS-84 误差小于一米', () {
    final (lat, lon) = Coordinate.gcj02ToWgs84(31.2284577, 121.4782231);
    expect(lat, closeTo(31.2304, 0.00001));
    expect(lon, closeTo(121.4737, 0.00001));
  });

  test('只有新版手机 GPS 手动记录需要转成 GCJ-02', () {
    expect(workoutTrackIsWgs84('watch'), isFalse);
    expect(workoutTrackIsWgs84('legacy'), isFalse);
    expect(workoutTrackIsWgs84('manual'), isTrue);
  });
}
