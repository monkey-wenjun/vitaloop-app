import 'dart:ui';

class AppLanguageOption {
  const AppLanguageOption({
    required this.code,
    required this.nativeName,
    this.locale,
  });

  final String code;
  final String nativeName;
  final Locale? locale;
}

const appLanguageOptions = <AppLanguageOption>[
  AppLanguageOption(code: 'system', nativeName: 'Auto'),
  AppLanguageOption(code: 'zh', nativeName: '简体中文', locale: Locale('zh')),
  AppLanguageOption(code: 'en', nativeName: 'English', locale: Locale('en')),
  AppLanguageOption(code: 'ja', nativeName: '日本語', locale: Locale('ja')),
  AppLanguageOption(code: 'ru', nativeName: 'Русский', locale: Locale('ru')),
  AppLanguageOption(code: 'fr', nativeName: 'Français', locale: Locale('fr')),
  AppLanguageOption(code: 'vi', nativeName: 'Tiếng Việt', locale: Locale('vi')),
  AppLanguageOption(code: 'th', nativeName: 'ไทย', locale: Locale('th')),
  AppLanguageOption(code: 'es', nativeName: 'Español', locale: Locale('es')),
  AppLanguageOption(code: 'de', nativeName: 'Deutsch', locale: Locale('de')),
];

AppLanguageOption? languageOptionByCode(String code) {
  for (final option in appLanguageOptions) {
    if (option.code == code) return option;
  }
  return null;
}
