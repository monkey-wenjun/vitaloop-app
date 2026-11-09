import 'package:flutter/services.dart';

class LocaleBridge {
  LocaleBridge._();

  static const _channel = MethodChannel('vitaloop/locale');

  static Future<void> sync(String code) async {
    try {
      await _channel.invokeMethod<void>('set_app_locale', {'code': code});
    } on MissingPluginException {
      // Desktop/tests do not expose the Android locale channel.
    } on PlatformException {
      // Flutter can still switch languages even if the native layer is unavailable.
    }
  }
}
