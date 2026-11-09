import 'dart:convert';

import 'package:flutter/services.dart';

/// 系统运行时权限状态。文件导入导出走系统文件选择器，不需要额外申请存储权限。
class PermissionSnapshot {
  const PermissionSnapshot({
    required this.location,
    required this.backgroundLocation,
    required this.bluetooth,
    required this.notifications,
    this.batteryOptimization = false,
    this.phone = false,
    this.answerCalls = false,
  });

  final bool location;
  final bool backgroundLocation;
  final bool bluetooth;
  final bool notifications;
  final bool batteryOptimization;
  final bool phone;
  final bool answerCalls;

  bool get allGranted =>
      location && backgroundLocation && bluetooth && notifications;

  factory PermissionSnapshot.fromJson(Map<String, dynamic> json) =>
      PermissionSnapshot(
        location: json['location'] == true,
        backgroundLocation: json['background_location'] == true,
        bluetooth: json['bluetooth'] == true,
        notifications: json['notifications'] == true,
        batteryOptimization: json['battery_optimization'] == true,
        phone: json['phone'] == true,
        answerCalls: json['answer_calls'] == true,
      );
}

class PermissionBridge {
  PermissionBridge._();

  static final PermissionBridge instance = PermissionBridge._();

  static const _method = MethodChannel('vitaloop/permissions');

  Future<PermissionSnapshot> status() async {
    try {
      final raw = await _method.invokeMethod<String>('status');
      return _parse(raw);
    } catch (_) {
      return const PermissionSnapshot(
        location: false,
        backgroundLocation: false,
        bluetooth: false,
        notifications: false,
      );
    }
  }

  /// 一次申请前台定位、蓝牙和通知。后台定位在 Android 10+ 必须单独申请。
  Future<PermissionSnapshot> request() async {
    try {
      final raw = await _method.invokeMethod<String>('request');
      return _parse(raw);
    } catch (_) {
      return status();
    }
  }

  Future<PermissionSnapshot> requestBackgroundLocation() async {
    try {
      final raw = await _method.invokeMethod<String>(
        'request_background_location',
      );
      return _parse(raw);
    } catch (_) {
      return status();
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _method.invokeMethod('open_settings');
    } catch (_) {}
  }

  Future<PermissionSnapshot> requestBatteryOptimization() async {
    try {
      final raw = await _method.invokeMethod<String>(
        'request_battery_optimization',
      );
      return _parse(raw);
    } catch (_) {
      return status();
    }
  }

  PermissionSnapshot _parse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const PermissionSnapshot(
        location: false,
        backgroundLocation: false,
        bluetooth: false,
        notifications: false,
      );
    }
    return PermissionSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}
