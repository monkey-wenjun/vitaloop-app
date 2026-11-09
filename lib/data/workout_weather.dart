import 'dart:convert';
import 'dart:io';

import '../src/rust/api/types.dart';
import 'api.dart';

/// 给带 GPS 轨迹、但缺温度/湿度的运动补 Open-Meteo 历史天气。
///
/// 旧版是在手表运动入库时同步查；新版入库在 Rust/原生侧，界面只负责
/// 在 refresh 后后台补齐，避免阻塞同步线程和首屏。
class WorkoutWeatherService {
  WorkoutWeatherService._();

  static bool _running = false;
  static DateTime? _lastRun;
  static const _minInterval = Duration(minutes: 5);

  static Future<void> backfill({bool force = false}) async {
    if (_running) return;
    final now = DateTime.now();
    if (!force &&
        _lastRun != null &&
        now.difference(_lastRun!) < _minInterval) {
      return;
    }
    _lastRun = now;
    _running = true;
    try {
      final candidates = await VitaloopApi.missingWorkoutWeather(limit: 8);
      for (final candidate in candidates) {
        await _fill(candidate);
      }
    } catch (_) {
      // 网络抖动或接口暂时不可用，留给下一轮 refresh 重试。
    } finally {
      _running = false;
    }
  }

  static Future<bool> _fill(WorkoutWeatherCandidate candidate) async {
    final start = DateTime.fromMillisecondsSinceEpoch(
      candidate.startMs.toInt(),
    );
    final weather = await _fetch(candidate.lat, candidate.lon, start);
    if (weather == null) return false;
    final temp = candidate.startTempC == null ? weather.tempC : null;
    final humidity = candidate.startHumidity == null
        ? weather.humidity?.round()
        : null;
    if (temp == null && humidity == null) return false;
    await VitaloopApi.setWorkoutWeather(
      candidate.id,
      tempC: temp,
      humidity: humidity,
    );
    return true;
  }

  static Future<_Weather?> _fetch(
    double lat,
    double lon,
    DateTime start,
  ) async {
    final date =
        '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final query = <String, String>{
      'latitude': lat.toStringAsFixed(5),
      'longitude': lon.toStringAsFixed(5),
      'hourly': 'temperature_2m,relativehumidity_2m',
      'timezone': 'Asia/Shanghai',
    };
    final archive = Uri.https('archive-api.open-meteo.com', '/v1/archive', {
      ...query,
      'start_date': date,
      'end_date': date,
    });
    final archived = await _getHourly(archive, start);
    if (archived?.hasValue == true) return archived;

    // 当天的运动 archive 还没出数，用 forecast 的 past_days 兜底。
    final forecast = Uri.https('api.open-meteo.com', '/v1/forecast', {
      ...query,
      'past_days': '7',
      'forecast_days': '1',
    });
    return await _getHourly(forecast, start) ?? archived;
  }

  static Future<_Weather?> _getHourly(Uri uri, DateTime start) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      try {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode != 200) {
          await response.drain<void>();
          continue;
        }
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
        final root = jsonDecode(body);
        if (root is! Map) continue;
        final hourly = root['hourly'];
        if (hourly is! Map) continue;
        final times = (hourly['time'] as List?)?.cast<String>();
        if (times == null || times.isEmpty) continue;

        var bestIndex = -1;
        Duration? bestDiff;
        for (var i = 0; i < times.length; i++) {
          final time = DateTime.tryParse(times[i]);
          if (time == null) continue;
          final diff = time.difference(start).abs();
          if (bestDiff == null || diff < bestDiff) {
            bestDiff = diff;
            bestIndex = i;
          }
        }
        if (bestIndex < 0 ||
            bestDiff == null ||
            bestDiff > const Duration(minutes: 90)) {
          continue;
        }
        final temps = hourly['temperature_2m'] as List?;
        final humidity = hourly['relativehumidity_2m'] as List?;
        final temp = _number(temps, bestIndex);
        final humid = _number(humidity, bestIndex);
        if (temp != null || humid != null) {
          return _Weather(temp, humid);
        }
      } catch (_) {
        // 重试一次；仍失败则留给下一轮 refresh。
      } finally {
        client.close(force: true);
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  static double? _number(List? values, int index) {
    if (values == null || index >= values.length) return null;
    final value = values[index];
    return value is num ? value.toDouble() : null;
  }
}

class _Weather {
  const _Weather(this.tempC, this.humidity);

  final double? tempC;
  final double? humidity;

  bool get hasValue => tempC != null || humidity != null;
}
