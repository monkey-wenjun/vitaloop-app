import 'dart:convert';

import 'package:flutter/services.dart';

import 'cloud.dart';

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppVersion {
  const AppVersion({required this.versionName, required this.versionCode});

  final String versionName;
  final int versionCode;

  String get label => '$versionName (build $versionCode)';
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.latestVersionCode,
    required this.downloadUrl,
    this.updateNotes = '',
    this.forceUpdate = false,
  });

  final String latestVersion;
  final int latestVersionCode;
  final String downloadUrl;
  final String updateNotes;
  final bool forceUpdate;
}

class AppUpdateResult {
  const AppUpdateResult({
    required this.ok,
    required this.message,
    this.versionName,
  });

  final bool ok;
  final String message;
  final String? versionName;
}

/// App 内更新：读取真实安装版本，检查服务端 app/config，再交给 Android
/// MethodChannel 下载、校验包名/签名/versionCode 并拉起系统安装器。
class AppUpdateClient {
  AppUpdateClient._();

  static const _channel = MethodChannel('vitaloop/update');
  static const _configPaths = ['/api/v1/app/config', '/v1/app/config'];

  static Future<AppVersion> currentVersion() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('info');
      final name = (info?['versionName'] as String?)?.trim();
      final code = (info?['versionCode'] as num?)?.toInt();
      return AppVersion(
        versionName: name?.isNotEmpty == true ? name! : '0.1.0',
        versionCode: code ?? 1,
      );
    } catch (_) {
      return const AppVersion(versionName: '0.1.0', versionCode: 1);
    }
  }

  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('can_install') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openInstallPermission() async {
    try {
      return await _channel.invokeMethod<bool>('open_install_permission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<AppUpdateResult> downloadAndInstall(String url) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'download_and_install',
        {'url': url},
      );
      return AppUpdateResult(
        ok: result?['ok'] == true,
        message: (result?['message'] as String?)?.trim().isNotEmpty == true
            ? result!['message'] as String
            : (result?['ok'] == true ? '已拉起系统安装器' : '更新失败'),
        versionName: (result?['versionName'] as String?)?.trim(),
      );
    } on PlatformException catch (e) {
      return AppUpdateResult(ok: false, message: e.message ?? '更新失败');
    } catch (_) {
      return const AppUpdateResult(ok: false, message: '更新失败');
    }
  }

  static Future<AppUpdateInfo?> check({
    required int currentVersionCode,
    required String currentVersionName,
    String? token,
  }) async {
    final tokens = <String?>[null];
    if (token != null && token.isNotEmpty) tokens.add(token);
    Object? lastError;
    for (final attemptToken in tokens) {
      for (final path in _configPaths) {
        try {
          final body = await CloudApi.appConfig(
            token: attemptToken,
            path: path,
          );
          return parseConfig(
            body,
            currentVersionCode: currentVersionCode,
            currentVersionName: currentVersionName,
          );
        } on CloudException catch (e) {
          lastError = e;
        } catch (e) {
          lastError = e;
        }
      }
    }
    if (lastError is CloudException) {
      final error = lastError;
      if (error.status == 401 || error.status == 403) {
        throw const AppUpdateException('当前服务需要登录账号后才能检查更新');
      }
      throw AppUpdateException(error.message);
    }
    throw AppUpdateException('检查更新失败：${lastError ?? "服务端没有返回配置"}');
  }

  static AppUpdateInfo? parseConfig(
    String body, {
    required int currentVersionCode,
    required String currentVersionName,
  }) {
    final config = _configMap(body);
    if (config == null) return null;

    final latestVersion = _string(
      config['latest_version'] ?? config['version_name'],
    );
    final latestCode = _int(
      config['latest_version_code'] ?? config['version_code'],
    );
    final downloadUrl = _resolveUrl(
      _string(config['download_url'] ?? config['apk_url']),
    );
    if (latestVersion.isEmpty && latestCode <= 0) return null;

    final newer = latestCode > 0
        ? latestCode > currentVersionCode
        : compareVersions(latestVersion, currentVersionName) > 0;
    if (!newer) return null;
    if (downloadUrl.isEmpty) {
      throw const AppUpdateException('服务端返回了新版本，但没有下载地址');
    }
    return AppUpdateInfo(
      latestVersion: latestVersion.isEmpty ? '$latestCode' : latestVersion,
      latestVersionCode: latestCode,
      downloadUrl: downloadUrl,
      updateNotes: _string(config['update_notes']),
      forceUpdate: _bool(config['force_update']),
    );
  }

  static int compareVersions(String a, String b) {
    final left = _versionParts(a);
    final right = _versionParts(b);
    final count = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < count; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  static List<int> _versionParts(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final parts = <int>[];
    for (final match in RegExp(r'\d+').allMatches(cleaned)) {
      parts.add(int.tryParse(match.group(0)!) ?? 0);
    }
    return parts;
  }

  static Map<String, dynamic>? _configMap(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const AppUpdateException('更新配置格式不正确');
    }
    final root = Map<String, dynamic>.from(decoded);
    final code = _int(root['code']);
    if (code != 0) {
      final message = _string(root['message'] ?? root['error']);
      throw AppUpdateException(message.isEmpty ? '服务端拒绝读取更新配置' : message);
    }
    var data = root['data'];
    if (data is String && data.trim().isNotEmpty) {
      data = jsonDecode(data);
    }
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final nested = map['config'];
      if (nested is Map) return Map<String, dynamic>.from(nested);
      return map;
    }
    if (root.containsKey('latest_version') ||
        root.containsKey('latest_version_code')) {
      return root;
    }
    return null;
  }

  static String _resolveUrl(String raw) {
    if (raw.isEmpty) return '';
    final parsed = Uri.tryParse(raw);
    if (parsed == null) return '';
    if (parsed.hasScheme) return parsed.toString();
    return Uri.parse(CloudApi.normalizeBase(CloudApi.base))
        .resolve(raw)
        .toString();
  }

  static String _string(Object? value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static int _int(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(_string(value)) ?? 0;
  }

  static bool _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return const {
      '1',
      'true',
      'yes',
      'on',
    }.contains(_string(value).toLowerCase());
  }
}
