// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Vitaloop';

  @override
  String get navFitness => 'Fitness';

  @override
  String get navSport => 'Sport';

  @override
  String get navRecords => 'Records';

  @override
  String get navSettings => 'Settings';

  @override
  String get startupFailed => 'Could not start';

  @override
  String get retry => 'Retry';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get notSetNickname => 'Nickname not set';

  @override
  String get cloudAccount => 'Cloud account';

  @override
  String get localProfileOffline => 'Local profile · Offline';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get yearsShort => ' yr';

  @override
  String get trainingAndBody => 'Training & body';

  @override
  String get profileTitle => 'Profile';

  @override
  String get profileSubtitle =>
      'Nickname, gender, birth date, height and weight';

  @override
  String get workoutGoals => 'Activity goals';

  @override
  String get workoutGoalsSubtitle => 'Steps, active calories and workout time';

  @override
  String get stepsPerDay => 'Daily steps';

  @override
  String get heartRateSettings => 'Heart rate';

  @override
  String get heartRateSettingsSubtitle =>
      'Heart-rate reserve and five training zones';

  @override
  String get maxHeartRate => 'Max heart rate';

  @override
  String get workoutSettings => 'Workout settings';

  @override
  String get workoutSettingsSubtitle =>
      'Keep screen on, auto-pause and recovery heart rate';

  @override
  String get myEquipment => 'My gear';

  @override
  String get myEquipmentSubtitle =>
      'Mileage by sport and replacement reminders';

  @override
  String get devicesAndSync => 'Devices & sync';

  @override
  String get bluetoothDevices => 'Bluetooth devices';

  @override
  String get bluetoothDevicesSubtitle =>
      'Heart-rate strap, scale, blood pressure, glucose and watch';

  @override
  String get watchTitle => 'Huawei watch';

  @override
  String get watchSubtitle =>
      'Sync sleep, heart rate, stress, HRV and GPS ephemeris';

  @override
  String get bound => 'Bound';

  @override
  String get unbound => 'Not bound';

  @override
  String get connected => 'Connected';

  @override
  String get notConnected => 'Not connected';

  @override
  String get general => 'General';

  @override
  String get account => 'Account';

  @override
  String get signInOrRegister => 'Sign in / register (optional)';

  @override
  String get cloudAccountLabel => 'Cloud account';

  @override
  String get offlineOnly => 'Signed out means all data stays on this device';

  @override
  String get signedIn => 'Signed in';

  @override
  String get appearance => 'Appearance';

  @override
  String get appearanceSubtitle => 'Follow system · Light / Dark';

  @override
  String get language => 'Language';

  @override
  String get languageSubtitle => 'Follow system or choose manually';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get selectLanguage => 'Choose language';

  @override
  String get permissions => 'Permissions';

  @override
  String get permissionsSubtitle =>
      'Location, background location, Bluetooth and notifications';

  @override
  String get about => 'About';

  @override
  String get openSourceLicense => 'Open source · AGPL-3.0';

  @override
  String get signOut => 'Sign out';

  @override
  String get settingsFooter =>
      'Vitaloop · Local-first · Optional automatic cloud sync';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get sleepDetails => 'Sleep details';

  @override
  String get noSleepNight => 'No sleep record for this night';

  @override
  String get noSleepNightBody =>
      'Wear your watch to sleep and sleep stages will sync here automatically.';

  @override
  String get noSleepRange => 'No sleep records in this period';

  @override
  String get noSleepRangeBody =>
      'Sleep summaries will appear after your watch syncs data.';

  @override
  String get sleepDuration => 'Sleep duration';

  @override
  String get sleepScore => 'Sleep score';

  @override
  String get sleepEfficiency => 'Sleep efficiency';

  @override
  String get bedTime => 'Bedtime';

  @override
  String get fellAsleep => 'Fell asleep';

  @override
  String get wokeUp => 'Woke up';

  @override
  String get breathing => 'Breathing';

  @override
  String get breathsPerMinute => 'breaths/min';

  @override
  String get nightRhythm => 'Night rhythm';

  @override
  String get nightRhythmSubtitle =>
      'Four sleep stages in time order. Block length shows time spent.';

  @override
  String get stageComposition => 'Stage composition';

  @override
  String get stageCompositionSubtitle =>
      'How the night was distributed across sleep stages.';

  @override
  String get awake => 'Awake';

  @override
  String get rem => 'REM';

  @override
  String get lightSleep => 'Light';

  @override
  String get deepSleep => 'Deep';

  @override
  String get totalSleep => 'Total sleep';

  @override
  String get averageSleep => 'Average sleep';

  @override
  String get sleepTrend => 'Sleep trend';

  @override
  String get nightHrv => 'Night HRV';

  @override
  String get average => 'Average';

  @override
  String get longestSleep => 'Longest block';

  @override
  String get personalBaseline => 'Personal baseline';

  @override
  String get vsBaseline => 'Vs baseline';

  @override
  String get sleepApnea => 'Sleep apnea';

  @override
  String get noApneaRecords =>
      'No apnea records for this night. No risk estimate is made when the watch reports none.';

  @override
  String get noApneaRisk => 'No apnea risk detected';

  @override
  String get lowRisk => 'Low risk';

  @override
  String get mediumRisk => 'Medium risk';

  @override
  String get highRisk => 'High risk';

  @override
  String bedAt(String time) {
    return 'Bedtime $time';
  }

  @override
  String wakeAt(String time) {
    return 'Wake $time';
  }

  @override
  String get chartHint => 'Tap or drag across the chart to inspect a stage.';

  @override
  String get stageStart => 'Start';

  @override
  String get stageEnd => 'End';

  @override
  String get duration => 'Duration';

  @override
  String get rangeDay => 'Day';

  @override
  String get rangeWeek => 'Week';

  @override
  String get rangeMonth => 'Month';

  @override
  String get recoveryGood => 'Recovery is good';

  @override
  String get recoveryFair => 'Recovery is fair';

  @override
  String get recoveryLow => 'Prioritize recovery';

  @override
  String get hoursShort => ' h';

  @override
  String get minutesShort => ' min';

  @override
  String get nightsShort => ' nights';

  @override
  String get recordsShort => ' records';

  @override
  String get wakesShort => ' wakes';

  @override
  String get pointsShort => ' pts';

  @override
  String get maxLevel => 'max level';

  @override
  String get deepSleepShare => 'deep sleep share';

  @override
  String get noTrendData => 'No trend data';
}
