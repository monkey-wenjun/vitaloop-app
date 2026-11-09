import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/util/km_markers.dart';

void main() {
  test('公里标记按距离插值，不按点数', () {
    final markers = computeKmGeoMarkers(const [
      Offset(30, 120),
      Offset(30, 120.03),
    ]);
    expect(markers.map((marker) => marker.km), [1, 2]);
    expect(markers.first.point.dy, closeTo(120.0104, 0.0005));
    expect(markers.last.point.dy, closeTo(120.0208, 0.0005));
  });

  test('五公里间隔只标 5、10', () {
    final markers = computeKmGeoMarkers(const [
      Offset(30, 120),
      Offset(30, 120.12),
    ], 5000);
    expect(markers.map((marker) => marker.km), [5, 10]);
  });
}
