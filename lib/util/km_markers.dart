import 'dart:math' as math;
import 'dart:ui';

class KmGeoMarker {
  const KmGeoMarker(this.km, this.point);

  final int km;
  final Offset point;
}

List<KmGeoMarker> computeKmGeoMarkers(
  List<Offset> points, [
  int intervalM = 1000,
]) {
  final stepM = intervalM < 1000 ? 1000 : intervalM;
  final markers = <KmGeoMarker>[];
  var travelled = 0.0;
  var nextMarkM = stepM;
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1];
    final b = points[i];
    final segment = distanceMeters(a.dx, a.dy, b.dx, b.dy);
    final before = travelled;
    travelled += segment;
    while (travelled >= nextMarkM) {
      final fraction = segment <= 0
          ? 1.0
          : ((nextMarkM - before) / segment).clamp(0.0, 1.0);
      markers.add(KmGeoMarker(nextMarkM ~/ 1000, Offset.lerp(a, b, fraction)!));
      nextMarkM += stepM;
    }
    if (nextMarkM > 200000) break;
  }
  return markers;
}

double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earth = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earth * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
