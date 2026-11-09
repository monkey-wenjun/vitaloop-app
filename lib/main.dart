import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'state/app_state.dart';
import 'data/ble_bridge.dart';
import 'data/map_display.dart';
import 'data/watch_bridge.dart';
import 'l10n/app_localizations.dart';
import 'l10n/ui_translations.dart';
import 'theme/tokens.dart';
import 'ui/components.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/records_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/screens/sport_screen.dart';
import 'ui/screens/workout_live_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UiTranslations.instance.load();
  final state = AppState();
  runApp(VitaloopApp(state: state));
  unawaited(MapDisplaySettings.instance.load());
  unawaited(state.bootstrap().then((_) => state.checkForUpdate()));
}

class VitaloopApp extends StatelessWidget {
  const VitaloopApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        debugShowCheckedModeBanner: false,
        locale: state.localeOverride,
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: (locales, supported) {
          for (final systemLocale in locales ?? const <Locale>[]) {
            for (final supportedLocale in supported) {
              if (systemLocale.languageCode == supportedLocale.languageCode) {
                return supportedLocale;
              }
            }
          }
          return const Locale('en');
        },
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: state.themeMode,
        builder: (context, child) {
          UiTranslations.instance.setLocale(
            Localizations.localeOf(context).languageCode,
          );
          return child ?? const SizedBox.shrink();
        },
        home: state.loading
            ? SplashScreen(state: state)
            : state.error != null
            ? ErrorScreen(message: state.error!, onRetry: state.bootstrap)
            : Shell(state: state),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: v.blue,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.all_inclusive_rounded,
                color: Colors.white,
                size: 42,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'VITALOOP',
              style: VText.label.copyWith(
                letterSpacing: 3.2,
                color: v.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: v.blue),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorScreen extends StatelessWidget {
  const ErrorScreen({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: v.bg,
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline_rounded, size: 42, color: v.danger),
            const SizedBox(height: 12),
            Text(l10n.startupFailed, style: VText.h2.copyWith(color: v.ink)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: VText.label.copyWith(color: v.muted, height: 1.5),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              VPrimaryButton(label: l10n.retry, onTap: onRetry),
            ],
          ],
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});

  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _legacyTimer;
  int _lastLiveToken = 0;
  bool _liveOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WatchBridge.instance.attach(widget.state);
    unawaited(WatchBridge.instance.ensureEphemeris());
    BleBridge.instance.attach(widget.state);
    WatchBridge.instance.workoutAutoOpen.addListener(_onWorkoutAutoOpen);
    WatchBridge.instance.autoConnect();
    widget.state.refreshFromLegacyIfNewer();
    _legacyTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => widget.state.refreshFromLegacyIfNewer(),
    );
  }

  @override
  void dispose() {
    _legacyTimer?.cancel();
    WatchBridge.instance.workoutAutoOpen.removeListener(_onWorkoutAutoOpen);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onWorkoutAutoOpen() {
    final token = WatchBridge.instance.workoutAutoOpen.value;
    if (token <= 0 || token == _lastLiveToken || _liveOpen || !mounted) return;
    _lastLiveToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _liveOpen) return;
      _liveOpen = true;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WorkoutLiveScreen(state: widget.state),
        ),
      );
      _liveOpen = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.state.refreshFromLegacyIfNewer();
      unawaited(WatchBridge.instance.refreshSleepNow());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.state.noteLocalChanges());
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep every retained tab in sync when the app or system locale changes.
    Localizations.localeOf(context);
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: widget.state,
          builder: (context, _) => IndexedStack(
            index: _index,
            children: [
              HomeScreen(
                state: widget.state,
                onOpenTab: (i) => setState(() => _index = i),
              ),
              SportScreen(
                state: widget.state,
                onOpenTab: (i) => setState(() => _index = i),
              ),
              RecordsScreen(state: widget.state),
              SettingsScreen(state: widget.state),
            ],
          ),
        ),
      ),
      bottomNavigationBar: VNavBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}
