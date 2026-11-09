import 'package:flutter/services.dart';

import '../l10n/ui_translations.dart';

/// 系统 TTS：路线转向和运动播报都走这里，并使用当前应用语言。
class TtsBridge {
  TtsBridge._();

  static final TtsBridge instance = TtsBridge._();
  static const _method = MethodChannel('vitaloop/tts');

  Future<bool> status() async {
    try {
      return await _method.invokeMethod<bool>('status') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> speak(String text, {bool flush = true}) async {
    final value = tr(text).trim();
    if (value.isEmpty) return false;
    try {
      return await _method.invokeMethod<bool>('speak', {
            'text': value,
            'flush': flush,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
  }
}
