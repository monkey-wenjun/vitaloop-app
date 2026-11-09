import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/api.dart';
import '../../../src/rust/api/types.dart';
import 'sleep_data.dart';

class SleepController extends ChangeNotifier {
  SleepController({required this.day});

  final int? day;

  NightSleepData? night;
  SleepPeriodData? period;
  List<ApneaRecord> apnea = const [];
  int rangeIndex = 0;
  bool loadingNight = true;
  bool loadingPeriod = false;
  bool loadingApnea = false;
  String? error;

  bool get disposed => _disposed;
  bool _disposed = false;

  Future<void> load() async {
    loadingNight = true;
    error = null;
    _notify();
    try {
      final detail = await VitaloopApi.sleepDetail(day: day);
      if (_disposed) return;
      night = detail == null ? null : NightSleepData.fromDetail(detail);
      if (detail != null) {
        unawaited(_loadApnea(detail.summary.dateEpochDay.toInt()));
      }
    } catch (e) {
      if (!_disposed) error = e.toString();
    } finally {
      if (!_disposed) {
        loadingNight = false;
        _notify();
      }
    }
  }

  Future<void> setRange(int index) async {
    if (index == rangeIndex || loadingPeriod) return;
    rangeIndex = index;
    period = null;
    if (index == 0) {
      _notify();
      return;
    }
    loadingPeriod = true;
    error = null;
    _notify();
    try {
      final days = index == 1 ? 7 : 30;
      final results = await Future.wait([
        VitaloopApi.metricSeries('sleep', days),
        VitaloopApi.metricSeries('deep_sleep', days),
        VitaloopApi.metricSeries('rem_sleep', days),
        VitaloopApi.metricSeries('awake', days),
      ]);
      if (_disposed) return;
      period = SleepPeriodData.fromSeries(
        rangeIndex: index,
        total: results[0],
        deep: results[1],
        rem: results[2],
        awake: results[3],
      );
    } catch (e) {
      if (!_disposed) error = e.toString();
    } finally {
      if (!_disposed) {
        loadingPeriod = false;
        _notify();
      }
    }
  }

  Future<void> _loadApnea(int epochDay) async {
    loadingApnea = true;
    _notify();
    try {
      final records = await VitaloopApi.apneaForDay(epochDay);
      if (!_disposed) apnea = records;
    } catch (_) {
      if (!_disposed) apnea = const [];
    } finally {
      if (!_disposed) {
        loadingApnea = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
