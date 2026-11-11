import 'dart:math' as math;

/// 高德栅格瓦片地址。
///
/// `ltype=11` 是高德的无路名底图；`0`/缺省是带街道名称的完整底图。
/// 地图渲染和「下载当前城市」都走这里，避免两边的 z/x/y 和 ltype 对不上。
String amapTileUrl(int x, int y, int z, {bool labels = true}) {
  final server = (x + y) % 4 + 1;
  final ltype = labels ? 0 : 11;
  return 'https://webrd0$server.is.autonavi.com/appmaptile'
      '?lang=zh_cn&size=1&scale=1&style=8&ltype=$ltype&x=$x&y=$y&z=$z';
}

int _tileX(double lon, int z) => (((lon + 180) / 360) * (1 << z)).floor();

int _tileY(double lat, int z) {
  final sinLat = math.sin(lat.clamp(-85.0, 85.0) * math.pi / 180);
  final y = 0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi);
  return (y * (1 << z)).floor();
}

/// 以 (lat, lon) 为中心、±[padDegrees] 覆盖的瓦片列表。
///
/// 离线下载默认取约 49km × 49km、缩放 10–15，和 PMTiles 离线区的尺度一致。
List<String> amapCityTileUrls({
  required double lat,
  required double lon,
  double padDegrees = 0.22,
  int minZoom = 10,
  int maxZoom = 15,
  bool labels = true,
}) {
  final urls = <String>{};
  final north = (lat + padDegrees).clamp(-85.0, 85.0);
  final south = (lat - padDegrees).clamp(-85.0, 85.0);
  final west = lon - padDegrees;
  final east = lon + padDegrees;
  for (var z = minZoom; z <= maxZoom; z++) {
    final count = 1 << z;
    final x0 = _tileX(west, z).clamp(0, count - 1);
    final x1 = _tileX(east, z).clamp(0, count - 1);
    final y0 = _tileY(north, z).clamp(0, count - 1);
    final y1 = _tileY(south, z).clamp(0, count - 1);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        urls.add(amapTileUrl(x, y, z, labels: labels));
      }
    }
  }
  return urls.toList(growable: false);
}
