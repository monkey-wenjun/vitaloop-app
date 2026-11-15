/// OpenTopoMap 等高线地形瓦片。
///
/// 瓦片本身就是 WGS-84 的 Web Mercator，和手机 GPS / 手表轨迹同一坐标系，
/// 不需要像高德那样做 GCJ-02 偏移。徒步、越野这类需要看山脊和等高线的
/// 场景用它；日常街道仍然用自托管 PMTiles。
///
/// 使用条款：OpenTopoMap 只允许按需浏览，禁止批量预下载。所以这里不提供
/// 城市离线预取，只依赖 [AmapTileCache] 的浏览缓存。
String opentopoTileUrl(int x, int y, int z) {
  final server = const ['a', 'b', 'c'][(x + y) % 3];
  return 'https://$server.tile.opentopomap.org/$z/$x/$y.png';
}

const opentopoAttribution =
    '© OpenStreetMap contributors, SRTM · 样式 © OpenTopoMap (CC-BY-SA)';
