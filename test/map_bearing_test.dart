import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/util/map_bearing.dart';

void main() {
  group('travelBearingDegrees', () {
    test('正北前进 → 0°', () {
      final bearing = travelBearingDegrees(const [
        Offset(31.0000, 121.0000),
        Offset(31.0010, 121.0000),
      ]);
      expect(bearing, isNotNull);
      final value = bearing!;
      expect(value < 1 || value > 359, isTrue);
    });

    test('正东前进 → 90°', () {
      final bearing = travelBearingDegrees(const [
        Offset(31.0000, 121.0000),
        Offset(31.0000, 121.0010),
      ]);
      expect(bearing, closeTo(90, 1));
    });

    test('正南前进 → 180°', () {
      final bearing = travelBearingDegrees(const [
        Offset(31.0010, 121.0000),
        Offset(31.0000, 121.0000),
      ]);
      expect(bearing, closeTo(180, 1));
    });

    test('正西前进 → 270°', () {
      final bearing = travelBearingDegrees(const [
        Offset(31.0000, 121.0010),
        Offset(31.0000, 121.0000),
      ]);
      expect(bearing, closeTo(270, 1));
    });

    test('点太少或原地打转时返回 null，调用方保持上一次方向', () {
      expect(travelBearingDegrees(const [Offset(31.0, 121.0)]), isNull);
      expect(
        travelBearingDegrees(const [
          Offset(31.0, 121.0),
          Offset(31.0, 121.0000001),
        ]),
        isNull,
      );
    });
  });

  group('blendBearingDegrees', () {
    test('每次最多追 40°，不会瞬移', () {
      final next = blendBearingDegrees(0, 180);
      final delta = (next - 0 + 540) % 360 - 180;
      expect(delta.abs(), closeTo(24, 0.001));
    });

    test('跨 0° 时走最短方向', () {
      final next = blendBearingDegrees(359, 1);
      expect(next < 2 || next > 358, isTrue);
    });

    test('小抖动直接忽略', () {
      expect(blendBearingDegrees(90, 91.5), 90);
    });
  });
}
