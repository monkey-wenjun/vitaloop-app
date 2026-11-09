import 'dart:math' as math;

/// 新版 workouts 表里的轨迹坐标系。
///
/// 旧版迁移的服务端轨迹和华为手表轨迹已经是 GCJ-02，旧版 AMap 直接按原值
/// 绘制就与道路吻合；只有新版手机 GPS 手动记录存的是 WGS-84 原始点。
bool workoutTrackIsWgs84(String source) => source == 'manual';

/// 中国大陆坐标系转换。
///
/// 手机 GPS 与手表轨迹是 WGS-84；高德栅格瓦片和地图点选结果是 GCJ-02。
/// 展示和导航比较前必须统一，否则在中国境内会整体偏移数百米。
class Coordinate {
  Coordinate._();

  static const _pi = 3.1415926535897932384626;
  static const _a = 6378245.0;
  static const _ee = 0.00669342162296594323;

  static bool outOfChina(double lat, double lon) =>
      lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static (double, double) wgs84ToGcj02(double lat, double lon) {
    if (outOfChina(lat, lon)) return (lat, lon);
    var dLat = _transformLat(lon - 105.0, lat - 35.0);
    var dLon = _transformLon(lon - 105.0, lat - 35.0);
    final radLat = lat / 180.0 * _pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi);
    dLon = (dLon * 180.0) / (_a / sqrtMagic * math.cos(radLat) * _pi);
    return (lat + dLat, lon + dLon);
  }

  static (double, double) gcj02ToWgs84(double lat, double lon) {
    if (outOfChina(lat, lon)) return (lat, lon);
    var wgsLat = lat;
    var wgsLon = lon;
    for (var i = 0; i < 3; i++) {
      final (gcjLat, gcjLon) = wgs84ToGcj02(wgsLat, wgsLon);
      wgsLat -= gcjLat - lat;
      wgsLon -= gcjLon - lon;
    }
    return (wgsLat, wgsLon);
  }

  static double _transformLat(double x, double y) {
    var ret =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    ret +=
        (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret +=
        (20.0 * math.sin(y * _pi) + 40.0 * math.sin(y / 3.0 * _pi)) * 2.0 / 3.0;
    ret +=
        (160.0 * math.sin(y / 12.0 * _pi) + 320 * math.sin(y * _pi / 30.0)) *
        2.0 /
        3.0;
    return ret;
  }

  static double _transformLon(double x, double y) {
    var ret =
        300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    ret +=
        (20.0 * math.sin(6.0 * x * _pi) + 20.0 * math.sin(2.0 * x * _pi)) *
        2.0 /
        3.0;
    ret +=
        (20.0 * math.sin(x * _pi) + 40.0 * math.sin(x / 3.0 * _pi)) * 2.0 / 3.0;
    ret +=
        (150.0 * math.sin(x / 12.0 * _pi) + 300.0 * math.sin(x / 30.0 * _pi)) *
        2.0 /
        3.0;
    return ret;
  }
}
