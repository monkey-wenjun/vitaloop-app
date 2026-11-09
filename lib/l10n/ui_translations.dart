import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class UiTranslations {
  UiTranslations._();

  static final UiTranslations instance = UiTranslations._();

  static const _asset = 'assets/i18n/ui_strings.json';
  static const _placeholderPattern = r'\[\[(\d+)\]\]';
  static final RegExp _han = RegExp(r'[\u3400-\u9fff]');
  static final RegExp _placeholder = RegExp(_placeholderPattern);
  static final RegExp _token = RegExp(r'\[\[\d+\]\]');

  final Map<String, Map<String, String>> _catalogs = {};
  final Map<String, List<_CompiledEntry>> _patterns = {};
  final Map<String, String> _cache = {};
  String _locale = 'zh';
  bool _loaded = false;
  Duration? lastLoadDuration;

  bool get loaded => _loaded;

  String get locale => _locale;

  Set<String> get loadedLocales => _catalogs.keys.toSet();

  @visibleForTesting
  int patternCountForLocale(String languageCode) =>
      _patterns[languageCode]?.length ?? 0;

  @visibleForTesting
  bool hasPatternForLocale(String languageCode, String source) =>
      _patterns[languageCode]?.any((entry) => entry.source == source) ?? false;

  Future<void> load({AssetBundle? bundle}) async {
    if (_loaded) return;
    final watch = Stopwatch()..start();
    try {
      final raw = await (bundle ?? rootBundle).loadString(_asset);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final locale in decoded.entries) {
        final values = <String, String>{};
        for (final item in (locale.value as Map<String, dynamic>).entries) {
          final value = item.value;
          if (value is String && value.trim().isNotEmpty) {
            values[item.key] = value;
          }
        }
        _catalogs[locale.key] = values;
        _patterns[locale.key] =
            [
              for (final entry in values.entries)
                if (entry.key.contains('[['))
                  _CompiledEntry(entry.key, entry.value),
            ]..sort((a, b) {
              final literalOrder = b.literalLength.compareTo(a.literalLength);
              return literalOrder != 0
                  ? literalOrder
                  : b.source.length.compareTo(a.source.length);
            });
      }
    } catch (error, stack) {
      debugPrint('[VitaloopI18n] failed to load legacy UI catalog: $error');
      debugPrint('$stack');
    } finally {
      watch.stop();
      lastLoadDuration = watch.elapsed;
      _loaded = true;
    }
  }

  void setLocale(String languageCode) {
    final next = languageCode.toLowerCase().split('-').first;
    if (_locale == next) return;
    _locale = next;
    _cache.clear();
  }

  String translate(String source, {String? languageCode}) {
    final language = (languageCode ?? _locale).toLowerCase().split('-').first;
    return _translate(source, 0, language);
  }

  String _translate(String source, int depth, String language) {
    if (source.isEmpty || language == 'zh' || !_han.hasMatch(source)) {
      return source;
    }
    final cacheKey = '$language\u0000$source';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    final catalog = _catalogs[language] ?? _catalogs['en'];
    if (catalog == null) return source;
    final exact = catalog[source];
    if (exact != null) {
      _remember(cacheKey, exact);
      return exact;
    }
    for (final entry in _patterns[language] ?? const <_CompiledEntry>[]) {
      final match = entry.pattern.firstMatch(source);
      if (match == null) continue;
      var translated = entry.translation;
      if (entry.placeholderCount == 0) {
        _remember(cacheKey, translated);
        return translated;
      }
      var complete = true;
      translated = translated.replaceAllMapped(_placeholder, (token) {
        final index = int.tryParse(token.group(1) ?? '');
        if (index == null || index + 1 > match.groupCount) {
          complete = false;
          return token.group(0)!;
        }
        final capture = match.group(index + 1) ?? '';
        return depth < 3 ? _translate(capture, depth + 1, language) : capture;
      });
      if (complete && !_token.hasMatch(translated)) {
        if (translated == source) continue;
        if (language != 'ja' && language != 'zh' && _han.hasMatch(translated)) {
          continue;
        }
        _remember(cacheKey, translated);
        return translated;
      }
    }
    if (language != 'en') {
      final fallback = _translate(source, depth, 'en');
      _remember(cacheKey, fallback);
      return fallback;
    }
    return source;
  }

  void _remember(String key, String value) {
    if (_cache.length > 2500) _cache.clear();
    _cache[key] = value;
  }
}

String tr(String source) => UiTranslations.instance.translate(source);

class _CompiledEntry {
  _CompiledEntry(this.source, this.translation)
    : placeholderCount = RegExp(_UiTranslationsPatterns.placeholder)
          .allMatches(source)
          .length,
      literalLength = source
          .replaceAll(RegExp(_UiTranslationsPatterns.placeholder), '')
          .trim()
          .length,
      pattern = RegExp(
        '^${_UiTranslationsPatterns.patternFor(source)}\$',
        dotAll: true,
      );

  final String source;
  final String translation;
  final int placeholderCount;
  final int literalLength;
  final RegExp pattern;
}

abstract final class _UiTranslationsPatterns {
  static const placeholder = r'\[\[\d+\]\]';

  static String patternFor(String source) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in RegExp(placeholder).allMatches(source)) {
      buffer.write(RegExp.escape(source.substring(cursor, match.start)));
      buffer.write('(.*?)');
      cursor = match.end;
    }
    buffer.write(RegExp.escape(source.substring(cursor)));
    return buffer.toString();
  }
}
