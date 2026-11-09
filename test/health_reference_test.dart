import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/util/health_reference.dart';

void main() {
  group('血压分级', () {
    test('正常范围', () {
      expect(bpLevel(119, 79), BpLevel.normal);
      expect(bpLevel(90, 60), BpLevel.normal);
    });

    test('偏高：收缩压 120-129 且舒张压 <80', () {
      expect(bpLevel(120, 79), BpLevel.elevated);
      expect(bpLevel(129, 79), BpLevel.elevated);
    });

    test('高血压1级：130-139 或舒张压 80-89', () {
      expect(bpLevel(130, 79), BpLevel.stage1);
      expect(bpLevel(139, 89), BpLevel.stage1);
      expect(bpLevel(119, 80), BpLevel.stage1);
      expect(bpLevel(120, 85), BpLevel.stage1);
    });

    test('高血压2级：任一指标达到 140/90', () {
      expect(bpLevel(140, 79), BpLevel.stage2);
      expect(bpLevel(120, 90), BpLevel.stage2);
      expect(bpLevel(160, 100), BpLevel.stage2);
    });

    test('参考表文案与分级一一对应', () {
      expect(bpReferenceRows.map((e) => e.level), [
        BpLevel.normal,
        BpLevel.elevated,
        BpLevel.stage1,
        BpLevel.stage2,
      ]);
      expect(bpLevelLabel(BpLevel.stage1), '高血压1级');
    });
  });

  group('BMI 分级', () {
    test('按旧版 18.5 / 24 / 28 边界分级', () {
      expect(bmiLevel(18.4), BmiLevel.underweight);
      expect(bmiLevel(18.5), BmiLevel.normal);
      expect(bmiLevel(23.9), BmiLevel.normal);
      expect(bmiLevel(24.0), BmiLevel.overweight);
      expect(bmiLevel(27.9), BmiLevel.overweight);
      expect(bmiLevel(28.0), BmiLevel.obese);
    });

    test('参考表文案与分级一一对应', () {
      expect(bmiReferenceRows.map((e) => e.level), [
        BmiLevel.underweight,
        BmiLevel.normal,
        BmiLevel.overweight,
        BmiLevel.obese,
      ]);
      expect(bmiReferenceRows.last.range, '≥ 28.0');
      expect(bmiLevelLabel(BmiLevel.overweight), '偏胖');
    });
  });

  group('血糖分级', () {
    test('空腹、餐前、睡前都按空腹标准', () {
      for (final type in ['fasting', 'before_meal', 'bedtime']) {
        expect(glucoseStandardFor(type), GlucoseStandard.fasting);
        expect(glucoseLevel(3.8, type), GlucoseLevel.low);
        expect(glucoseLevel(3.9, type), GlucoseLevel.normal);
        expect(glucoseLevel(6.0, type), GlucoseLevel.normal);
        expect(glucoseLevel(6.1, type), GlucoseLevel.impaired);
        expect(glucoseLevel(6.9, type), GlucoseLevel.impaired);
        expect(glucoseLevel(7.0, type), GlucoseLevel.diabetes);
      }
    });

    test('餐后按餐后2小时标准', () {
      expect(glucoseStandardFor('after_meal'), GlucoseStandard.afterMeal);
      expect(glucoseLevel(7.7, 'after_meal'), GlucoseLevel.normal);
      expect(glucoseLevel(7.8, 'after_meal'), GlucoseLevel.impaired);
      expect(glucoseLevel(11.0, 'after_meal'), GlucoseLevel.impaired);
      expect(glucoseLevel(11.1, 'after_meal'), GlucoseLevel.diabetes);
    });

    test('随机血糖不强行分级', () {
      expect(glucoseStandardFor('random'), isNull);
      expect(glucoseLevel(6.5, 'random'), isNull);
      expect(glucoseLevelLabel(6.5, 'random'), isNull);
    });

    test('分级文案区分空腹受损和糖耐量减低', () {
      expect(glucoseLevelLabel(6.5, 'fasting'), '空腹血糖受损');
      expect(glucoseLevelLabel(8.0, 'after_meal'), '糖耐量减低');
      expect(glucoseLevelLabel(3.0, 'fasting'), '偏低');
      expect(glucoseLevelLabel(12.0, 'after_meal'), '糖尿病');
    });
  });
}
