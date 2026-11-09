import 'package:flutter/services.dart';

/// 运动轨迹文件导出：原生侧写 cache/exports 并通过系统分享面板发出。
class ExportBridge {
  ExportBridge._();

  static final ExportBridge instance = ExportBridge._();

  static const _method = MethodChannel('vitaloop/export');

  Future<bool> shareTextFile({
    required String fileName,
    required String mimeType,
    required String content,
  }) async {
    try {
      return await _method.invokeMethod<bool>('share_file', {
            'name': fileName,
            'mime': mimeType,
            'content': content,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 分享内存里的二进制（例如运动详情截图），原生侧写 cache/exports 后
  /// 走系统分享面板。
  Future<bool> shareBytes({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    try {
      return await _method.invokeMethod<bool>('share_bytes', {
            'name': fileName,
            'mime': mimeType,
            'bytes': bytes,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 保存 PNG 到系统相册；Android 10+ 走 MediaStore，旧系统回退到
  /// Pictures/Vitaloop 并触发媒体扫描。
  Future<bool> saveBytes({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    try {
      return await _method.invokeMethod<bool>('save_image', {
            'name': fileName,
            'mime': mimeType,
            'bytes': bytes,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
