import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_th.dart';
import 'app_localizations_vi.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fr'),
    Locale('ja'),
    Locale('ru'),
    Locale('th'),
    Locale('vi'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Vitaloop'**
  String get appTitle;

  /// No description provided for @navFitness.
  ///
  /// In en, this message translates to:
  /// **'Fitness'**
  String get navFitness;

  /// No description provided for @navSport.
  ///
  /// In en, this message translates to:
  /// **'Sport'**
  String get navSport;

  /// No description provided for @navRecords.
  ///
  /// In en, this message translates to:
  /// **'Records'**
  String get navRecords;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @startupFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start'**
  String get startupFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @notSetNickname.
  ///
  /// In en, this message translates to:
  /// **'Nickname not set'**
  String get notSetNickname;

  /// No description provided for @cloudAccount.
  ///
  /// In en, this message translates to:
  /// **'Cloud account'**
  String get cloudAccount;

  /// No description provided for @localProfileOffline.
  ///
  /// In en, this message translates to:
  /// **'Local profile · Offline'**
  String get localProfileOffline;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @yearsShort.
  ///
  /// In en, this message translates to:
  /// **' yr'**
  String get yearsShort;

  /// No description provided for @trainingAndBody.
  ///
  /// In en, this message translates to:
  /// **'Training & body'**
  String get trainingAndBody;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTitle;

  /// No description provided for @profileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Nickname, gender, birth date, height and weight'**
  String get profileSubtitle;

  /// No description provided for @workoutGoals.
  ///
  /// In en, this message translates to:
  /// **'Activity goals'**
  String get workoutGoals;

  /// No description provided for @workoutGoalsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Steps, active calories and workout time'**
  String get workoutGoalsSubtitle;

  /// No description provided for @stepsPerDay.
  ///
  /// In en, this message translates to:
  /// **'Daily steps'**
  String get stepsPerDay;

  /// No description provided for @heartRateSettings.
  ///
  /// In en, this message translates to:
  /// **'Heart rate'**
  String get heartRateSettings;

  /// No description provided for @heartRateSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Heart-rate reserve and five training zones'**
  String get heartRateSettingsSubtitle;

  /// No description provided for @maxHeartRate.
  ///
  /// In en, this message translates to:
  /// **'Max heart rate'**
  String get maxHeartRate;

  /// No description provided for @workoutSettings.
  ///
  /// In en, this message translates to:
  /// **'Workout settings'**
  String get workoutSettings;

  /// No description provided for @workoutSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep screen on, auto-pause and recovery heart rate'**
  String get workoutSettingsSubtitle;

  /// No description provided for @myEquipment.
  ///
  /// In en, this message translates to:
  /// **'My gear'**
  String get myEquipment;

  /// No description provided for @myEquipmentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mileage by sport and replacement reminders'**
  String get myEquipmentSubtitle;

  /// No description provided for @devicesAndSync.
  ///
  /// In en, this message translates to:
  /// **'Devices & sync'**
  String get devicesAndSync;

  /// No description provided for @bluetoothDevices.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth devices'**
  String get bluetoothDevices;

  /// No description provided for @bluetoothDevicesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Heart-rate strap, scale, blood pressure, glucose and watch'**
  String get bluetoothDevicesSubtitle;

  /// No description provided for @watchTitle.
  ///
  /// In en, this message translates to:
  /// **'Huawei watch'**
  String get watchTitle;

  /// No description provided for @watchSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync sleep, heart rate, stress, HRV and GPS ephemeris'**
  String get watchSubtitle;

  /// No description provided for @bound.
  ///
  /// In en, this message translates to:
  /// **'Bound'**
  String get bound;

  /// No description provided for @unbound.
  ///
  /// In en, this message translates to:
  /// **'Not bound'**
  String get unbound;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @signInOrRegister.
  ///
  /// In en, this message translates to:
  /// **'Sign in / register (optional)'**
  String get signInOrRegister;

  /// No description provided for @cloudAccountLabel.
  ///
  /// In en, this message translates to:
  /// **'Cloud account'**
  String get cloudAccountLabel;

  /// No description provided for @offlineOnly.
  ///
  /// In en, this message translates to:
  /// **'Signed out means all data stays on this device'**
  String get offlineOnly;

  /// No description provided for @signedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get signedIn;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @appearanceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Follow system · Light / Dark'**
  String get appearanceSubtitle;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Follow system or choose manually'**
  String get languageSubtitle;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Choose language'**
  String get selectLanguage;

  /// No description provided for @permissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get permissions;

  /// No description provided for @permissionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Location, background location, Bluetooth and notifications'**
  String get permissionsSubtitle;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @openSourceLicense.
  ///
  /// In en, this message translates to:
  /// **'Open source · AGPL-3.0'**
  String get openSourceLicense;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @settingsFooter.
  ///
  /// In en, this message translates to:
  /// **'Vitaloop · Local-first · Optional automatic cloud sync'**
  String get settingsFooter;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @sleepDetails.
  ///
  /// In en, this message translates to:
  /// **'Sleep details'**
  String get sleepDetails;

  /// No description provided for @noSleepNight.
  ///
  /// In en, this message translates to:
  /// **'No sleep record for this night'**
  String get noSleepNight;

  /// No description provided for @noSleepNightBody.
  ///
  /// In en, this message translates to:
  /// **'Wear your watch to sleep and sleep stages will sync here automatically.'**
  String get noSleepNightBody;

  /// No description provided for @noSleepRange.
  ///
  /// In en, this message translates to:
  /// **'No sleep records in this period'**
  String get noSleepRange;

  /// No description provided for @noSleepRangeBody.
  ///
  /// In en, this message translates to:
  /// **'Sleep summaries will appear after your watch syncs data.'**
  String get noSleepRangeBody;

  /// No description provided for @sleepDuration.
  ///
  /// In en, this message translates to:
  /// **'Sleep duration'**
  String get sleepDuration;

  /// No description provided for @sleepScore.
  ///
  /// In en, this message translates to:
  /// **'Sleep score'**
  String get sleepScore;

  /// No description provided for @sleepEfficiency.
  ///
  /// In en, this message translates to:
  /// **'Sleep efficiency'**
  String get sleepEfficiency;

  /// No description provided for @bedTime.
  ///
  /// In en, this message translates to:
  /// **'Bedtime'**
  String get bedTime;

  /// No description provided for @fellAsleep.
  ///
  /// In en, this message translates to:
  /// **'Fell asleep'**
  String get fellAsleep;

  /// No description provided for @wokeUp.
  ///
  /// In en, this message translates to:
  /// **'Woke up'**
  String get wokeUp;

  /// No description provided for @breathing.
  ///
  /// In en, this message translates to:
  /// **'Breathing'**
  String get breathing;

  /// No description provided for @breathsPerMinute.
  ///
  /// In en, this message translates to:
  /// **'breaths/min'**
  String get breathsPerMinute;

  /// No description provided for @nightRhythm.
  ///
  /// In en, this message translates to:
  /// **'Night rhythm'**
  String get nightRhythm;

  /// No description provided for @nightRhythmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Four sleep stages in time order. Block length shows time spent.'**
  String get nightRhythmSubtitle;

  /// No description provided for @stageComposition.
  ///
  /// In en, this message translates to:
  /// **'Stage composition'**
  String get stageComposition;

  /// No description provided for @stageCompositionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How the night was distributed across sleep stages.'**
  String get stageCompositionSubtitle;

  /// No description provided for @awake.
  ///
  /// In en, this message translates to:
  /// **'Awake'**
  String get awake;

  /// No description provided for @rem.
  ///
  /// In en, this message translates to:
  /// **'REM'**
  String get rem;

  /// No description provided for @lightSleep.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get lightSleep;

  /// No description provided for @deepSleep.
  ///
  /// In en, this message translates to:
  /// **'Deep'**
  String get deepSleep;

  /// No description provided for @totalSleep.
  ///
  /// In en, this message translates to:
  /// **'Total sleep'**
  String get totalSleep;

  /// No description provided for @averageSleep.
  ///
  /// In en, this message translates to:
  /// **'Average sleep'**
  String get averageSleep;

  /// No description provided for @sleepTrend.
  ///
  /// In en, this message translates to:
  /// **'Sleep trend'**
  String get sleepTrend;

  /// No description provided for @nightHrv.
  ///
  /// In en, this message translates to:
  /// **'Night HRV'**
  String get nightHrv;

  /// No description provided for @average.
  ///
  /// In en, this message translates to:
  /// **'Average'**
  String get average;

  /// No description provided for @longestSleep.
  ///
  /// In en, this message translates to:
  /// **'Longest block'**
  String get longestSleep;

  /// No description provided for @personalBaseline.
  ///
  /// In en, this message translates to:
  /// **'Personal baseline'**
  String get personalBaseline;

  /// No description provided for @vsBaseline.
  ///
  /// In en, this message translates to:
  /// **'Vs baseline'**
  String get vsBaseline;

  /// No description provided for @sleepApnea.
  ///
  /// In en, this message translates to:
  /// **'Sleep apnea'**
  String get sleepApnea;

  /// No description provided for @noApneaRecords.
  ///
  /// In en, this message translates to:
  /// **'No apnea records for this night. No risk estimate is made when the watch reports none.'**
  String get noApneaRecords;

  /// No description provided for @noApneaRisk.
  ///
  /// In en, this message translates to:
  /// **'No apnea risk detected'**
  String get noApneaRisk;

  /// No description provided for @lowRisk.
  ///
  /// In en, this message translates to:
  /// **'Low risk'**
  String get lowRisk;

  /// No description provided for @mediumRisk.
  ///
  /// In en, this message translates to:
  /// **'Medium risk'**
  String get mediumRisk;

  /// No description provided for @highRisk.
  ///
  /// In en, this message translates to:
  /// **'High risk'**
  String get highRisk;

  /// No description provided for @bedAt.
  ///
  /// In en, this message translates to:
  /// **'Bedtime {time}'**
  String bedAt(String time);

  /// No description provided for @wakeAt.
  ///
  /// In en, this message translates to:
  /// **'Wake {time}'**
  String wakeAt(String time);

  /// No description provided for @chartHint.
  ///
  /// In en, this message translates to:
  /// **'Tap or drag across the chart to inspect a stage.'**
  String get chartHint;

  /// No description provided for @stageStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get stageStart;

  /// No description provided for @stageEnd.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get stageEnd;

  /// No description provided for @duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// No description provided for @rangeDay.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get rangeDay;

  /// No description provided for @rangeWeek.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get rangeWeek;

  /// No description provided for @rangeMonth.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get rangeMonth;

  /// No description provided for @recoveryGood.
  ///
  /// In en, this message translates to:
  /// **'Recovery is good'**
  String get recoveryGood;

  /// No description provided for @recoveryFair.
  ///
  /// In en, this message translates to:
  /// **'Recovery is fair'**
  String get recoveryFair;

  /// No description provided for @recoveryLow.
  ///
  /// In en, this message translates to:
  /// **'Prioritize recovery'**
  String get recoveryLow;

  /// No description provided for @hoursShort.
  ///
  /// In en, this message translates to:
  /// **' h'**
  String get hoursShort;

  /// No description provided for @minutesShort.
  ///
  /// In en, this message translates to:
  /// **' min'**
  String get minutesShort;

  /// No description provided for @nightsShort.
  ///
  /// In en, this message translates to:
  /// **' nights'**
  String get nightsShort;

  /// No description provided for @recordsShort.
  ///
  /// In en, this message translates to:
  /// **' records'**
  String get recordsShort;

  /// No description provided for @wakesShort.
  ///
  /// In en, this message translates to:
  /// **' wakes'**
  String get wakesShort;

  /// No description provided for @pointsShort.
  ///
  /// In en, this message translates to:
  /// **' pts'**
  String get pointsShort;

  /// No description provided for @maxLevel.
  ///
  /// In en, this message translates to:
  /// **'max level'**
  String get maxLevel;

  /// No description provided for @deepSleepShare.
  ///
  /// In en, this message translates to:
  /// **'deep sleep share'**
  String get deepSleepShare;

  /// No description provided for @noTrendData.
  ///
  /// In en, this message translates to:
  /// **'No trend data'**
  String get noTrendData;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'ja',
    'ru',
    'th',
    'vi',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'ja':
      return AppLocalizationsJa();
    case 'ru':
      return AppLocalizationsRu();
    case 'th':
      return AppLocalizationsTh();
    case 'vi':
      return AppLocalizationsVi();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
