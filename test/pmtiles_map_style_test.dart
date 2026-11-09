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
}
