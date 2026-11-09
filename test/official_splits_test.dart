import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/official_splits.dart';

void main() {
  test('官方分段只取整公里并保留尾段', () {
    const json = '''
    [
      {"i":0,"d":1,"type":0,"pace":250,"point":249,"corr":null},
      {"i":1,"d":1,"type":1,"pace":352,"point":351,"corr":null},
      {"i":2,"d":2,"type":0,"pace":260,"point":516,"corr":null},
      {"i":3,"d":2,"type":0,"pace":270,"point":667,"corr":4900}
    ]
    ''';

    final splits = parseOfficialSplitEntries(json);

    expect(splits.length, 3);
    expect(splits[0].distanceM, 1000);
    expect(splits[0].paceSecondsPerKm, 250);
    expect(splits[0].partial, isFalse);
    expect(splits[1].distanceM, 1000);
    expect(splits[2].distanceM, 490);
    expect(splits[2].paceSecondsPerKm, 270);
    expect(splits[2].partial, isTrue);
    expect(splits[2].seconds, closeTo(132.3, 0.001));
  });

  test('坏 JSON、空值和非法配速都安全跳过', () {
    expect(parseOfficialSplitEntries(null), isEmpty);
    expect(parseOfficialSplitEntries('not json'), isEmpty);
    expect(
      parseOfficialSplitEntries(
        '[{"i":0,"type":0,"pace":10,"corr":null},{"i":1,"type":0,"pace":400,"corr":0}]',
      ).length,
      1,
    );
  });
}
