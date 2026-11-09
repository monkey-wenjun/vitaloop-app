import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/l10n/app_localizations.dart';
import 'package:vitaloop/l10n/language_options.dart';
import 'package:vitaloop/state/app_state.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/settings_screen.dart';

void main() {
  test('all declared language options have generated localizations', () {
    final generated = {
      for (final locale in AppLocalizations.supportedLocales)
        locale.languageCode,
    };
    final configured = {
      for (final option in appLanguageOptions)
        if (option.locale != null) option.locale!.languageCode,
    };
    expect(configured, generated);
  });

  testWidgets('core strings load for every supported locale', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context);
              return Text(l10n.sleepDetails);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(l10n.sleepDetails, isNotEmpty);
      expect(l10n.navSettings, isNotEmpty);
      expect(l10n.language, isNotEmpty);
      expect(find.text(l10n.sleepDetails), findsOneWidget);
    }
  });

  test('state maps automatic and explicit language settings to locales', () {
    final state = AppState();
    expect(state.localeOverride, isNull);
    state.language = 'ja';
    expect(state.localeOverride, const Locale('ja'));
    state.language = 'system';
    expect(state.localeOverride, isNull);
  });

  testWidgets('settings exposes the manual language picker', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1800);
    addTearDown(tester.view.reset);
    final state = AppState();

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
        home: Scaffold(body: SettingsScreen(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    final languageRow = find.text('Language');
    await tester.ensureVisible(languageRow);
    await tester.tap(languageRow);
    await tester.pumpAndSettle();

    expect(find.text('Choose language'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);
  });
}
