import 'package:flutter/material.dart' hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/l10n/app_localizations.dart';
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:vitaloop/l10n/ui_translations.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/components.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await UiTranslations.instance.load();
  });

  tearDown(() {
    UiTranslations.instance.setLocale('zh');
  });

  test('translates exact labels and dynamic templates', () {
    UiTranslations.instance.setLocale('en');

    expect(UiTranslations.instance.loadedLocales.length, 8);
    expect(
      UiTranslations.instance.lastLoadDuration,
      lessThan(const Duration(seconds: 2)),
    );
    expect(UiTranslations.instance.patternCountForLocale('en'), greaterThan(0));
    expect(
      UiTranslations.instance.hasPatternForLocale('en', '[[0]] 分钟前'),
      isTrue,
    );
    expect(tr('心率'), 'Heart rate');
    expect(tr('全马'), 'Marathon');
    expect(tr('3 分钟前'), '3 minutes ago');
    expect(tr('abc · 定时拉取'), 'abc · Scheduled fetch');
  });

  test('translates the same dynamic text into another locale', () {
    UiTranslations.instance.setLocale('fr');

    expect(tr('全马'), 'Marathon');
    expect(tr('定时拉取'), isNot('定时拉取'));
    expect(tr('3 分钟前'), contains('3'));
  });

  test('every supported legacy locale handles labels and placeholders', () {
    for (final code in ['en', 'ja', 'ru', 'fr', 'vi', 'th', 'es', 'de']) {
      UiTranslations.instance.setLocale(code);
      expect(tr('心率'), isNot('心率'), reason: code);
      expect(tr('均心'), isNot('均心'), reason: code);
      expect(tr('3 分钟前'), isNot('3 分钟前'), reason: code);
    }
  });

  test('runtime health descriptions never fall back to Chinese', () {
    const source = '心率变异性（RMSSD），越高说明自主神经恢复越好。';
    UiTranslations.instance.setLocale('en');
    expect(tr(source), contains('Heart rate variability'));

    UiTranslations.instance.setLocale('fr');
    final fallback = tr(source);
    expect(fallback, contains('Heart rate variability'));
    expect(RegExp(r'[\u3400-\u9fff]').hasMatch(fallback), isFalse);
  });

  testWidgets('localized Text translates plain and rich spans', (tester) async {
    UiTranslations.instance.setLocale('en');

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
        home: const Scaffold(
          body: Column(
            children: [
              Text('删除'),
              Text.rich(TextSpan(text: '心率')),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Heart rate'), findsOneWidget);
  });

  testWidgets('retained widgets follow MaterialApp locale changes', (
    tester,
  ) async {
    UiTranslations.instance.setLocale('zh');

    Widget app(Locale locale) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
        body: VTile(icon: Icons.bedtime_rounded, label: '今日睡眠', value: '7h42'),
      ),
    );

    await tester.pumpWidget(app(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Sleep Today'), findsOneWidget);
    expect(find.text('今日睡眠'), findsNothing);

    await tester.pumpWidget(app(const Locale('fr')));
    await tester.pumpAndSettle();
    expect(find.text("Dormir Aujourd'hui"), findsOneWidget);
    expect(find.text('Sleep Today'), findsNothing);
  });
}
