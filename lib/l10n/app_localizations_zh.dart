// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '元环 Vitaloop';

  @override
  String get navFitness => '体能';

  @override
  String get navSport => '运动';

  @override
  String get navRecords => '记录';

  @override
  String get navSettings => '设置';

  @override
  String get startupFailed => '启动失败';

  @override
  String get retry => '重试';

  @override
  String get settingsTitle => '设置';

  @override
  String get notSetNickname => '未设置昵称';

  @override
  String get cloudAccount => '云端账号';

  @override
  String get localProfileOffline => '本机资料 · 未登录';

  @override
  String get editProfile => '编辑资料';

  @override
  String get yearsShort => ' 岁';

  @override
  String get trainingAndBody => '训练与身体';

  @override
  String get profileTitle => '个人资料';

  @override
  String get profileSubtitle => '昵称、性别、出生日期、身高体重';

  @override
  String get workoutGoals => '运动目标';

  @override
  String get workoutGoalsSubtitle => '步数、活动热量、运动时长';

  @override
  String get stepsPerDay => '每日步数';

  @override
  String get heartRateSettings => '心率设置';

  @override
  String get heartRateSettingsSubtitle => '储备心率、五档心率区间';

  @override
  String get maxHeartRate => '最大心率';

  @override
  String get workoutSettings => '运动设置';

  @override
  String get workoutSettingsSubtitle => '屏幕常亮、自动暂停、恢复心率';

  @override
  String get myEquipment => '我的装备';

  @override
  String get myEquipmentSubtitle => '按运动类型累计里程与更换提醒';

  @override
  String get devicesAndSync => '设备与同步';

  @override
  String get bluetoothDevices => '蓝牙设备';

  @override
  String get bluetoothDevicesSubtitle => '心率带、体重秤、血压计、血糖仪、华为手表';

  @override
  String get watchTitle => '华为手表';

  @override
  String get watchSubtitle => '同步睡眠、心率、压力、HRV 与 GPS 星历';

  @override
  String get bound => '已绑定';

  @override
  String get unbound => '未绑定';

  @override
  String get connected => '已连接';

  @override
  String get notConnected => '未连接';

  @override
  String get general => '通用';

  @override
  String get account => '账号';

  @override
  String get signInOrRegister => '登录 / 注册（可选）';

  @override
  String get cloudAccountLabel => '云端账号';

  @override
  String get offlineOnly => '不登录 = 全部数据只存本机';

  @override
  String get signedIn => '已登录';

  @override
  String get appearance => '外观';

  @override
  String get appearanceSubtitle => '跟随系统 · 浅色 / 深色';

  @override
  String get language => '语言';

  @override
  String get languageSubtitle => '跟随系统或手动选择';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get selectLanguage => '选择语言';

  @override
  String get permissions => '权限管理';

  @override
  String get permissionsSubtitle => '定位、后台定位、蓝牙和通知';

  @override
  String get about => '关于';

  @override
  String get openSourceLicense => '开源 · AGPL-3.0';

  @override
  String get signOut => '退出登录';

  @override
  String get settingsFooter => 'Vitaloop 元环 · 不登录只存本机 · 登录后可选自动同步';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get sleepDetails => '睡眠详情';

  @override
  String get noSleepNight => '这一晚没有睡眠记录';

  @override
  String get noSleepNightBody => '戴着手表入睡后，深睡、浅睡与 REM 会自动同步到这里。';

  @override
  String get noSleepRange => '这段时间没有睡眠记录';

  @override
  String get noSleepRangeBody => '手表同步睡眠数据后，会在这里汇总展示。';

  @override
  String get sleepDuration => '睡眠时长';

  @override
  String get sleepScore => '睡眠评分';

  @override
  String get sleepEfficiency => '睡眠效率';

  @override
  String get bedTime => '上床';

  @override
  String get fellAsleep => '入睡';

  @override
  String get wokeUp => '醒来';

  @override
  String get breathing => '呼吸';

  @override
  String get breathsPerMinute => '次/分';

  @override
  String get nightRhythm => '夜间节律';

  @override
  String get nightRhythmSubtitle => '四个阶段按时间依次展开，色块长度对应实际停留时长。';

  @override
  String get stageComposition => '分期构成';

  @override
  String get stageCompositionSubtitle => '查看整晚在清醒、REM、浅睡与深睡之间的分布。';

  @override
  String get awake => '清醒';

  @override
  String get rem => 'REM';

  @override
  String get lightSleep => '浅睡';

  @override
  String get deepSleep => '深睡';

  @override
  String get totalSleep => '总睡眠';

  @override
  String get averageSleep => '平均睡眠';

  @override
  String get sleepTrend => '睡眠趋势';

  @override
  String get nightHrv => '夜间 HRV';

  @override
  String get average => '平均';

  @override
  String get longestSleep => '最长单段';

  @override
  String get personalBaseline => '个人基线';

  @override
  String get vsBaseline => '较基线';

  @override
  String get sleepApnea => '睡眠呼吸暂停';

  @override
  String get noApneaRecords => '这一晚没有呼吸暂停记录。手表未上报时不会估算风险。';

  @override
  String get noApneaRisk => '未见呼吸暂停风险';

  @override
  String get lowRisk => '低风险';

  @override
  String get mediumRisk => '中风险';

  @override
  String get highRisk => '高风险';

  @override
  String bedAt(String time) {
    return '上床 $time';
  }

  @override
  String wakeAt(String time) {
    return '醒来 $time';
  }

  @override
  String get chartHint => '轻触或横向拖动图表，查看对应阶段。';

  @override
  String get stageStart => '开始';

  @override
  String get stageEnd => '结束';

  @override
  String get duration => '时长';

  @override
  String get rangeDay => '日';

  @override
  String get rangeWeek => '周';

  @override
  String get rangeMonth => '月';

  @override
  String get recoveryGood => '恢复良好';

  @override
  String get recoveryFair => '恢复一般';

  @override
  String get recoveryLow => '优先恢复';

  @override
  String get hoursShort => ' 小时';

  @override
  String get minutesShort => ' 分钟';

  @override
  String get nightsShort => ' 晚';

  @override
  String get recordsShort => ' 条记录';

  @override
  String get wakesShort => ' 次夜醒';

  @override
  String get pointsShort => ' 分';

  @override
  String get maxLevel => '最高级别';

  @override
  String get deepSleepShare => '深睡占比';

  @override
  String get noTrendData => '暂无趋势数据';
}
