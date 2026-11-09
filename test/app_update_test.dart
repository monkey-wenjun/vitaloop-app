import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/data/app_update.dart';
import 'package:vitaloop/data/cloud.dart';

void main() {
  test('解析裸 JSON 更新配置并识别新版本', () {
    final info = AppUpdateClient.parseConfig(
      jsonEncode({
        'latest_version': '0.2.0',
        'latest_version_code': 2,
        'download_url': 'https://example.com/vitaloop.apk',
        'update_notes': '修复同步问题',
        'force_update': true,
      }),
      currentVersionCode: 1,
      currentVersionName: '0.1.0',
    );

    expect(info, isNotNull);
    expect(info!.latestVersion, '0.2.0');
    expect(info.latestVersionCode, 2);
    expect(info.downloadUrl, 'https://example.com/vitaloop.apk');
    expect(info.updateNotes, '修复同步问题');
    expect(info.forceUpdate, isTrue);
  });

  test('兼容 code/data 包装、字符串 versionCode 和相对下载地址', () {
    final oldBase = CloudApi.base;
    CloudApi.base = 'https://vitaloop.example';
    addTearDown(() => CloudApi.base = oldBase);

    final info = AppUpdateClient.parseConfig(
      jsonEncode({
        'code': 0,
        'message': 'ok',
        'data': {
          'latest_version': 'v0.3.1',
          'latest_version_code': '3',
          'download_url': '/downloads/vitaloop-0.3.1.apk',
          'force_update': '1',
        },
      }),
      currentVersionCode: 2,
      currentVersionName: '0.3.0',
    );

    expect(info, isNotNull);
    expect(info!.latestVersionCode, 3);
    expect(
      info.downloadUrl,
      'https://vitaloop.example/downloads/vitaloop-0.3.1.apk',
    );
    expect(info.forceUpdate, isTrue);
  });

  test('同版本或旧版本不提示更新', () {
    expect(
      AppUpdateClient.parseConfig(
        jsonEncode({
          'latest_version': '0.1.0',
          'latest_version_code': 1,
          'download_url': 'https://example.com/vitaloop.apk',
        }),
        currentVersionCode: 1,
        currentVersionName: '0.1.0',
      ),
      isNull,
    );
  });

  test('版本号按数字段比较，不按字符串比较', () {
    expect(AppUpdateClient.compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(AppUpdateClient.compareVersions('v2.0', '2.0.0'), 0);
    expect(AppUpdateClient.compareVersions('1.0.1', '1.0.2'), lessThan(0));
  });

  test('服务端业务错误和缺少下载地址会给出明确异常', () {
    expect(
      () => AppUpdateClient.parseConfig(
        jsonEncode({'code': 9, 'message': '配置未开放'}),
        currentVersionCode: 1,
        currentVersionName: '0.1.0',
      ),
      throwsA(
        isA<AppUpdateException>().having((e) => e.message, 'message', '配置未开放'),
      ),
    );
    expect(
      () => AppUpdateClient.parseConfig(
        jsonEncode({'latest_version': '0.2.0', 'latest_version_code': 2}),
        currentVersionCode: 1,
        currentVersionName: '0.1.0',
      ),
      throwsA(isA<AppUpdateException>()),
    );
  });
}
