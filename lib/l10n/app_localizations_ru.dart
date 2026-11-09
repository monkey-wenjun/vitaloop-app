// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Vitaloop';

  @override
  String get navFitness => 'Фитнес';

  @override
  String get navSport => 'Спорт';

  @override
  String get navRecords => 'Записи';

  @override
  String get navSettings => 'Настройки';

  @override
  String get startupFailed => 'Не удалось запустить';

  @override
  String get retry => 'Повторить';

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get notSetNickname => 'Имя не задано';

  @override
  String get cloudAccount => 'Облачный аккаунт';

  @override
  String get localProfileOffline => 'Локальный профиль · Офлайн';

  @override
  String get editProfile => 'Изменить профиль';

  @override
  String get yearsShort => ' лет';

  @override
  String get trainingAndBody => 'Тренировки и тело';

  @override
  String get profileTitle => 'Профиль';

  @override
  String get profileSubtitle => 'Имя, пол, дата рождения, рост и вес';

  @override
  String get workoutGoals => 'Цели активности';

  @override
  String get workoutGoalsSubtitle =>
      'Шаги, активные калории и время тренировок';

  @override
  String get stepsPerDay => 'Шагов в день';

  @override
  String get heartRateSettings => 'Пульс';

  @override
  String get heartRateSettingsSubtitle => 'Резерв пульса и пять пульсовых зон';

  @override
  String get maxHeartRate => 'Максимальный пульс';

  @override
  String get workoutSettings => 'Настройки тренировок';

  @override
  String get workoutSettingsSubtitle =>
      'Экран включён, автопауза и пульс восстановления';

  @override
  String get myEquipment => 'Моё снаряжение';

  @override
  String get myEquipmentSubtitle =>
      'Пробег по видам спорта и напоминания о замене';

  @override
  String get devicesAndSync => 'Устройства и синхронизация';

  @override
  String get bluetoothDevices => 'Bluetooth-устройства';

  @override
  String get bluetoothDevicesSubtitle =>
      'Пульсометр, весы, тонометр, глюкометр и часы';

  @override
  String get watchTitle => 'Часы Huawei';

  @override
  String get watchSubtitle => 'Сон, пульс, стресс, HRV и GPS-эфемериды';

  @override
  String get bound => 'Привязано';

  @override
  String get unbound => 'Не привязано';

  @override
  String get connected => 'Подключено';

  @override
  String get notConnected => 'Не подключено';

  @override
  String get general => 'Общие';

  @override
  String get account => 'Аккаунт';

  @override
  String get signInOrRegister => 'Вход / регистрация (необязательно)';

  @override
  String get cloudAccountLabel => 'Облачный аккаунт';

  @override
  String get offlineOnly => 'Без входа все данные остаются на устройстве';

  @override
  String get signedIn => 'Выполнен вход';

  @override
  String get appearance => 'Оформление';

  @override
  String get appearanceSubtitle => 'Как в системе · Светлая / Тёмная';

  @override
  String get language => 'Язык';

  @override
  String get languageSubtitle => 'Как в системе или вручную';

  @override
  String get languageSystem => 'Как в системе';

  @override
  String get selectLanguage => 'Выбор языка';

  @override
  String get permissions => 'Разрешения';

  @override
  String get permissionsSubtitle =>
      'Геолокация, фоновая геолокация, Bluetooth и уведомления';

  @override
  String get about => 'О приложении';

  @override
  String get openSourceLicense => 'Открытый код · AGPL-3.0';

  @override
  String get signOut => 'Выйти';

  @override
  String get settingsFooter =>
      'Vitaloop · Данные сначала локально · Необязательная автосинхронизация';

  @override
  String get themeSystem => 'Как в системе';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get sleepDetails => 'Подробности сна';

  @override
  String get noSleepNight => 'За эту ночь нет данных о сне';

  @override
  String get noSleepNightBody =>
      'Наденьте часы на ночь, и фазы сна синхронизируются автоматически.';

  @override
  String get noSleepRange => 'За этот период нет данных о сне';

  @override
  String get noSleepRangeBody => 'Сводка появится после синхронизации часов.';

  @override
  String get sleepDuration => 'Продолжительность сна';

  @override
  String get sleepScore => 'Оценка сна';

  @override
  String get sleepEfficiency => 'Эффективность сна';

  @override
  String get bedTime => 'В постели';

  @override
  String get fellAsleep => 'Заснул';

  @override
  String get wokeUp => 'Пробуждение';

  @override
  String get breathing => 'Дыхание';

  @override
  String get breathsPerMinute => 'вдох./мин';

  @override
  String get nightRhythm => 'Ночной ритм';

  @override
  String get nightRhythmSubtitle =>
      'Четыре фазы сна по времени. Длина блока показывает длительность.';

  @override
  String get stageComposition => 'Структура сна';

  @override
  String get stageCompositionSubtitle => 'Распределение ночи по фазам сна.';

  @override
  String get awake => 'Бодрствование';

  @override
  String get rem => 'REM';

  @override
  String get lightSleep => 'Лёгкий сон';

  @override
  String get deepSleep => 'Глубокий сон';

  @override
  String get totalSleep => 'Общий сон';

  @override
  String get averageSleep => 'Средний сон';

  @override
  String get sleepTrend => 'Тренд сна';

  @override
  String get nightHrv => 'Ночной HRV';

  @override
  String get average => 'Среднее';

  @override
  String get longestSleep => 'Макс. блок';

  @override
  String get personalBaseline => 'Личная база';

  @override
  String get vsBaseline => 'К базе';

  @override
  String get sleepApnea => 'Апноэ во сне';

  @override
  String get noApneaRecords =>
      'За эту ночь нет записей апноэ. Без данных часов риск не оценивается.';

  @override
  String get noApneaRisk => 'Риск апноэ не обнаружен';

  @override
  String get lowRisk => 'Низкий риск';

  @override
  String get mediumRisk => 'Средний риск';

  @override
  String get highRisk => 'Высокий риск';

  @override
  String bedAt(String time) {
    return 'В постели $time';
  }

  @override
  String wakeAt(String time) {
    return 'Пробуждение $time';
  }

  @override
  String get chartHint =>
      'Нажмите или проведите по графику, чтобы изучить фазу.';

  @override
  String get stageStart => 'Начало';

  @override
  String get stageEnd => 'Конец';

  @override
  String get duration => 'Длительность';

  @override
  String get rangeDay => 'День';

  @override
  String get rangeWeek => 'Неделя';

  @override
  String get rangeMonth => 'Месяц';

  @override
  String get recoveryGood => 'Восстановление хорошее';

  @override
  String get recoveryFair => 'Восстановление среднее';

  @override
  String get recoveryLow => 'Приоритет — восстановление';

  @override
  String get hoursShort => ' ч';

  @override
  String get minutesShort => ' мин';

  @override
  String get nightsShort => ' ноч.';

  @override
  String get recordsShort => ' записей';

  @override
  String get wakesShort => ' пробуждений';

  @override
  String get pointsShort => ' баллов';

  @override
  String get maxLevel => 'макс. уровень';

  @override
  String get deepSleepShare => 'доля глубокого сна';

  @override
  String get noTrendData => 'Нет данных тренда';
}
