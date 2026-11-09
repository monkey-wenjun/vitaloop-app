/// 基于保存路线折线的转向引导。
///
/// 输入坐标必须已经在同一坐标系（GCJ-02）：路线点来自高德地图点选，
/// 手机 GPS 需要先在 Dart 侧转成 GCJ-02。
pub fn route_guidance(route_json: String, lat: f64, lon: f64, arrival_radius_m: f64) -> String {
    crate::navigation::guidance(&route_json, lat, lon, arrival_radius_m)
}
