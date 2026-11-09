import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/l10n/app_localizations.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/sleep/sleep_data.dart';
import 'package:vitaloop/ui/screens/sleep/sleep_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sleep dashboard renders on a narrow phone in English', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 1800);
    addTearDown(tester.view.reset);
    final data = NightSleepData.fromDetail(_detail());

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SleepNightHero(data: data),
              const SizedBox(height: 12),
              SleepNightChartCard(data: data),
              const SizedBox(height: 12),
              SleepCompositionCard(data: data),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Night rhythm'), findsOneWidget);
    expect(find.text('Stage composition'), findsOneWidget);
    expect(find.textContaining('7 h 42 min'), findsOneWidget);
    expect(
      find.text('Tap or drag across the chart to inspect a stage.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sleep dashboard fits 320px in longer translated locales', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 1900);
    addTearDown(tester.view.reset);
    final data = NightSleepData.fromDetail(_detail());

    for (final code in ['ru', 'th', 'ja']) {
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                SleepNightHero(data: data),
                const SizedBox(height: 12),
                SleepNightChartCard(data: data),
                const SizedBox(height: 12),
                SleepCompositionCard(data: data),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'locale $code');
    }
  });
}

SleepDetail _detail() {
  final start = DateTime(2026, 11, 7, 23).millisecondsSinceEpoch;
  final end = start + const Duration(hours: 8, minutes: 7).inMilliseconds;
  return SleepDetail(
    summary: SleepSummary(
      dateEpochDay: 20800,
      totalMinutes: 462,
      deepMinutes: 132,
      lightMinutes: 212,
      remMinutes: 118,
      awakeMinutes: 25,
      napMinutes: 0,
      startMs: start,
      endMs: end,
      efficiency: 95,
      score: 88,
    ),
    stages: [
      SleepStage(
        startMs: start,
        endMs: start + const Duration(minutes: 8).inMilliseconds,
        stage: 'awake',
      ),
      SleepStage(
        startMs: start + const Duration(minutes: 8).inMilliseconds,
        endMs: start + const Duration(minutes: 38).inMilliseconds,
        stage: 'light',
      ),
      SleepStage(
        startMs: start + const Duration(minutes: 38).inMilliseconds,
        endMs: start + const Duration(minutes: 79).inMilliseconds,
        stage: 'deep',
      ),
      SleepStage(
        startMs: start + const Duration(minutes: 79).inMilliseconds,
        endMs: end - const Duration(minutes: 30).inMilliseconds,
        stage: 'rem',
      ),
      SleepStage(
        startMs: end - const Duration(minutes: 30).inMilliseconds,
        endMs: end - const Duration(minutes: 24).inMilliseconds,
        stage: 'awake',
      ),
      SleepStage(
        startMs: end - const Duration(minutes: 24).inMilliseconds,
        endMs: end,
        stage: 'light',
      ),
    ],
    chartStartMs: start,
    chartEndMs: end,
    breathing: 14.2,
    sleepHrvAvg: 62,
    sleepHrvMinBaseline: 52,
    sleepHrvMaxBaseline: 68,
    sleepHrvDayToBaseline: 4,
  );
}
