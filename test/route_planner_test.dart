import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/l10n/app_localizations.dart';
import 'package:vitaloop/data/map_display.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/amap_route_map.dart';
import 'package:vitaloop/ui/screens/sport_tools_screen.dart';

void main() {
  setUp(() {
    MapDisplaySettings.instance.provider = MapBaseProvider.amap;
  });

  tearDown(() {
    MapDisplaySettings.instance.provider = MapBaseProvider.pmtiles;
  });

  testWidgets('route planner is map-first and hides snapping controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(Brightness.light),
        home: const RoutePlannerScreen(
          route: SavedRoute(
            id: 'test',
            name: '测试路线',
            distanceM: 1200,
            createdMs: 0,
            points: [
              GeoPoint(lat: 31.23, lon: 121.47),
              GeoPoint(lat: 31.24, lon: 121.48),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(AmapRouteMap), findsOneWidget);
    expect(tester.getSize(find.byType(AmapRouteMap)).height, greaterThan(300));
    expect(find.text('路网类型'), findsNothing);
    expect(find.text('途经点'), findsNothing);
    expect(find.text('贴道路'), findsNothing);
    final save = tester.getCenter(find.text('保存路线'));
    final watch = tester.getCenter(find.text('保存并发手表'));
    expect((save.dy - watch.dy).abs(), lessThan(0.1));
    expect(save.dx, lessThan(watch.dx));
    expect(tester.takeException(), isNull);
  });
}
