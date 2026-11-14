import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/state/app_state.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/components.dart';
import 'package:vitaloop/ui/screens/home_screen.dart';
import 'package:vitaloop/ui/screens/heart_rhythm_screen.dart';

void main() {
  testWidgets('进入编辑态后三列小卡保持原尺寸', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _demoState();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HomeScreen(state: state, onOpenTab: (_) {}),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('心率'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    Map<String, Size> miniSizes() => {
      for (final element in find.byType(VMini).evaluate())
        (element.widget as VMini).label:
            (element.renderObject as RenderBox).size,
    };

    final before = miniSizes();
    expect(before, isNotEmpty);

    await tester.longPress(find.text('心率'));
    await tester.pumpAndSettle();

    final after = miniSizes();
    for (final label in before.keys) {
      expect(after[label], isNotNull, reason: '$label 进入编辑态后仍应存在');
      expect(after[label]!.width, moreOrLessEquals(before[label]!.width));
      expect(after[label]!.height, moreOrLessEquals(before[label]!.height));
    }

    final heart = tester.getRect(
      find.ancestor(of: find.text('心率'), matching: find.byType(VMini)),
    );
    final spo2 = tester.getRect(
      find.ancestor(of: find.text('血氧'), matching: find.byType(VMini)),
    );
    final gap = Offset((heart.right + spo2.left) / 2, heart.center.dy);
    await tester.tapAt(gap);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(gap);
    await tester.pumpAndSettle();

    expect(find.textContaining('双击空白退出'), findsNothing);
  });

  testWidgets('编辑态双击列表外空白可退出', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HomeScreen(state: _demoState(), onOpenTab: (_) {}),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('编辑首页卡片'));
    await tester.pumpAndSettle();
    expect(find.textContaining('双击空白退出'), findsOneWidget);

    await tester.tapAt(const Offset(5, 300));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('双击空白退出'), findsNothing);
  });

  testWidgets('运动时长卡片显示锻炼环/运动记录分钟数，不用滞后的活动分钟', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // activeMinutes 是旧 App 日报遗留列，手表实时同步不会写它；
    // 卡片必须读 exerciseMinutes，否则当天跑完 25 分钟首页仍然显示 0。
    final state = _demoState(exerciseMinutes: 25);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HomeScreen(state: state, onOpenTab: (_) {}),
        ),
      ),
    );
    await tester.pump();

    final tile = find.ancestor(
      of: find.text('运动时长'),
      matching: find.byType(VTile),
    );
    await tester.scrollUntilVisible(
      tile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: tile, matching: find.text('25 分钟')),
      findsOneWidget,
    );
  });

  testWidgets('下拉刷新会重新加载首页全部数据', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _demoState(state: _RefreshTestState());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HomeScreen(state: state, onOpenTab: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
    await tester.fling(find.byType(ListView), const Offset(0, 420), 1000);
    await tester.pump();
    await tester.pumpAndSettle();

    expect((state as _RefreshTestState).refreshCalls, 1);
  });

  testWidgets('心电卡片显示最近一次 ECG 结果', (tester) async {
    tester.view.physicalSize = const Size(411, 905);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _demoState()
      ..ecg = [
        EcgEntry(
          startMs: DateTime(2026, 11, 7, 8, 30).millisecondsSinceEpoch,
          endMs: DateTime(2026, 11, 7, 8, 31).millisecondsSinceEpoch,
          avgHeartRate: 63,
          arrhythmiaType: 1,
          sampleCount: 15000,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: HomeScreen(state: state, onOpenTab: (_) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final card = find.ancestor(
      of: find.text('心电'),
      matching: find.byType(VMini),
    );
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.byType(VMini), findsWidgets);
    expect(find.text('心电'), findsOneWidget);
    expect(find.textContaining('63'), findsWidgets);
    expect(find.textContaining('· 30 秒'), findsOneWidget);

    await tester.tap(find.text('心电'));
    await tester.pumpAndSettle();
    expect(find.byType(HeartRhythmScreen), findsOneWidget);
  });
}

class _RefreshTestState extends AppState {
  int refreshCalls = 0;

  @override
  Future<void> refresh() async {
    refreshCalls++;
    notifyListeners();
  }
}

AppState _demoState({AppState? state, int exerciseMinutes = 0}) {
  final day = DateTime(2026, 11, 7);
  return (state ?? AppState())
    ..home = HomeSummary(
      dateEpochDay: day.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay,
      readiness: const ReadinessScore(
        total: 60,
        level: '一般',
        advice: '',
        trend: 0,
        hrvScore: 60,
        sleepScore: 60,
        rhrScore: 60,
        tempScore: 60,
        stressScore: 60,
        recoveryScore: 60,
        recoveryMinutes: 0,
        computedAtMs: 0,
      ),
      readinessHistory: const [],
      steps: 5967,
      stepsGoal: 8000,
      activeCalories: 172,
      caloriesGoal: 500,
      distanceM: 0,
      activeMinutes: 0,
      exerciseMinutes: exerciseMinutes,
      exerciseGoalMin: 30,
      activeHours: 5,
      activeHoursGoal: 9,
      runningIndex: 48,
      restingHr: 54,
      heartRate: 70,
      heartRateSeries: const [],
      hrvMs: 55,
      sleepMinutes: 314,
      spo2: 99,
      stress: 37,
      weightKg: 69.4,
      bmi: 24,
      respiration: 13,
      weeklyLoad: 195,
      weeklyWorkouts: 3,
      deviceConnected: true,
    )
    ..profile = const Profile(
      nickname: '测试跑者',
      gender: 'male',
      heightCm: 175,
      weightKg: 69.4,
      birthDate: '1995-01-01',
      email: '',
    );
}
