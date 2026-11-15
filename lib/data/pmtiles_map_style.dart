import 'dart:convert';

Map<String, Object?> pmtilesMapStyle({
  required String sourceUrl,
  bool night = false,
  bool showBaseMap = true,
  String demUrl = '',
  String contourUrl = '',
}) {
  final c = night
      ? const {
          'background': '#111827',
          'earth': '#151f2d',
          'water': '#17395f',
          'landuse': '#1a2d34',
          'building': '#243143',
          'road': '#53657c',
          'roadMinor': '#39495e',
          'poi': '#f59e0b',
          'boundary': '#697b91',
          'label': '#d9e2ef',
          'labelHalo': '#111827',
        }
      : const {
          'background': '#edf2f7',
          'earth': '#f4f1e9',
          'water': '#9fc7e8',
          'landuse': '#e4eddc',
          'building': '#d8d9d6',
          'road': '#ffffff',
          'roadMinor': '#e3e5e2',
          'poi': '#ea580c',
          'boundary': '#b8c0c8',
          'label': '#334155',
          'labelHalo': '#ffffff',
        };
  final layers = <Map<String, Object?>>[
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': c['background']},
    },
  ];
  final hasBaseSource = showBaseMap && sourceUrl.trim().isNotEmpty;
  if (hasBaseSource) {
    layers.addAll(_baseLayers(c: c, night: night));
  }
  final dem = demUrl.trim();
  final hasDem = hasBaseSource && dem.isNotEmpty;
  if (hasDem) {
    _addTerrainLayers(layers, dem: dem, night: night);
  }
  final contours = contourUrl.trim();
  if (hasBaseSource && contours.isNotEmpty) {
    _addContourLayer(layers, url: contours, night: night);
  }
  final vectorSource = sourceUrl.contains('.pmtiles')
      ? <String, Object?>{
          'type': 'vector',
          'url': 'pmtiles://$sourceUrl',
          'attribution': 'Protomaps · Map data © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors, ODbL',
        }
      : <String, Object?>{
          'type': 'vector',
          'tiles': ['$sourceUrl/tiles/{z}/{x}/{y}.mvt'],
          'minzoom': 0,
          'maxzoom': 15,
          'attribution': 'Protomaps · Map data © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors, ODbL',
        };
  return {
    'version': 8,
    'glyphs': 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
    'sources': {
      if (hasBaseSource) 'protomaps': vectorSource,
      if (hasDem)
        'terrain-dem': <String, Object?>{
          'type': 'raster-dem',
          'tiles': ['$dem/{z}/{x}/{y}.png'],
          'encoding': 'terrarium',
          'tileSize': 256,
          'minzoom': 0,
          'maxzoom': 15,
          'attribution': 'Elevation: Mapzen / AWS Terrain Tiles (SRTM, GMTED)',
        },
      if (hasBaseSource && contours.isNotEmpty)
        'terrain-contours': <String, Object?>{
          'type': 'raster',
          'tiles': ['$contours/{z}/{x}/{y}.png'],
          'tileSize': 256,
          'minzoom': 0,
          'maxzoom': 15,
          'attribution': '等高线：vitaloop 自算（SRTM / GMTED）',
        },
    },
    'layers': layers,
  };
}

/// 等高线是服务端从 DEM 现算的透明 PNG，叠在道路和标注下面，
/// 这样线不会盖住路名，也不会糊住轨迹。
void _addContourLayer(
  List<Map<String, Object?>> layers, {
  required String url,
  required bool night,
}) {
  final layer = <String, Object?>{
    'id': 'terrain-contours',
    'type': 'raster',
    'source': 'terrain-contours',
    'paint': {
      'raster-opacity': night ? 0.5 : 0.85,
      'raster-contrast': night ? 0.1 : 0.2,
    },
  };
  final insertAt = layers.indexWhere((item) => item['id'] == 'roads-casing');
  if (insertAt < 0) {
    layers.add(layer);
  } else {
    layers.insert(insertAt, layer);
  }
}

/// 把 DEM 山体阴影和海拔分层着色插到陆地之后、水系道路之前。
///
/// MapLibre Native 还没有 3D 地形（`setTerrain` 只有 web 支持），但
/// `hillshade` + `color-relief` 已经能给出接近高驰的立体山地观感：
/// 阴影勾出山脊沟谷，分层着色让山地整片是绿的、高处偏深，裸露的
/// 高峰再往黄褐过渡 —— 和纸质登山图、高驰的观感一致。
void _addTerrainLayers(
  List<Map<String, Object?>> layers, {
  required String dem,
  required bool night,
}) {
  final insertAt = layers.indexWhere((layer) => layer['id'] == 'water');
  final terrain = <Map<String, Object?>>[
    {
      'id': 'terrain-hillshade',
      'type': 'hillshade',
      'source': 'terrain-dem',
      'paint': {
        // 阴影垫在着色下面：着色盖住之后仍然能透出山脊沟谷，
        // 又不会因为白色高光把整片山冲成浅灰。
        // 单向光比 multidirectional 更能勾出山脊线，避免糊成一团灰雾。
        'hillshade-illumination-direction': 315,
        'hillshade-illumination-altitude': 45,
        'hillshade-exaggeration': night ? 0.4 : 0.8,
        'hillshade-shadow-color': night ? '#0b1220' : '#7d8f6e',
        'hillshade-highlight-color': night ? '#5a6b80' : '#ffffff',
        'hillshade-accent-color': night ? '#22303d' : '#cfc4ac',
      },
    },
    {
      'id': 'terrain-elevation-tint',
      'type': 'color-relief',
      'source': 'terrain-dem',
      'paint': {
        // 白天要真的盖住米色底图，否则山看起来是灰黄的。
        'color-relief-opacity': night ? 0.18 : 0.82,
        'color-relief-color': [
          'interpolate',
          ['linear'],
          ['elevation'],
          0,
          'rgba(146, 184, 126, 1)',
          120,
          'rgba(134, 176, 112, 1)',
          350,
          'rgba(118, 166, 98, 1)',
          700,
          'rgba(102, 152, 86, 1)',
          1200,
          'rgba(96, 144, 84, 1)',
          1800,
          'rgba(112, 148, 92, 1)',
          2400,
          'rgba(146, 152, 104, 1)',
          2600,
          'rgba(186, 186, 158, 1)',
          3200,
          'rgba(222, 220, 212, 1)',
        ],
      },
    },
  ];
  if (insertAt < 0) {
    layers.addAll(terrain);
  } else {
    layers.insertAll(insertAt, terrain);
  }
}

List<Map<String, Object?>> _baseLayers({
  required Map<String, String> c,
  bool night = false,
}) {
  return [
    {
      'id': 'earth',
      'type': 'fill',
      'source': 'protomaps',
      'source-layer': 'earth',
      'paint': {'fill-color': c['earth']},
    },
    {
      'id': 'landuse',
      'type': 'fill',
      'source': 'protomaps',
      'source-layer': 'landuse',
      'paint': {'fill-color': c['landuse'], 'fill-opacity': 0.72},
    },
    {
      'id': 'water',
      'type': 'fill',
      'source': 'protomaps',
      'source-layer': 'water',
      'filter': [
        '==',
        ['geometry-type'],
        'Polygon',
      ],
      'paint': {'fill-color': c['water']},
    },
    {
      'id': 'roads-casing',
      'type': 'line',
      'source': 'protomaps',
      'source-layer': 'roads',
      'paint': {
        'line-color': c['roadMinor'],
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          0.8,
          14,
          4,
          18,
          18,
        ],
      },
    },
    {
      'id': 'roads',
      'type': 'line',
      'source': 'protomaps',
      'source-layer': 'roads',
      'paint': {
        'line-color': c['road'],
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          10,
          0.4,
          14,
          2.2,
          18,
          10,
        ],
      },
    },
    {
      'id': 'buildings',
      'type': 'fill',
      'source': 'protomaps',
      'source-layer': 'buildings',
      'minzoom': 13,
      'paint': {
        'fill-color': c['building'],
        'fill-opacity': [
          'interpolate',
          ['linear'],
          ['zoom'],
          13,
          0,
          15,
          0.8,
        ],
      },
    },
    {
      'id': 'roads-labels-major',
      'type': 'symbol',
      'source': 'protomaps',
      'source-layer': 'roads',
      'minzoom': 11,
      'filter': [
        'all',
        ['has', 'name'],
        [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['highway', 'major_road'],
          ],
        ],
      ],
      'layout': {
        'symbol-placement': 'line',
        'text-field': ['get', 'name'],
        'text-font': ['Noto Sans Regular'],
        'text-size': [
          'interpolate',
          ['linear'],
          ['zoom'],
          11,
          10,
          16,
          12.5,
        ],
        'symbol-spacing': 260,
        'text-rotation-alignment': 'map',
        'text-pitch-alignment': 'viewport',
      },
      'paint': {
        'text-color': c['label'],
        'text-halo-color': c['labelHalo'],
        'text-halo-width': 1.4,
      },
    },
    {
      'id': 'roads-labels-minor',
      'type': 'symbol',
      'source': 'protomaps',
      'source-layer': 'roads',
      'minzoom': 14,
      'filter': [
        'all',
        ['has', 'name'],
        [
          'in',
          ['get', 'kind'],
          [
            'literal',
            ['minor_road', 'other', 'path'],
          ],
        ],
      ],
      'layout': {
        'symbol-placement': 'line',
        'text-field': ['get', 'name'],
        'text-font': ['Noto Sans Regular'],
        'text-size': 10.5,
        'symbol-spacing': 320,
        'text-rotation-alignment': 'map',
        'text-pitch-alignment': 'viewport',
      },
      'paint': {
        'text-color': c['label'],
        'text-halo-color': c['labelHalo'],
        'text-halo-width': 1.2,
      },
    },
    {
      'id': 'places-labels',
      'type': 'symbol',
      'source': 'protomaps',
      'source-layer': 'places',
      'minzoom': 9,
      'filter': ['has', 'name'],
      'layout': {
        'text-field': ['get', 'name'],
        'text-font': ['Noto Sans Regular'],
        'text-size': [
          'interpolate',
          ['linear'],
          ['zoom'],
          9,
          11,
          15,
          14,
        ],
        'text-anchor': 'center',
        'text-max-width': 8,
      },
      'paint': {
        'text-color': c['label'],
        'text-halo-color': c['labelHalo'],
        'text-halo-width': 1.5,
      },
    },
  ];
}

String pmtilesMapStyleJson({
  required String sourceUrl,
  bool night = false,
  bool showBaseMap = true,
  String demUrl = '',
  String contourUrl = '',
}) => jsonEncode(
  pmtilesMapStyle(
    sourceUrl: sourceUrl,
    night: night,
    showBaseMap: showBaseMap,
    demUrl: demUrl,
    contourUrl: contourUrl,
  ),
);
