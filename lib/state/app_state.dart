import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/app_update.dart';
import '../data/cloud.dart';
import '../data/cloud_sync_policy.dart';
import '../data/locale_bridge.dart';
import '../data/workout_weather.dart';
import '../l10n/language_options.dart';
import '../src/rust/api/types.dart';

class AppState extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  String language = 'system';
  bool loading = true;
  String? error;
  String? accountEmail;
  bool signedIn = false;
  bool cloudBusy = false;
  String? cloudStatus;
  DateTime? cloudLastSync;
  String cloudServer = CloudApi.defaultBase;
  String? _cloudToken;
  int? _cloudChangeBase;
  Timer? _cloudTimer;
  static const _cloudSyncInterval = Duration(minutes: 1);

  HomeSummary? home;
  SleepSummary? sleep;
  List<WorkoutSummary> workouts = const [];
  List<DeviceInfo> devices = const [];
  Profile? profile;
  List<WeightEntry> weights = const [];
  List<BloodPressureEntry> bloodPressure = const [];
  List<GlucoseEntry> glucose = const [];
  List<ArrhythmiaEntry> arrhythmia = const [];
  WatchIdentity? watchIdentity;
  Goals? goals;
  int maxHr = 0;
  bool maxHrAuto = true;
  AppVersion appVersion = const AppVersion(
    versionName: '0.1.0',
    versionCode: 1,
  );
  AppUpdateInfo? availableUpdate;
  bool updateChecking = false;
  String? updateCheckError;
  Future<void>? _updateFuture;

  bool get hasDevice => devices.any((d) => d.connected);
  Locale? get localeOverride => switch (language) {
    'system' => null,
    _ => Locale(language),
  };
  DeviceInfo? get primaryDevice => devices.isEmpty
      ? null
      : devices.firstWhere((d) => d.connected, orElse: () => devices.first);

  Future<void> bootstrap() async {
    try {
      await VitaloopApi.bootstrap();
      // 迁移必须在 UI 首帧之前完成：锁屏、后台启动或 Shell 还没渲染时，
      // 仍然要把旧库里的新表补进来。
      await _importLegacyIfNeeded();
      final theme = await VitaloopApi.setting('theme', 'system');
      themeMode = switch (theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      final savedLanguage = await VitaloopApi.setting('language', 'system');
      language = languageOptionByCode(savedLanguage)?.code ?? 'system';
      unawaited(LocaleBridge.sync(language));
      // 默认离线直进：登录只是可选功能，不影响本地数据。
      accountEmail = await VitaloopApi.setting('account_email', '');
      _cloudToken = await VitaloopApi.setting('cloud_token', '');
      cloudServer = CloudApi.normalizeBase(
        await VitaloopApi.setting('cloud_server', CloudApi.defaultBase),
      );
      CloudApi.base = cloudServer;
      signedIn =
          (accountEmail?.isNotEmpty ?? false) &&
          (_cloudToken?.isNotEmpty ?? false);
      appVersion = await AppUpdateClient.currentVersion();
      final last = int.tryParse(
        await VitaloopApi.setting('cloud_last_sync_ms', ''),
      );
      cloudLastSync = last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last);
      await refresh();
      _cloudChangeBase = await VitaloopApi.accountDataChangeCount();
      if (signedIn) {
        final pending =
            await VitaloopApi.setting('cloud_pending_sync', '0') == '1';
        if (pending || cloudLastSync == null) {
          unawaited(
            _autoSyncCloud(mergeRemote: cloudLastSync == null, force: true),
          );
        }
      }
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final results = await Future.wait([
      VitaloopApi.home(),
      VitaloopApi.sleep(),
      VitaloopApi.workouts(limit: 500),
      VitaloopApi.devices(),
      VitaloopApi.profile(),
      VitaloopApi.weights(limit: 120),
      VitaloopApi.bloodPressure(limit: 200),
      VitaloopApi.glucose(limit: 200),
      VitaloopApi.arrhythmia(limit: 500),
      VitaloopApi.watchIdentity(),
      VitaloopApi.goals(),
      VitaloopApi.setting('max_hr', ''),
      VitaloopApi.setting('max_hr_auto', '1'),
    ]);
    home = results[0] as HomeSummary;
    sleep = results[1] as SleepSummary?;
    workouts = results[2] as List<WorkoutSummary>;
    devices = results[3] as List<DeviceInfo>;
    profile = results[4] as Profile;
    weights = results[5] as List<WeightEntry>;
    bloodPressure = results[6] as List<BloodPressureEntry>;
    glucose = results[7] as List<GlucoseEntry>;
    arrhythmia = results[8] as List<ArrhythmiaEntry>;
    watchIdentity = results[9] as WatchIdentity;
    goals = results[10] as Goals;
    maxHr = int.tryParse(results[11] as String) ?? 0;
    maxHrAuto = (results[12] as String) != '0';
    notifyListeners();
    unawaited(WorkoutWeatherService.backfill());
    _ensureCloudAutoSync();
  }

  /// 导入逻辑本身有增删时递增：版本号不一致会在回前台时自动重跑一次导入，
  /// 否则老库里新增的表永远不会被读进来。
  static const _legacyImportVersion = '18';
  bool _legacyImporting = false;

  Future<LegacyImportReport?> importLegacy() async {
    if (_legacyImporting) return null;
    if (!await VitaloopApi.legacyAvailable()) return null;
    _legacyImporting = true;
    try {
      final report = await VitaloopApi.importLegacy();
      await VitaloopApi.setSetting(
        'legacy_import_version',
        _legacyImportVersion,
      );
      await _rememberLegacyMtime();
      return report;
    } finally {
      _legacyImporting = false;
    }
  }

  Future<bool> _importLegacyIfNeeded() async {
    debugPrint(
      '[VitaloopLegacy] check import importing=$_legacyImporting '
      'path=${VitaloopApi.legacyDbPath}',
    );
    if (_legacyImporting) return false;
    try {
      final file = File(VitaloopApi.legacyDbPath);
      if (!file.existsSync()) {
        debugPrint('[VitaloopLegacy] skip: legacy db not found');
        return false;
      }
      final version = await VitaloopApi.setting('legacy_import_version', '');
      if (version != _legacyImportVersion) {
        debugPrint(
          '[VitaloopLegacy] import version $version -> $_legacyImportVersion',
        );
        final report = await importLegacy();
        debugPrint(
          '[VitaloopLegacy] import done ok=${report?.ok} '
          'already=${report?.alreadyImported} workouts=${report?.workouts} '
          'hr=${report?.heartRatePoints} weights=${report?.weights} '
          'bp=${report?.bloodPressure} glucose=${report?.glucose}',
        );
        return report != null;
      }
      final mtime = file.lastModifiedSync().millisecondsSinceEpoch.toString();
      final last = await VitaloopApi.setting('legacy_db_mtime', '');
      if (last == mtime) return false;
      debugPrint('[VitaloopLegacy] legacy db changed, re-import');
      final report = await importLegacy();
      return report != null;
    } catch (e, st) {
      // 自动导入失败时保留当前数据，等下次启动或回到前台再重试。
      debugPrint('[VitaloopLegacy] auto import failed: $e');
      debugPrint('$st');
      return false;
    }
  }

  /// 应用回到前台时，如果 legacy/ 下的旧版数据库被更新过，自动重新导入。
  Future<void> refreshFromLegacyIfNewer() async {
    if (await _importLegacyIfNeeded()) await refresh();
  }

  /// App 退到后台时只写一个待同步标记；真正的 85MB 快照留给前台/定时器，
  /// 避免系统把应用冻结在半次上传里。
  Future<void> noteLocalChanges() async {
    if (!signedIn || _cloudToken == null || _cloudToken!.isEmpty) return;
    try {
      final changes = await VitaloopApi.accountDataChangeCount();
      if (_cloudChangeBase == null || changes != _cloudChangeBase) {
        await VitaloopApi.setSetting('cloud_pending_sync', '1');
      }
    } catch (_) {}
  }

  Future<void> _rememberLegacyMtime() async {
    try {
      final file = File(VitaloopApi.legacyDbPath);
      if (file.existsSync()) {
        await VitaloopApi.setSetting(
          'legacy_db_mtime',
          file.lastModifiedSync().millisecondsSinceEpoch.toString(),
        );
      }
    } catch (_) {}
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    await VitaloopApi.setSetting('theme', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    });
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    if (languageOptionByCode(code) == null) return;
    language = code;
    await VitaloopApi.setSetting('language', code);
    await LocaleBridge.sync(code);
    notifyListeners();
  }

  Future<void> checkForUpdate() {
    final running = _updateFuture;
    if (running != null) return running;
    final future = _runUpdateCheck();
    _updateFuture = future;
    return future.whenComplete(() {
      if (identical(_updateFuture, future)) _updateFuture = null;
    });
  }

  Future<void> _runUpdateCheck() async {
    updateChecking = true;
    updateCheckError = null;
    notifyListeners();
    try {
      availableUpdate = await AppUpdateClient.check(
        currentVersionCode: appVersion.versionCode,
        currentVersionName: appVersion.versionName,
        token: _cloudToken,
      );
    } catch (e) {
      updateCheckError = e.toString();
    } finally {
      updateChecking = false;
      notifyListeners();
    }
  }

  Future<void> signIn(
    String email, {
    required String password,
    bool register = false,
  }) async {
    cloudBusy = true;
    cloudStatus = register ? '正在创建账号…' : '正在登录…';
    notifyListeners();
    try {
      final account = register
          ? await CloudApi.register(email, password)
          : await CloudApi.login(email, password);
      signedIn = true;
      accountEmail = account.email;
      _cloudToken = account.token;
      await VitaloopApi.setSetting('signed_in', '1');
      await VitaloopApi.setSetting('account_email', account.email);
      await VitaloopApi.setSetting('cloud_account_id', account.accountId);
      await VitaloopApi.setSetting('cloud_token', account.token);
      _ensureCloudAutoSync();
      await _syncCloudNow();
    } catch (e) {
      cloudStatus = e.toString();
      rethrow;
    } finally {
      cloudBusy = false;
      notifyListeners();
    }
    final current = profile ?? await VitaloopApi.profile();
    if (current.email.isEmpty) {
      await VitaloopApi.saveProfile(
        Profile(
          nickname: current.nickname.isEmpty
              ? _nickFromEmail(email)
              : current.nickname,
          gender: current.gender,
          heightCm: current.heightCm,
          weightKg: current.weightKg,
          birthDate: current.birthDate,
          email: email,
        ),
      );
      profile = await VitaloopApi.profile();
    }
  }

  Future<void> setCloudServer(String raw) async {
    cloudServer = CloudApi.normalizeBase(raw);
    CloudApi.base = cloudServer;
    await VitaloopApi.setSetting('cloud_server', cloudServer);
    notifyListeners();
  }

  Future<void> continueAsGuest() async {
    _stopCloudAutoSync();
    signedIn = false;
    accountEmail = null;
    _cloudToken = null;
    await VitaloopApi.setSetting('signed_in', '0');
    await VitaloopApi.setSetting('guest', '1');
    await VitaloopApi.setSetting('account_email', '');
    await VitaloopApi.setSetting('cloud_token', '');
    notifyListeners();
  }

  Future<void> signOut() async {
    _stopCloudAutoSync();
    signedIn = false;
    accountEmail = null;
    _cloudToken = null;
    await VitaloopApi.setSetting('signed_in', '0');
    await VitaloopApi.setSetting('account_email', '');
    await VitaloopApi.setSetting('cloud_token', '');
    notifyListeners();
  }

  Future<void> _autoSyncCloud({
    bool mergeRemote = false,
    bool force = false,
  }) async {
    if (!signedIn ||
        _cloudToken == null ||
        _cloudToken!.isEmpty ||
        CloudApi.base.isEmpty) {
      return;
    }
    if (cloudBusy) return;
    if (!force && !mergeRemote) {
      try {
        final changes = await VitaloopApi.accountDataChangeCount();
        if (_cloudChangeBase != null && changes == _cloudChangeBase) {
          if (cloudStatus != '云端已同步') {
            cloudStatus = '云端已同步';
            notifyListeners();
          }
          return;
        }
      } catch (_) {
        // 计数读不到时宁可做一次同步，也不要静默丢掉本地新数据。
      }
    }
    cloudBusy = true;
    cloudStatus = mergeRemote ? '正在同步云端…' : '正在上传…';
    notifyListeners();
    try {
      await _syncCloudNow(mergeRemote: mergeRemote);
      cloudStatus = '云端已同步';
    } catch (e) {
      cloudStatus = e.toString();
    } finally {
      cloudBusy = false;
      try {
        _cloudChangeBase = await VitaloopApi.accountDataChangeCount();
      } catch (_) {}
      notifyListeners();
    }
  }

  void _ensureCloudAutoSync() {
    if (!signedIn ||
        _cloudToken == null ||
        _cloudToken!.isEmpty ||
        CloudApi.base.isEmpty) {
      _stopCloudAutoSync();
      return;
    }
    if (_cloudTimer?.isActive ?? false) return;
    _cloudTimer?.cancel();
    _cloudTimer = Timer.periodic(_cloudSyncInterval, (_) {
      unawaited(_autoSyncCloud());
    });
  }

  void _stopCloudAutoSync() {
    _cloudTimer?.cancel();
    _cloudTimer = null;
  }

  Future<void> _syncCloudNow({bool mergeRemote = true}) async {
    final token = _cloudToken;
    if (token == null || token.isEmpty) return;
    final sw = Stopwatch()..start();
    debugPrint('[cloud] sync start mergeRemote=$mergeRemote');
    if (mergeRemote) {
      // 登录/首次同步时先把云端已有数据合并回本机，再上传本机并集；
      // 定时同步只上传本地新增，不能每分钟重拉 85MB 把 UI 拖死。
      final remote = await CloudApi.download(token);
      debugPrint(
        '[cloud] download done ${sw.elapsedMilliseconds}ms remote=${remote?.length}',
      );
      if (remote != null) {
        await VitaloopApi.importAccountData(payload: remote);
      }
      debugPrint('[cloud] import done ${sw.elapsedMilliseconds}ms');
      await refresh();
      debugPrint('[cloud] refresh done ${sw.elapsedMilliseconds}ms');
    }
    final rawSeq = await VitaloopApi.setting('cloud_sync_seq', '');
    final sinceSeq = int.tryParse(rawSeq) ?? 0;
    // 老版本只做过全量同步，没有增量游标；升级后先补一次全量基线，
    // 否则升级前最后几笔本地改动不在变更日志里，会永远传不上去。
    if (mergeRemote || rawSeq.isEmpty) {
      await _uploadFullSnapshot(token, sw);
    } else {
      try {
        await _uploadDelta(token, sinceSeq, sw);
      } on CloudException catch (e) {
        // 旧服务端还没有增量接口（或账号快照缺失）时退回一次全量，
        // 之后仍然按增量走。
        if (e.status != 409 && e.status != 404) rethrow;
        debugPrint('[cloud] delta rejected (${e.status}), full fallback');
        await _uploadFullSnapshot(token, sw);
      }
    }
    debugPrint('[cloud] upload done ${sw.elapsedMilliseconds}ms');
    final now = DateTime.now();
    cloudLastSync = now;
    cloudStatus = '云端已同步';
    await VitaloopApi.setSetting(
      'cloud_last_sync_ms',
      now.millisecondsSinceEpoch.toString(),
    );
    await VitaloopApi.setSetting('cloud_pending_sync', '0');
    _cloudChangeBase = await VitaloopApi.accountDataChangeCount();
  }

  Future<void> _uploadFullSnapshot(String token, Stopwatch sw) async {
    // 先记游标再导出：导出/上传期间新写入的行不会被这次 clear 掉。
    final seq = await VitaloopApi.accountDeltaMaxSeq();
    final snapshot = await VitaloopApi.exportAccountData();
    debugPrint(
      '[cloud] full export done ${sw.elapsedMilliseconds}ms bytes=${snapshot.length}',
    );
    await CloudApi.upload(token, snapshot);
    await VitaloopApi.clearAccountDelta(throughSeq: seq);
    await VitaloopApi.setSetting('cloud_sync_seq', seq.toString());
  }

  Future<void> _uploadDelta(String token, int sinceSeq, Stopwatch sw) async {
    var cursor = sinceSeq;
    // 一次只处理有限条变更，既能把单次 JSON / HTTP 包压小，也能把 CPU 和
    // 网络时间切片，避免同步期间滑动掉帧。剩余变更下一轮继续。
    const maxEntries = 1500;
    const maxRounds = 4;
    for (var round = 0; round < maxRounds; round++) {
      final latest = await VitaloopApi.accountDeltaMaxSeq();
      if (latest <= cursor) break;
      final pendingEntries = latest - cursor;
      if (shouldUploadFullSnapshot(pendingEntries: pendingEntries)) {
        debugPrint(
          '[cloud] delta backlog=$pendingEntries, full snapshot fallback',
        );
        await _uploadFullSnapshot(token, sw);
        return;
      }
      final delta = await VitaloopApi.exportAccountDeltaLimited(
        sinceSeq: cursor,
        maxEntries: maxEntries,
      );
      // 只取游标，不在 Dart UI 线程上 jsonDecode 整包（大包会有明显卡顿）。
      final match = RegExp(r'"max_seq":(\d+)').firstMatch(delta);
      final deltaMax = int.tryParse(match?.group(1) ?? '') ?? cursor;
      if (shouldUploadFullSnapshot(
        pendingEntries: pendingEntries,
        deltaChars: delta.length,
      )) {
        debugPrint(
          '[cloud] delta too large chars=${delta.length}, '
          'full snapshot fallback',
        );
        await _uploadFullSnapshot(token, sw);
        return;
      }
      if (deltaMax <= cursor || delta.contains('"tables":{}')) {
        if (deltaMax > cursor) {
          await VitaloopApi.clearAccountDelta(throughSeq: deltaMax);
          await VitaloopApi.setSetting('cloud_sync_seq', deltaMax.toString());
        }
        break;
      }
      debugPrint(
        '[cloud] delta chunk ${round + 1} ${sw.elapsedMilliseconds}ms '
        'bytes=${delta.length} seq=$cursor..$deltaMax',
      );
      await CloudApi.uploadDelta(token, delta);
      await VitaloopApi.clearAccountDelta(throughSeq: deltaMax);
      await VitaloopApi.setSetting('cloud_sync_seq', deltaMax.toString());
      cursor = deltaMax;
      if (round + 1 < maxRounds) {
        // 给 UI 和网络栈留一口气，不要连续满速打满。
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> saveProfile(Profile next) async {
    await VitaloopApi.saveProfile(next);
    profile = next;
    notifyListeners();
  }

  static String _nickFromEmail(String email) {
    final local = email.split('@').first.replaceAll(RegExp(r'[._-]+'), ' ');
    if (local.isEmpty) return '跑者';
    return local[0].toUpperCase() + local.substring(1);
  }
}
