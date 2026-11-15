import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/pmtiles_map_style.dart';

void main() {
  test('Liberty 亮色和 Dark 暗色共用 PMTiles 矢量源', () {
    final day = jsonDecode(
      pmtilesMapStyleJson(sourceUrl: 'https://tiles.example.com'),
    ) as Map<String, dynamic>;
    final night = jsonDecode(
      pmtilesMapStyleJson(sourceUrl: 'https://tiles.example.com', night: true),
    ) as Map<String, dynamic>;

    final daySource = (day['sources'] as Map)['protomaps'] as Map;
    final nightSource = (night['sources'] as Map)['protomaps'] as Map;
    expect(daySource['tiles'], [
      'https://tiles.example.com/tiles/{z}/{x}/{y}.mvt',
    ]);
    expect(nightSource['tiles'], daySource['tiles']);
    expect(day['glyphs'], contains('{fontstack}'));
    final ids = (day['layers'] as List)
        .map((layer) => (layer as Map)['id'])
        .toSet();
    expect(ids, containsAll(['roads-labels-major', 'places-labels']));
    expect((day['layers'] as List).first['paint'], {
      'background-color': '#edf2f7',
    });
    expect((night['layers'] as List).first['paint'], {
      'background-color': '#111827',
    });
  });

  test('关闭底图时不请求 PMTiles', () {
    final style = jsonDecode(
      pmtilesMapStyleJson(
        sourceUrl: 'https://tiles.example.com',
        showBaseMap: false,
      ),
    ) as Map<String, dynamic>;
    expect(style['sources'], isEmpty);
    expect(style['layers'], hasLength(1));
  });

  test('未配置瓦片服务时不生成网络瓦片源', () {
    final style = pmtilesMapStyle(sourceUrl: '');
    expect(style['sources'], isEmpty);
    expect(style['layers'], hasLength(1));
  });

  test('配置 DEM 后加入 terrarium 源、山体阴影和海拔着色', () {
    final style = jsonDecode(
      pmtilesMapStyleJson(
        sourceUrl: 'https://tiles.example.com',
        demUrl: 'https://tiles.example.com/dem',
      ),
    ) as Map<String, dynamic>;
    final dem = (style['sources'] as Map)['terrain-dem'] as Map;
    expect(dem['type'], 'raster-dem');
    expect(dem['encoding'], 'terrarium');
    expect(dem['tiles'], ['https://tiles.example.com/dem/{z}/{x}/{y}.png']);

    final layers = (style['layers'] as List).cast<Map>();
    final ids = layers.map((layer) => layer['id']).toList();
    final hillshade = layers.firstWhere(
      (layer) => layer['id'] == 'terrain-hillshade',
    );
    expect(hillshade['type'], 'hillshade');
    expect(hillshade['source'], 'terrain-dem');
    final relief = layers.firstWhere(
      (layer) => layer['id'] == 'terrain-elevation-tint',
    );
    expect(relief['type'], 'color-relief');
    // 地形要压在陆地上、盖在水系和道路之下。
    expect(ids.indexOf('terrain-hillshade'), greaterThan(ids.indexOf('earth')));
    expect(ids.indexOf('terrain-hillshade'), lessThan(ids.indexOf('water')));
  });

  test('不传 DEM 时不请求地形瓦片', () {
    final style = pmtilesMapStyle(sourceUrl: 'https://tiles.example.com');
    expect((style['sources'] as Map).containsKey('terrain-dem'), isFalse);
    final ids = (style['layers'] as List)
        .map((layer) => (layer as Map)['id'])
        .toSet();
    expect(ids, isNot(contains('terrain-hillshade')));
  });

  test('配置等高线后叠在道路下面、水系上面', () {
    final style = jsonDecode(
      pmtilesMapStyleJson(
        sourceUrl: 'https://tiles.example.com',
        demUrl: 'https://tiles.example.com/dem',
        contourUrl: 'https://tiles.example.com/contours',
      ),
    ) as Map<String, dynamic>;
    final source = (style['sources'] as Map)['terrain-contours'] as Map;
    expect(source['type'], 'raster');
    expect(source['tiles'], [
      'https://tiles.example.com/contours/{z}/{x}/{y}.png',
    ]);
    final layers = (style['layers'] as List).cast<Map>();
    final ids = layers.map((layer) => layer['id']).toList();
    final contours = layers.firstWhere((layer) => layer['id'] == 'terrain-contours');
    expect(contours['type'], 'raster');
    expect(contours['source'], 'terrain-contours');
    // 等高线压在水系上，但不能盖住道路和路名。
    expect(ids.indexOf('terrain-contours'), greaterThan(ids.indexOf('water')));
    expect(ids.indexOf('terrain-contours'), lessThan(ids.indexOf('roads-casing')));
  });

  test('不传等高线地址时不生成等高线图层', () {
    final style = pmtilesMapStyle(
      sourceUrl: 'https://tiles.example.com',
      demUrl: 'https://tiles.example.com/dem',
    );
    expect((style['sources'] as Map).containsKey('terrain-contours'), isFalse);
    final ids = (style['layers'] as List)
        .map((layer) => (layer as Map)['id'])
        .toSet();
    expect(ids, isNot(contains('terrain-contours')));
  });
}
