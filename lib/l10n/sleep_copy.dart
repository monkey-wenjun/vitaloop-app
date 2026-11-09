import '../ui/screens/sleep/sleep_data.dart';
import 'app_localizations.dart';

extension SleepLocalizations on AppLocalizations {
  String sleepDurationText(int minutes) {
    final safe = minutes < 0 ? 0 : minutes;
    final hours = safe ~/ 60;
    final rest = safe % 60;
    if (hours == 0) return '$rest$minutesShort';
    if (rest == 0) return '$hours$hoursShort';
    return '$hours$hoursShort $rest$minutesShort';
  }

  String sleepStageName(SleepStageKind kind) => switch (kind) {
    SleepStageKind.awake => awake,
    SleepStageKind.rem => rem,
    SleepStageKind.light => lightSleep,
    SleepStageKind.deep => deepSleep,
  };

  String sleepRangeName(int index) => switch (index) {
    1 => rangeWeek,
    2 => rangeMonth,
    _ => rangeDay,
  };

  String sleepRecoveryLabel(int score) {
    if (score >= 80) return recoveryGood;
    if (score >= 60) return recoveryFair;
    return recoveryLow;
  }
}
