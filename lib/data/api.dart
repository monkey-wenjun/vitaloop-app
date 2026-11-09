import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../src/rust/api/health.dart' as rust;
import '../src/rust/api/navigation.dart' as nav;
import '../src/rust/api/types.dart';
import '../src/rust/frb_generated.dart';

class VitaloopApi {
  static const _legacyChannel = MethodChannel('vitaloop/legacy');
  static bool _ready = false;
  static final Completer<void> _readyCompleter = Completer<void>();
  static String? _supportDir;
  static String? _legacyDir;
  static String? _externalLegacyDir;

  /// 原生保活服务和 UI 都可能在 bootstrap 结束前发起手表连接；
  /// 等这里完成后再读 Rust 里的认证身份，避免抢跑成 firstConnection。
  static Future<void> get readyFuture => _readyCompleter.future;

  static Future<AppInfo> bootstrap({bool seedDemo = false}) async {
    try {
      await RustLib.init();
      await _resolveLegacyDir();
      final dir = Directory(_supportDir!);
      final info = await rust.bootstrap(
        dbPath: p.join(dir.path, 'vitaloop.db'),
        seedDemoIfEmpty: seedDemo,
      );
      await _backfillLegacyWatchIdentity();
      _ready = true;
      return info;
    } finally {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  /// 自动导入只扫描内部 support/legacy；外部 legacy 目录里的 device_prefs.xml
  /// 可能还没被搬进去。这里只补手表身份，避免为了一个 authkey 重跑全量迁移。
  static Future<void> _backfillLegacyWatchIdentity() async {
    try {
      final current = await rust.getWatchIdentity();
      debugPrint(
        '[VitaloopLegacy] backfill start authKeyLen=${current.authKey.length} '
        'legacyDir=$_legacyDir external=$_externalLegacyDir',
      );
      if (current.authKey.isNotEmpty) {
        debugPrint('[VitaloopLegacy] skip: authKey already set');
        return;
      }
      final dir = _legacyDir ?? p.join(supportDir, 'legacy');
      String read(String name) {
        final paths = <String>[p.join(dir, name)];
        final external = _externalLegacyDir;
        if (external != null && external != dir) {
          paths.add(p.join(external, name));
        }
        for (final path in paths) {
          try {
            final file = File(path);
            if (!file.existsSync()) {
              debugPrint('[VitaloopLegacy] missing $path');
              continue;
            }
            final text = file.readAsStringSync();
            debugPrint(
              '[VitaloopLegacy] read $name from $path len=${text.length}',
            );
            return text;
          } catch (e) {
            debugPrint('[VitaloopLegacy] read $name from $path failed: $e');
          }
        }
        return '';
      }

      final devicePrefs = read('device_prefs.xml');
      if (devicePrefs.trim().isEmpty) {
        debugPrint('[VitaloopLegacy] abort: device_prefs.xml empty');
        return;
      }
      final config = jsonDecode(
        await rust.buildLegacyConfig(
          devicePrefsXml: devicePrefs,
          globalPrefsXml: read('prefs.xml'),
          profileXml: '',
          goalsXml: '',
          heartXml: '',
          ephemerisXml: read('ephemeris_prefs.xml'),
        ),
      ) as Map<String, dynamic>;
      final watch = config['watch'] as Map<String, dynamic>? ?? const {};
      final authKey = (watch['auth_key'] as String? ?? '').trim();
      debugPrint(
        '[VitaloopLegacy] parsed watch keys=${watch.keys.join(",")} '
        'authKeyLen=${authKey.length} '
        'fakeAndroidIdLen=${(watch['fake_android_id'] as String? ?? '').length}',
      );
      if (authKey.isEmpty) {
        debugPrint('[VitaloopLegacy] abort: parsed auth_key empty');
        return;
      }
      final address = (watch['address'] as String? ?? '').trim();
      final name = (watch['name'] as String? ?? '').trim();
      final lastSync = watch['last_sync_ms'];
      await rust.saveWatchIdentity(
        identity: WatchIdentity(
          address: address.isEmpty ? current.address : address,
          name: name.isEmpty ? current.name : name,
          account: (watch['account'] as String? ?? '').trim(),
          authKey: authKey,
          fakeAndroidId: (watch['fake_android_id'] as String? ?? '').trim(),
          huaweiAddress: (watch['huawei_address'] as String? ?? '').trim(),
          lastSyncMs: lastSync is num ? lastSync.toInt() : current.lastSyncMs,
          migrated: true,
          ephemerisUrl: (watch['ephemeris_url'] as String? ?? '').trim().isEmpty
              ? current.ephemerisUrl
              : (watch['ephemeris_url'] as String? ?? '').trim(),
        ),
      );
      final saved = await rust.getWatchIdentity();
      debugPrint(
        '[VitaloopLegacy] saved authKeyLen=${saved.authKey.length} '
        'account=${saved.account.isNotEmpty}',
      );
    } catch (e, st) {
      debugPrint('[VitaloopLegacy] backfill failed: $e');
      debugPrint('$st');
    }
  }

  /// release 包没有 root/run-as，内部 files/ 写不进去。旧版数据库允许放在
  /// 应用外部目录；内部目录存在时仍优先用内部。用户通过系统文件选择器导入时，
  /// 原生层会把文件复制到内部 legacy/，所以这里需要能重新解析一次。
  static Future<void> _resolveLegacyDir() async {
    final dir = await getApplicationSupportDirectory();
    _supportDir = dir.path;
    final internalLegacy = Directory(p.join(dir.path, 'legacy'));
    final external = await getExternalStorageDirectory();
    final externalLegacy = external == null
        ? null
        : Directory(p.join(external.path, 'legacy'));
    _externalLegacyDir = externalLegacy?.path;
    if (File(p.join(internalLegacy.path, 'health_sync.db')).existsSync()) {
      _legacyDir = internalLegacy.path;
    } else if (externalLegacy != null &&
        File(p.join(externalLegacy.path, 'health_sync.db')).existsSync()) {
      _legacyDir = externalLegacy.path;
    } else {
      _legacyDir = internalLegacy.path;
    }
  }

  static bool get ready => _ready;

  static String get supportDir => _supportDir ?? '';

  static String get legacyDbPath =>
      p.join(_legacyDir ?? p.join(supportDir, 'legacy'), 'health_sync.db');

  static Future<bool> legacyAvailable() async {
    if (supportDir.isEmpty) return false;
    return rust.legacyDbAvailable(path: legacyDbPath);
  }

  /// 系统文件选择器：把 health_sync.db / XML 复制进应用内部 legacy/。
  /// 返回实际复制的文件名；用户取消时返回空列表。
  static Future<List<String>> pickLegacyFiles() async {
    final raw = await _legacyChannel.invokeMethod<List<dynamic>>('pick_files');
    final names = raw?.map((e) => '$e').toList() ?? const <String>[];
    if (names.isNotEmpty) await _resolveLegacyDir();
    return names;
  }

  /// 从应用目录 `legacy/` 下的旧版数据库与 XML 配置导入。
  static Future<LegacyImportReport> importLegacy() async {
    final dir = _legacyDir ?? p.join(supportDir, 'legacy');
    String read(String name) {
      final primary = File(p.join(dir, name));
      if (primary.existsSync()) return primary.readAsStringSync();
      final external = _externalLegacyDir;
      if (external != null && external != dir) {
        final fallback = File(p.join(external, name));
        if (fallback.existsSync()) return fallback.readAsStringSync();
      }
      return '';
    }

    final config = await rust.buildLegacyConfig(
      devicePrefsXml: read('device_prefs.xml'),
      globalPrefsXml: read('prefs.xml'),
      profileXml: read('user_profile_settings.xml'),
      goalsXml: read('activity_goals.xml'),
      heartXml: read('heart_rate_settings.xml'),
      ephemerisXml: read('ephemeris_prefs.xml'),
    );
    final report = await rust.importLegacyData(
      dbPath: legacyDbPath,
      configJson: config,
    );
    await _importLegacyGear(read('GearPrefs.xml'));
    return report;
  }

  /// 旧版装备存在 SharedPreferences 的 GearPrefs.xml，不在 Room 数据库。
  /// 按旧 UUID 记录已导入项；用户之后删掉装备，不会被下一次迁移重新加回来。
  static Future<int> _importLegacyGear(String xml) async {
    if (xml.trim().isEmpty) return 0;
    final match = RegExp(
      r'<string\s+name="gears"\s*>([\s\S]*?)</string>',
      caseSensitive: false,
    ).firstMatch(xml);
    if (match == null) return 0;

    late final List<dynamic> rows;
    try {
      rows = jsonDecode(_xmlText(match.group(1) ?? '')) as List<dynamic>;
    } catch (_) {
      return 0;
    }

    final seenRaw = await setting('legacy_gear_seen_ids', '[]');
    final seen = <String>{};
    try {
      seen.addAll((jsonDecode(seenRaw) as List<dynamic>).map((e) => '$e'));
    } catch (_) {}

    final existing = await equipment();
    final existingKeys = {
      for (final e in existing) '${e.name}|${e.gearType}|${e.brand}|${e.model}',
    };
    final imported = <String>[];
    var count = 0;

    for (final raw in rows) {
      if (raw is! Map<String, dynamic>) continue;
      final legacyId = (raw['id'] as String? ?? '').trim();
      if (legacyId.isEmpty || seen.contains(legacyId)) continue;
      final oldType = (raw['type'] as String? ?? 'BIKE').toUpperCase();
      final gearType = switch (oldType) {
        'SHOES' => 'shoes',
        'JERSEY' => 'jersey',
        'SHORTS' => 'shorts',
        'BIKE' => 'bike',
        'HEART_RATE_STRAP' => 'hr_strap',
        'WATCH' => 'watch',
        'HELMET' => 'helmet',
        'GLOVES' => 'gloves',
        'GLASSES' => 'glasses',
        _ => 'bike',
      };
      final brand = (raw['brand'] as String? ?? '').trim();
      final model = (raw['model'] as String? ?? '').trim();
      final name =
          [
            brand,
            model,
          ].where((part) => part.isNotEmpty).join(' ').trim().isEmpty
          ? _gearLabel(gearType)
          : [brand, model].where((part) => part.isNotEmpty).join(' ');
      final key = '$name|$gearType|$brand|$model';
      if (existingKeys.contains(key)) {
        imported.add(legacyId);
        continue;
      }
      final sport = switch (gearType) {
        'shoes' => 'outdoor_run',
        'bike' || 'jersey' || 'shorts' => 'cycling',
        _ => 'other',
      };
      final limitKm = switch (gearType) {
        'shoes' => 800.0,
        'bike' => 5000.0,
        _ => 1000.0,
      };
      final purchase = DateTime.tryParse(raw['purchaseDate'] as String? ?? '');
      try {
        await addEquipment(
          name: name,
          sport: sport,
          gearType: gearType,
          brand: brand,
          model: model,
          purchaseMs: purchase?.millisecondsSinceEpoch ?? 0,
          isActive: raw['isActive'] as bool? ?? true,
          startKm: 0,
          limitKm: limitKm,
          note: (raw['notes'] as String? ?? '').trim(),
        );
        imported.add(legacyId);
        count++;
      } catch (_) {
        // 单件装备字段异常时跳过错，不影响数据库与其它装备迁移。
      }
    }

    seen.addAll(imported);
    await setSetting('legacy_gear_seen_ids', jsonEncode(seen.toList()..sort()));
    return count;
  }

  static String _gearLabel(String type) => switch (type) {
    'shoes' => '旧版跑鞋',
    'jersey' => '旧版骑行服',
    'shorts' => '旧版骑行裤',
    'bike' => '旧版自行车',
    'hr_strap' => '旧版心率带',
    'watch' => '旧版手表',
    'helmet' => '旧版头盔',
    'gloves' => '旧版手套',
    'glasses' => '旧版眼镜',
    _ => '旧版装备',
  };

  static String _xmlText(String raw) => raw.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-fA-F]+|amp|lt|gt|quot|apos);'),
    (m) {
      final entity = m.group(1) ?? '';
      return switch (entity) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        _ => String.fromCharCode(
          entity.startsWith('#x') || entity.startsWith('#X')
              ? int.tryParse(entity.substring(2), radix: 16) ?? 0
              : int.tryParse(entity.substring(1)) ?? 0,
        ),
      };
    },
  );

  static int today() =>
      DateTime.now().toLocal().difference(DateTime(1970)).inDays;

  static Future<HomeSummary> home({int? day}) =>
      rust.getHomeSummary(day: day ?? 0);

  static Future<ReadinessDetail> readinessDetail({int? day}) =>
      rust.getReadinessDetail(day: day ?? 0);

  static Future<List<DailyPoint>> readinessSeries(int days) =>
      rust.getReadinessSeries(days: days);

  static Future<List<DailyPoint>> metricSeries(String metric, int days) =>
      rust.getMetricSeries(metric: metric, days: days);

  static Future<MetricDetail> metricDetail(String metric, {int days = 30}) =>
      rust.getMetricDetail(metric: metric, days: days);

  static Future<List<MetricDay>> metricDays(int fromDay, int toDay) =>
      rust.getMetricDays(fromDay: fromDay, toDay: toDay);

  static Future<SleepSummary?> sleep({int? day}) =>
      rust.getSleepSummary(day: day ?? 0);

  static Future<SleepDetail?> sleepDetail({int? day}) =>
      rust.getSleepDetail(day: day ?? 0);

  static Future<List<WorkoutSummary>> workouts({
    String filter = 'all',
    int limit = 100,
  }) => rust.listWorkouts(filter: filter, limit: limit);

  static Future<List<StrengthExercise>> strengthExercises() =>
      rust.listStrengthExercises();

  static Future<int> addStrengthExercise({
    required String name,
    required String muscleGroup,
    required String equipment,
  }) async => (await rust.addStrengthExercise(
    name: name,
    muscleGroup: muscleGroup,
    equipment: equipment,
  )).toInt();

  static Future<List<StrengthTemplate>> strengthTemplates() =>
      rust.listStrengthTemplates();

  static Future<int> saveStrengthTemplate({
    int id = 0,
    required String name,
    String notes = '',
    required List<StrengthTemplateExerciseInput> exercises,
  }) async => (await rust.saveStrengthTemplate(
    id: id,
    name: name,
    notes: notes,
    exercises: exercises,
  )).toInt();

  static Future<void> deleteStrengthTemplate(int id) =>
      rust.deleteStrengthTemplate(id: id);

  static Future<void> saveStrengthSets(
    String sessionId,
    List<StrengthSetInput> sets,
  ) => rust.saveStrengthSets(sessionId: sessionId, sets: sets);

  static Future<List<StrengthSet>> strengthSets(String sessionId) =>
      rust.listStrengthSets(sessionId: sessionId);

  static Future<List<ApneaRecord>> apneaRecords({int limit = 60}) =>
      rust.listApneaRecords(limit: limit);

  static Future<List<ApneaRecord>> apneaForDay(int day) =>
      rust.apneaRecordsForDay(day: day);

  static Future<List<HourlyStatusPoint>> hourlyStatus(int day) =>
      rust.listHourlyStatus(day: day);

  static Future<List<DailyRing>> dailyRings({int limit = 30}) =>
      rust.listDailyRings(limit: limit);

  static Future<DailyRing?> dailyRing(int day) => rust.getDailyRing(day: day);

  static Future<List<SavedRoute>> savedRoutes() => rust.listSavedRoutes();

  static Future<String> saveRoute({
    String id = '',
    required String name,
    required List<GeoPoint> points,
  }) => rust.saveSavedRoute(id: id, name: name, points: points);

  static Future<void> deleteRoute(String id) => rust.deleteSavedRoute(id: id);

  static Future<List<RunningIndexPoint>> runningIndex({int limit = 100}) =>
      rust.getRunningIndexHistory(limit: limit);

  static Future<WorkoutDetail?> workout(String id) => rust.getWorkout(id: id);

  static Future<void> deleteWorkout(String id) => rust.deleteWorkout(id: id);

  static Future<String> saveManualWorkout({
    required String sport,
    required int startMs,
    required int durationSec,
    double distanceM = 0,
    int calories = 0,
    int avgHr = 0,
    int maxHr = 0,
    String trackJson = '',
  }) => rust.saveManualWorkout(
    sport: sport,
    startMs: startMs,
    durationSec: durationSec,
    distanceM: distanceM,
    calories: calories,
    avgHr: avgHr,
    maxHr: maxHr,
    trackJson: trackJson,
  );

  static Future<String> gpx(String id) => rust.exportWorkoutGpx(id: id);

  static Future<String> tcx(String id) => rust.exportWorkoutTcx(id: id);

  /// 手机骑行没有功率计，按速度、坡度和体重估算实时功率。
  static double cyclingPowerWatts({
    required double speedKmh,
    required double gradientPercent,
    required double riderWeightKg,
    double bikeWeightKg = 10,
  }) => rust.cyclingPowerWatts(
    speedKmh: speedKmh,
    gradientPercent: gradientPercent,
    riderWeightKg: riderWeightKg,
    bikeWeightKg: bikeWeightKg,
  );

  /// 骑行结束后按轨迹补齐功率曲线、NP、FTP、IF 和 TSS。
  static Future<String?> analyzeCyclingWorkout(
    String id, {
    required double riderWeightKg,
    double bikeWeightKg = 10,
  }) => rust.analyzeCyclingWorkout(
    id: id,
    riderWeightKg: riderWeightKg,
    bikeWeightKg: bikeWeightKg,
  );

  /// 根据保存路线折线给出转向、剩余距离和偏航状态，返回 JSON。
  static Future<String> routeGuidance({
    required String routeJson,
    required double lat,
    required double lon,
    double arrivalRadiusM = 25,
  }) => nav.routeGuidance(
    routeJson: routeJson,
    lat: lat,
    lon: lon,
    arrivalRadiusM: arrivalRadiusM,
  );

  static Future<void> saveWorkoutRecovery(String id, String recoveryJson) =>
      rust.saveWorkoutRecovery(id: id, recoveryJson: recoveryJson);

  static Future<void> setWorkoutWeather(
    String id, {
    double? tempC,
    int? humidity,
  }) => rust.setWorkoutWeather(id: id, tempC: tempC, humidity: humidity);

  static Future<List<WorkoutWeatherCandidate>> missingWorkoutWeather({
    int limit = 8,
  }) => rust.workoutsMissingWeather(limit: limit);

  static Future<String> addWeightRecord({
    required double weightKg,
    double bodyFatPercent = 0,
  }) =>
      rust.addWeightRecord(weightKg: weightKg, bodyFatPercent: bodyFatPercent);

  static Future<String> addBloodPressure({
    required int systolic,
    required int diastolic,
    int pulse = 0,
  }) => rust.addBloodPressure(
    systolic: systolic,
    diastolic: diastolic,
    pulse: pulse,
  );

  static Future<String> addBloodGlucose({
    required double value,
    String measureType = 'random',
  }) => rust.addBloodGlucose(value: value, measureType: measureType);

  static Future<void> updateWeightRecord({
    required String id,
    required double weightKg,
    double bodyFatPercent = 0,
  }) => rust.updateWeightRecord(
    id: id,
    weightKg: weightKg,
    bodyFatPercent: bodyFatPercent,
  );

  static Future<void> deleteWeightRecord(String id) =>
      rust.deleteWeightRecord(id: id);

  static Future<void> updateBloodPressure({
    required String id,
    required int systolic,
    required int diastolic,
    int pulse = 0,
  }) => rust.updateBloodPressure(
    id: id,
    systolic: systolic,
    diastolic: diastolic,
    pulse: pulse,
  );

  static Future<void> deleteBloodPressure(String id) =>
      rust.deleteBloodPressure(id: id);

  static Future<void> updateBloodGlucose({
    required String id,
    required double value,
    String measureType = 'random',
  }) => rust.updateBloodGlucose(id: id, value: value, measureType: measureType);

  static Future<void> deleteBloodGlucose(String id) =>
      rust.deleteBloodGlucose(id: id);

  static Future<List<HrPoint>> heartRate(int day) =>
      rust.getHeartRateSeries(day: day);

  static Future<HrvMetrics> calculateHrv(List<int> rrIntervals) =>
      rust.calculateHrv(rrIntervals: Int64List.fromList(rrIntervals));

  static Future<Profile> profile() => rust.getProfile();

  static Future<void> saveProfile(Profile profile) =>
      rust.saveProfile(profile: profile);

  static Future<List<DeviceInfo>> devices() => rust.listDevices();

  static Future<List<WeightEntry>> weights({int limit = 60}) =>
      rust.listWeights(limit: limit);

  static Future<List<Equipment>> equipment() => rust.listEquipment();

  static Future<void> addEquipment({
    required String name,
    required String sport,
    String gearType = 'shoes',
    String brand = '',
    String model = '',
    int purchaseMs = 0,
    bool isActive = true,
    required double startKm,
    required double limitKm,
    required String note,
  }) => rust.addEquipment(
    name: name,
    sport: sport,
    gearType: gearType,
    brand: brand,
    model: model,
    purchaseMs: purchaseMs,
    isActive: isActive,
    startKm: startKm,
    limitKm: limitKm,
    note: note,
  );

  static Future<void> updateEquipment({
    required int id,
    required String name,
    required String sport,
    String gearType = 'shoes',
    String brand = '',
    String model = '',
    int purchaseMs = 0,
    bool isActive = true,
    required double startKm,
    required double limitKm,
    required String note,
  }) => rust.updateEquipment(
    id: id,
    name: name,
    sport: sport,
    gearType: gearType,
    brand: brand,
    model: model,
    purchaseMs: purchaseMs,
    isActive: isActive,
    startKm: startKm,
    limitKm: limitKm,
    note: note,
  );

  static Future<void> deleteEquipment(int id) => rust.deleteEquipment(id: id);

  static Future<List<PersonalRecord>> personalRecords() =>
      rust.getPersonalRecords();

  static Future<List<BloodPressureEntry>> bloodPressure({int limit = 100}) =>
      rust.getBloodPressureRecords(limit: limit);

  static Future<List<GlucoseEntry>> glucose({int limit = 100}) =>
      rust.getGlucoseRecords(limit: limit);

  static Future<List<ArrhythmiaEntry>> arrhythmia({int limit = 500}) =>
      rust.getArrhythmiaRecords(limit: limit);

  static Future<WatchIdentity> watchIdentity() => rust.getWatchIdentity();

  static Future<List<WatchLog>> watchLogs({int limit = 500}) =>
      rust.getWatchLogs(limit: limit);

  static Future<void> saveWatchIdentity(WatchIdentity identity) =>
      rust.saveWatchIdentity(identity: identity);

  static Future<Goals> goals() => rust.getGoals();

  static Future<void> saveGoals(Goals goals) => rust.saveGoals(goals: goals);

  static Future<String> setting(String key, [String fallback = '']) =>
      rust.getSetting(key: key, fallback: fallback);

  static Future<void> setSetting(String key, String value) =>
      rust.setSetting(key: key, value: value);

  static Future<String> ingestWatchData({required String eventsJson}) =>
      rust.ingestWatchData(eventsJson: eventsJson);

  static Future<String> exportAccountData() => rust.exportAccountData();

  static Future<int> importAccountData({required String payload}) async =>
      (await rust.importAccountData(payload: payload)).toInt();

  static Future<String> exportAccountDelta({required int sinceSeq}) =>
      rust.exportAccountDelta(sinceSeq: sinceSeq);

  static Future<String> exportAccountDeltaLimited({
    required int sinceSeq,
    required int maxEntries,
  }) => rust.exportAccountDeltaLimited(
    sinceSeq: sinceSeq,
    maxEntries: maxEntries,
  );

  static Future<int> accountDeltaMaxSeq() async =>
      (await rust.accountDeltaMaxSeq()).toInt();

  static Future<int> clearAccountDelta({required int throughSeq}) async =>
      (await rust.clearAccountDelta(throughSeq: throughSeq)).toInt();

  static Future<int> localDataCount() async =>
      (await rust.localDataCount()).toInt();

  static Future<int> accountDataChangeCount() async =>
      (await rust.accountDataChangeCount()).toInt();

  static Future<void> seedDemo() => rust.seedDemoData();

  static Future<void> clearDemo() => rust.clearDemoData();
}
