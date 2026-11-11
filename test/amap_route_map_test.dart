import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/map_display.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/amap_route_map.dart';
import 'package:vitaloop/data/amap_tile_cache.dart';

/// 2026-11-06：装机 4 分钟后 /data/anr 里出现 5 次「主线程一直 RUNNING」的轨迹。
/// 地图是同一个提交里唯一新增的循环代码（瓦片循环 + 相机拟合 + 折线重绘），
/// 这些用例只盯一件事：**任何输入下都必须收敛** —— 不许抛、不许每帧重新 setState。
Widget _host(Widget child) => MaterialApp(
  home: Theme(
    data: ThemeData(extensions: const <ThemeExtension>[VColors.light]),
    child: Scaffold(body: SizedBox(width: 360, height: 260, child: child)),
  ),
);

Widget _darkHost(Widget child) => MaterialApp(
  home: Theme(
    data: ThemeData(extensions: const <ThemeExtension>[VColors.dark]),
    child: Scaffold(body: SizedBox(width: 360, height: 260, child: child)),
  ),
);

int _tileImages(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .where((w) => w.image is AmapTileImageProvider)
    .length;

Set<int> _tileZooms(WidgetTester tester) => {
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    if (image.image case final AmapTileImageProvider provider)
      int.tryParse(Uri.tryParse(provider.url)?.queryParameters['z'] ?? '') ??
          -1,
};

Set<(int, int, int)> _tiles(WidgetTester tester) => {
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    if (image.image case final AmapTileImageProvider provider)
      if (Uri.tryParse(provider.url)?.queryParameters case final query?)
        (
          int.tryParse(query['x'] ?? '') ?? -1,
          int.tryParse(query['y'] ?? '') ?? -1,
          int.tryParse(query['z'] ?? '') ?? -1,
        ),
};

void main() {
  setUp(() {
    MapDisplaySettings.instance.provider = MapBaseProvider.amap;
  });

  tearDown(() {
    MapDisplaySettings.instance.provider = MapBaseProvider.pmtiles;
  });

  testWidgets('两点同坐标（跨度为 0）：出图且不炸', (tester) async {
    const same = Offset(31.2304, 121.4737);
    await tester.pumpWidget(_host(const AmapRouteMap(points: [same, same])));
    await tester.pump(); // 帧后拟合
    expect(tester.takeException(), isNull);
    expect(find.byType(AmapRouteMap), findsOneWidget);
    // 拟合收敛后瓦片数必须在一屏的量级（上限 9×9）
    expect(_tileImages(tester), lessThanOrEqualTo(81));
  });

  testWidgets('空轨迹、NaN/越界坐标：都不炸', (tester) async {
    await tester.pumpWidget(_host(const AmapRouteMap(points: [])));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [
            Offset(double.infinity, 999.0), // 非法坐标 → 过滤掉
            Offset(99.0, 999.0), // 纬度/经度越界 → 过滤掉
            Offset(31.23, 121.47),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_tileImages(tester), lessThanOrEqualTo(81));
  });

  testWidgets('两万个点：一帧出得来，之后几帧不再变（拟合没有来回抖）', (tester) async {
    final points = List.generate(
      20000,
      (i) => Offset(31.23 + i * 1e-6, 121.47 + i * 1e-6),
    );
    await tester.pumpWidget(_host(AmapRouteMap(points: points)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final settled = _tileImages(tester);
    expect(settled, lessThanOrEqualTo(81));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_tileImages(tester), settled);
  });

  testWidgets('换一份新的点列表（同样内容）不应把相机抖回拟合循环', (tester) async {
    List<Offset> track() => [
      const Offset(31.23, 121.47),
      const Offset(31.24, 121.48),
    ];
    await tester.pumpWidget(_host(AmapRouteMap(points: track())));
    await tester.pump();
    final settled = _tileImages(tester);
    await tester.pumpWidget(_host(AmapRouteMap(points: track())));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_tileImages(tester), settled);
  });

  testWidgets('远端当前位置不能把路线缩小到不可见', (tester) async {
    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [
            Offset(30.73, 120.72),
            Offset(30.74, 120.76),
            Offset(30.76, 120.78),
          ],
          currentPoint: Offset(30.35, 119.99),
        ),
      ),
    );
    await tester.pump();
    final zooms = _tileZooms(tester);
    expect(zooms, isNotEmpty);
    expect(zooms.reduce(math.min), greaterThanOrEqualTo(11));
  });

  testWidgets('双指捏合缩放后瓦片仍然收敛', (tester) async {
    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [Offset(31.23, 121.47), Offset(31.24, 121.48)],
        ),
      ),
    );
    await tester.pump();

    // 两根手指从中间往外张（放大），再往中间收（缩小）。
    final finger1 = await tester.startGesture(const Offset(140, 130));
    final finger2 = await tester.startGesture(const Offset(220, 130));
    await tester.pump(const Duration(milliseconds: 100));
    await finger1.moveTo(const Offset(110, 130));
    await finger2.moveTo(const Offset(250, 130));
    await tester.pump(const Duration(milliseconds: 100));
    await finger1.moveTo(const Offset(165, 130));
    await finger2.moveTo(const Offset(195, 130));
    await tester.pump(const Duration(milliseconds: 100));
    await finger1.up();
    await finger2.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_tileImages(tester), lessThanOrEqualTo(81));
  });

  testWidgets('双击地图放大一级', (tester) async {
    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [Offset(31.23, 121.47), Offset(31.24, 121.48)],
        ),
      ),
    );
    await tester.pump();
    final before = _tileZooms(tester).reduce(math.max);

    final center = tester.getCenter(find.byType(AmapRouteMap));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 350));

    expect(tester.takeException(), isNull);
    expect(_tileZooms(tester).reduce(math.max), before + 1);
    final maxZoom = _tileZooms(tester).reduce(math.max);
    // 双击中心只放大、不把机位搬走：屏幕中心仍应落在轨迹中心附近。
    const centerLat = 31.235;
    const centerLon = 121.475;
    final expectedX = (((centerLon + 180) / 360) * (1 << maxZoom)).floor();
    final sinLat = math.sin(centerLat * math.pi / 180);
    final centerY = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
    final expectedY = (centerY * (1 << maxZoom)).floor();
    final tiles = _tiles(tester);
    expect(tiles.any((t) => (t.$1 - expectedX).abs() <= 1), isTrue);
    expect(tiles.any((t) => (t.$2 - expectedY).abs() <= 1), isTrue);
  });

  testWidgets('深色主题给高德底图叠加夜间滤镜', (tester) async {
    await tester.pumpWidget(
      _darkHost(
        const AmapRouteMap(
          points: [Offset(31.23, 121.47), Offset(31.24, 121.48)],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(_tileImages(tester), greaterThan(0));
  });

  testWidgets('关闭底图后只保留轨迹，不再加载瓦片', (tester) async {
    MapDisplaySettings.instance.showBaseMap = false;
    addTearDown(() => MapDisplaySettings.instance.showBaseMap = true);
    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [Offset(31.23, 121.47), Offset(31.24, 121.48)],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_tileImages(tester), 0);
  });

  testWidgets('实时跟随时车头朝上，轨迹增长后相机不缩小也不来回抖', (tester) async {
    final points = [
      const Offset(31.2300, 121.4700),
      const Offset(31.2305, 121.4705),
    ];
    await tester.pumpWidget(
      _host(
        AmapRouteMap(
          points: points,
          currentPoint: points.last,
          followCurrentPoint: true,
          fitInsets: const EdgeInsets.fromLTRB(24, 100, 24, 150),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_tileZooms(tester).reduce(math.max), 16);
    // 东北方向前进：整张地图要旋转，不能还是北向上。
    final rotate = tester.widget<Transform>(
      find.byKey(const ValueKey('amap-rotate')),
    );
    expect(rotate.transform.storage[1].abs(), greaterThan(0.01));
    final settled = _tileImages(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(_tileImages(tester), settled);
  });

  testWidgets('未开始移动时先展示完整目标路线，不被远端当前位置缩成一点', (tester) async {
    await tester.pumpWidget(
      _host(
        const AmapRouteMap(
          points: [Offset(30.3500, 119.9900)],
          targetPoints: [
            Offset(31.2300, 121.4700),
            Offset(31.2320, 121.4800),
            Offset(31.2330, 121.4900),
          ],
          supplyPoints: [Offset(31.2320, 121.4800)],
          currentPoint: Offset(30.3500, 119.9900),
          showEndpoints: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(AmapRouteMap), findsOneWidget);
    expect(_tileImages(tester), greaterThan(0));
    expect(_tileZooms(tester).reduce(math.max), lessThanOrEqualTo(15));
  });

  // 2026-11-08 隧道丢 GPS 事故：一段跨多个公里阈值时，旧实现把整段终点复用给所有
  // 标记，后画的圆标整个盖住先画的，地图上看就是"6 和 8 之间少了 7"。
  group('computeKmMarkers 段内插值', () {
    Offset project(double lat, double lon) {
      final x = (lon + 180) / 360;
      final clamped = lat.clamp(-85.0, 85.0);
      final sinLat = math.sin(clamped * math.pi / 180);
      final y = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
      return Offset(x, y);
    }

    List<Offset> projectAll(List<Offset> latLon) => [
      for (final p in latLon) project(p.dx, p.dy),
    ];

    test('一段跨 2 个公里阈值：两个标记位置必须不同', () {
      // 纬度方向 0.02° ≈ 2.22km，单段跨 1km 和 2km 两个阈值。
      final latLon = const [Offset(31.0, 121.0), Offset(31.02, 121.0)];
      final markers = computeKmMarkers(latLon, projectAll(latLon));
      expect(markers.length, 2);
      expect(markers[0].km, 1);
      expect(markers[1].km, 2);
      // 关键断言：两个标记的 worldPoint 不能相同（旧实现会相同）。
      expect(markers[0].worldPoint, isNot(markers[1].worldPoint));
      // Web Mercator 纬度越高 y 越小，所以 1km（纬度低）的 y 应大于 2km 的 y。
      expect(markers[0].worldPoint.dy, greaterThan(markers[1].worldPoint.dy));
    });

    test('标记位置按距离比例插值，不是按点数', () {
      // 一段 ~3.3km：1km/2km/3km 三个标记，y 差应大致相等。
      final latLon = const [
        Offset(0.0, 0.0),
        Offset(0.03, 0.0), // 约 3.34km（纬度 1° ≈ 111.19km）
      ];
      final markers = computeKmMarkers(latLon, projectAll(latLon));
      expect(markers.length, 3);
      final y0 = markers[0].worldPoint.dy;
      final y1 = markers[1].worldPoint.dy;
      final y2 = markers[2].worldPoint.dy;
      // 等距三段：y 差值应大致相等（Web Mercator 在赤道附近近似线性）
      expect(((y0 - y1) - (y1 - y2)).abs(), lessThan(0.001));
    });

    test('多段累计：每公里一个标记，无重复无遗漏', () {
      // 每段 0.5km，4 段共 2km，应有 1km 和 2km 两个标记。
      final latLon = [const Offset(31.0, 121.0)];
      // 纬度 0.0045° ≈ 0.5km
      for (var i = 1; i <= 4; i++) {
        latLon.add(Offset(31.0 + i * 0.0045, 121.0));
      }
      final markers = computeKmMarkers(latLon, projectAll(latLon));
      expect(markers.map((m) => m.km).toList(), [1, 2]);
    });

    test('五公里间隔只标 5、10 公里', () {
      final latLon = const [
        Offset(0.0, 0.0),
        Offset(0.10, 0.0), // 约 11.12km
      ];
      final markers = computeKmMarkers(latLon, projectAll(latLon), 5000);
      expect(markers.map((m) => m.km).toList(), [5, 10]);
    });

    test('退化段（点重合）：跳过不报错', () {
      final latLon = const [
        Offset(31.0, 121.0),
        Offset(31.0, 121.0), // 同坐标，segMeters = 0
        Offset(31.01, 121.0), // 约 1.11km
      ];
      final markers = computeKmMarkers(latLon, projectAll(latLon));
      expect(markers.length, 1);
      expect(markers[0].km, 1);
    });

    test('空/单点输入：返回空列表', () {
      expect(computeKmMarkers([], []), isEmpty);
      expect(
        computeKmMarkers(const [
          Offset(31.0, 121.0),
        ], projectAll(const [Offset(31.0, 121.0)])),
        isEmpty,
      );
    });
  });
}
