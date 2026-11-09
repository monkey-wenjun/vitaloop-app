import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import 'api.dart';

/// 标准 BLE 心率带桥：扫描/连接/实时心率都走原生 GATT，心率样本批量写入 Rust。
class BleBridge {
  BleBridge._();

  static final BleBridge instance = BleBridge._();

  static const _method = MethodChannel('vitaloop/ble');
  static const _events = EventChannel('vitaloop/ble_events');

  final devices = ValueNotifier<Map<String, Map<String, dynamic>>>({});
  final history = ValueNotifier<Map<String, String>>({});
  final scanning = ValueNotifier<bool>(false);
  final latestHeartRate = ValueNotifier<int>(0);
  final _rrController = StreamController<int>.broadcast();

  /// 标准心率带上报的 RR 间期（毫秒）。没有 RR 能力的设备不会产生事件。
  Stream<int> get rrIntervals => _rrController.stream;

  // ignore: unused_field
  StreamSubscription? _sub;
  bool _listening = false;
  AppState? _appState;
  final List<Map<String, dynamic>> _buffer = [];
  final Map<String, int> _lastSaved = {};
  Timer? _flushTimer;

  void attach(AppState state) {
    _appState = state;
    _ensureListen();
    _loadHistory();
    unawaited(_configureScaleProfile());
    unawaited(_autoConnect());
  }

  Future<void> _configureScaleProfile() async {
    final profile = _appState?.profile;
    if (profile == null) return;
    try {
      await _method.invokeMethod('configure_scale', {
        'heightCm': profile.heightCm,
        'age': _ageFromBirthDate(profile.birthDate),
        'sex': profile.gender == 'female' ? 'female' : 'male',
      });
    } catch (_) {}
  }

  int _ageFromBirthDate(String birth) {
    final d = DateTime.tryParse(birth);
    if (d == null) return 30;
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month || (now.month == d.month && now.day < d.day)) age--;
    return age > 0 ? age : 30;
  }

  Future<void> _ensureListen() async {
    if (_listening) return;
    _listening = true;
    try {
      _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    } catch (_) {
      _listening = false;
    }
  }

  void _onEvent(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final address = msg['address'] as String? ?? '';
      if (type == 'scan') {
        scanning.value = msg['scanning'] == true;
        return;
      }
      if (type == 'forget') {
        final next = Map<String, Map<String, dynamic>>.from(devices.value)
          ..remove(address);
        devices.value = next;
        _loadHistory();
        return;
      }
      if (address.isEmpty) return;
      final current = Map<String, Map<String, dynamic>>.from(devices.value);
      final item = Map<String, dynamic>.from(current[address] ?? {});
      item['address'] = address;
      item['name'] = msg['name'] ?? item['name'] ?? '';
      item['rssi'] = msg['rssi'] ?? item['rssi'] ?? 0;
      item['state'] = msg['state'] ?? item['state'] ?? 'disconnected';
      item['kind'] = msg['kind'] ?? item['kind'] ?? '';
      item['display'] = msg['display'] ?? item['display'] ?? '';
      item['heartRate'] = msg['heartRate'] ?? item['heartRate'] ?? 0;
      item['battery'] = msg['battery'] ?? item['battery'] ?? -1;
      item['charging'] = msg['charging'] ?? item['charging'];
      item['weightKg'] = msg['weightKg'] ?? item['weightKg'];
      item['bodyFatPercent'] = msg['bodyFatPercent'] ?? item['bodyFatPercent'];
      // 体脂秤一次称重会同时回传肌肉/水分/骨量等成分；只存进历史不带到
      // 实时卡片的话，用户连上秤后只能看到体重和体脂率。
      for (final key in _scaleCompositionKeys) {
        if (msg[key] != null) item[key] = msg[key];
      }
      current[address] = item;
      devices.value = current;
      _refreshAverage();
      if (type == 'hr') {
        final bpm = item['heartRate'] as int? ?? 0;
        if (bpm > 0) {
          _buffer.add({
            't': 'hr',
            'ts': msg['ts'] ?? DateTime.now().millisecondsSinceEpoch,
            'bpm': bpm,
          });
          _flushTimer ??= Timer(const Duration(seconds: 5), _flush);
          if (_buffer.length >= 30) _flush();
        }
        final rr = msg['rr'];
        if (rr is List) {
          for (final value in rr) {
            if (value is num) _rrController.add(value.toInt());
          }
        }
      }
      if (type == 'weight') {
        final kg = (msg['weightKg'] as num?)?.toDouble() ?? 0;
        final fat = (msg['bodyFatPercent'] as num?)?.toDouble() ?? 0;
        final stable = msg['stable'] != false;
        if (kg >= 10 &&
            (fat > 0
                ? _shouldSave('weight_comp', seconds: 6)
                : (stable && _shouldSave('weight')))) {
          _saveScale(msg);
        }
      } else if (type == 'bp') {
        final sys = (msg['systolic'] as num?)?.toInt() ?? 0;
        final dia = (msg['diastolic'] as num?)?.toInt() ?? 0;
        final pulse = (msg['pulse'] as num?)?.toInt() ?? 0;
        if (sys > 0 && dia > 0 && _shouldSave('bp')) _saveBp(sys, dia, pulse);
      } else if (type == 'glucose') {
        final value = (msg['value'] as num?)?.toDouble() ?? 0;
        if (value > 0 && _shouldSave('glucose')) _saveGlucose(value);
      }
      if (item['state'] == 'connected') _loadHistory();
    } catch (_) {}
  }

  bool _shouldSave(String key, {int seconds = 15}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastSaved[key] ?? 0;
    if (now - last < seconds * 1000) return false;
    _lastSaved[key] = now;
    return true;
  }

  Future<void> _saveScale(Map<String, dynamic> msg) async {
    final kg = (msg['weightKg'] as num?)?.toDouble() ?? 0;
    if (kg < 10) return;
    final event = <String, dynamic>{
      't': 'weight',
      'ts': msg['ts'] ?? DateTime.now().millisecondsSinceEpoch,
      'kg': kg,
      'source': 'scale',
      'device': msg['name'] ?? '',
    };
    void put(String from, String to) {
      final value = (msg[from] as num?)?.toDouble() ?? 0;
      if (value > 0) event[to] = value;
    }

    put('bodyFatPercent', 'body_fat');
    put('musclePercent', 'muscle');
    put('waterPercent', 'water');
    put('proteinPercent', 'protein');
    put('bonePercent', 'bone');
    put('fatMassKg', 'fat_mass');
    put('muscleMassKg', 'muscle_mass');
    put('waterMassKg', 'water_mass');
    put('proteinMassKg', 'protein_mass');
    put('boneMassKg', 'bone_mass');
    put('skeletalMusclePercent', 'skeletal_muscle');
    put('skeletalMuscleMassKg', 'skeletal_muscle_mass');
    put('subcutaneousFatPercent', 'subcutaneous_fat');
    put('subcutaneousFatMassKg', 'subcutaneous_fat_mass');
    put('resistanceOhm', 'resistance');
    put('heightCm', 'height_cm');
    final model = msg['model'] as String?;
    if (model != null && model.isNotEmpty) event['model'] = model;
    try {
      await VitaloopApi.ingestWatchData(
        eventsJson: jsonEncode({
          'events': [event],
        }),
      );
      await _appState?.refresh();
    } catch (_) {}
  }

  Future<void> _saveBp(int systolic, int diastolic, int pulse) async {
    try {
      await VitaloopApi.addBloodPressure(
        systolic: systolic,
        diastolic: diastolic,
        pulse: pulse,
      );
      await _appState?.refresh();
    } catch (_) {}
  }

  Future<void> _saveGlucose(double value) async {
    try {
      await VitaloopApi.addBloodGlucose(value: value);
      await _appState?.refresh();
    } catch (_) {}
  }

  void _refreshAverage() {
    final values = devices.value.values
        .where((e) => e['state'] == 'connected')
        .map((e) => e['heartRate'] as int? ?? 0)
        .where((v) => v > 0)
        .toList();
    latestHeartRate.value = values.isEmpty
        ? 0
        : (values.reduce((a, b) => a + b) / values.length).round();
  }

  Future<void> _flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_buffer.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();
    try {
      await VitaloopApi.ingestWatchData(
        eventsJson: jsonEncode({'events': batch}),
      );
      await _appState?.refresh();
    } catch (_) {}
  }

  Future<void> _loadHistory() async {
    try {
      final raw = await _method.invokeMethod<String>('history');
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      history.value = {for (final e in map.entries) e.key: '${e.value}'};
    } catch (_) {}
  }

  /// 体重页打开时先读一次已配对历史，避免 attach() 的异步加载还没完成就误判为“没有秤”。
  Future<void> refreshHistory() => _loadHistory();

  Future<bool> requestPermissions() async {
    try {
      return await _method.invokeMethod<bool>('request_permissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasPermissions() async {
    try {
      return await _method.invokeMethod<bool>('has_permissions') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startScan() async {
    await _ensureListen();
    try {
      final ok = await _method.invokeMethod<bool>('scan_start') ?? false;
      scanning.value = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopScan() async {
    try {
      await _method.invokeMethod('scan_stop');
    } catch (_) {}
    scanning.value = false;
  }

  Future<bool> connect(String address, String name) async {
    await _ensureListen();
    try {
      final ok =
          await _method.invokeMethod<bool>('connect', {
            'address': address,
            'name': name,
          }) ??
          false;
      if (ok) {
        final current = Map<String, Map<String, dynamic>>.from(devices.value);
        current[address] = {
          ...?current[address],
          'address': address,
          'name': name,
          'state': 'connecting',
        };
        devices.value = current;
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect(String address) async {
    try {
      await _method.invokeMethod('disconnect', {'address': address});
    } catch (_) {}
  }

  Future<void> forget(String address) async {
    try {
      await _method.invokeMethod('forget', {'address': address});
    } catch (_) {}
  }

  Future<void> _autoConnect() async {
    try {
      if (!await hasPermissions()) return;
      await _method.invokeMethod<bool>('connect_last');
    } catch (_) {}
  }

  /// 重新连接上次成功连接的设备；权限不足时返回 false，不弹系统授权框。
  Future<bool> connectLast() async {
    await _ensureListen();
    try {
      return await _method.invokeMethod<bool>('connect_last') ?? false;
    } catch (_) {
      return false;
    }
  }
}

const _scaleCompositionKeys = [
  'fatMassKg',
  'musclePercent',
  'muscleMassKg',
  'waterPercent',
  'waterMassKg',
  'proteinPercent',
  'proteinMassKg',
  'bonePercent',
  'boneMassKg',
  'skeletalMusclePercent',
  'skeletalMuscleMassKg',
  'subcutaneousFatPercent',
  'subcutaneousFatMassKg',
  'resistanceOhm',
  'heightCm',
];
