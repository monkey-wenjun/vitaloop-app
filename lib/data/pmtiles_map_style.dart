import 'dart:convert';

Map<String, Object?> pmtilesMapStyle({
  required String sourceUrl,
  bool night = false,
  bool showBaseMap = true,
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
    layers.addAll(_baseLayers(c: c));
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
    'sources': hasBaseSource ? {'protomaps': vectorSource} : const {},
    'layers': layers,
  };
}

List<Map<String, Object?>> _baseLayers({required Map<String, String> c}) {
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
}) => jsonEncode(
  pmtilesMapStyle(sourceUrl: sourceUrl, night: night, showBaseMap: showBaseMap),
);
