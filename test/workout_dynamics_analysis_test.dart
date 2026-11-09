import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/ui/workout_dynamics_analysis.dart';

void main() {
  test('vertical oscillation grades cover boundaries', () {
    expect(assessVerticalOscillation(8).grade, DynamicsGrade.excellent);
    expect(assessVerticalOscillation(8.1).grade, DynamicsGrade.good);
    expect(assessVerticalOscillation(10).grade, DynamicsGrade.good);
    expect(assessVerticalOscillation(10.1).grade, DynamicsGrade.average);
    expect(assessVerticalOscillation(12.1).grade, DynamicsGrade.high);
  });

  test('ground contact balance uses distance from half', () {
    expect(assessGroundContactBalance(49).grade, DynamicsGrade.excellent);
    expect(assessGroundContactBalance(51.1).grade, DynamicsGrade.good);
    expect(assessGroundContactBalance(47.5).grade, DynamicsGrade.average);
    expect(assessGroundContactBalance(46.9).grade, DynamicsGrade.high);
  });
}
