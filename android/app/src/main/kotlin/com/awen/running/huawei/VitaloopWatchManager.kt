package com.awen.running.huawei

import android.annotation.SuppressLint
import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.location.Location
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaMetadataRetriever
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.OpenableColumns
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import android.util.Log
import com.google.gson.Gson
import com.awen.running.data.WeatherSpec
import com.awen.running.location.VitaloopGpsManager
import com.awen.running.route.WatchRoute
import com.awen.running.route.WatchRoutePoint
import com.awen.running.utils.FileLogger
import kotlinx.coroutines.runBlocking
import nodomain.freeyourgadget.gadgetbridge.GBApplication
import nodomain.freeyourgadget.gadgetbridge.activities.devicesettings.DeviceSettingsPreferenceConst
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiConstants
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinator
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCoordinatorSupplier
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCrypto
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiDictTypes
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiGpsParser
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPeriodRriFileParser
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiSequenceDataFileParser
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTruSleepParser
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTrueSleepSequenceDataParser
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiUtil
import nodomain.freeyourgadget.gadgetbridge.devices.miband.MiBandConst
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.P2P
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Ephemeris
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.EphemerisFileUpload
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FileUpload
import nodomain.freeyourgadget.gadgetbridge.impl.GBDevice
import nodomain.freeyourgadget.gadgetbridge.impl.GBDeviceMusic
import nodomain.freeyourgadget.gadgetbridge.model.Alarm
import nodomain.freeyourgadget.gadgetbridge.model.NotificationSpec
import nodomain.freeyourgadget.gadgetbridge.model.NotificationType
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiEphemerisManager
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiFileDownloadManager
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiUploadManager
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.HuaweiP2PManager
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PCalendarService
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PCoursePlanService
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PDataDictionarySyncService
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PMapService
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PTrackService
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.App
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.CameraRemote
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Calls
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.DeviceConfig
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FindPhone
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.GpsAndTime
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Menstrual
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.MusicControl
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Watchface
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Weather
import nodomain.freeyourgadget.gadgetbridge.model.Contact
import nodomain.freeyourgadget.gadgetbridge.model.CallSpec
import nodomain.freeyourgadget.gadgetbridge.model.MusicSpec
import nodomain.freeyourgadget.gadgetbridge.model.MusicStateSpec
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadAck
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.AcceptAgreementsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.AlarmsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetBatteryLevelNotifyRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetDeviceStatusRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetEventAlarmList
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetExpandCapabilityRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetHiChainRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetLinkParamsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetProductInformationRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetSecurityNegotiationRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetSettingRelatedRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetSmartAlarmList
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetSleepDataCountRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetStepDataCountRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetFitnessTotalsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetSupportedServicesRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWorkoutCountRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetAppNames
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetContactsCount
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetMusicInfoParams
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetMusicList
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetMusicPlaylist
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetMusicPlaylistMusics
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetNotificationCapabilitiesRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetNotificationConstraintsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetGpsParameterRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWatchfaceParams
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWatchfacesList
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWatchfacesNames
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWearStatusNotifyRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.Request
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendAppDelete
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendCameraRemoteSetupEvent
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendDndAddRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendDndDeleteRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendSetContactsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendUploadMusicFileInfoResponse
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWatchfaceConfirm
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWatchfaceOperation
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetMusicRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetMusicStatusRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.StopFindPhoneRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetActivateOnLiftRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetActivityReminderRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetAutomaticHeartrateRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetAutomaticSpoRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetDateFormatRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetDisconnectNotification
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetNavigateOnRotateRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetNotificationRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetSkinTemperatureMeasurement
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetTimeRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetTimeZoneIdRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetTruSleepRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetWearMessagePushRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SetWorkModeRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFitnessUserInfoRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendExtendedAccountRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadChunk
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadComplete
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadHash
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFileUploadInfo
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendFactoryResetRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendGpsDataRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendGpsAndTimeToDeviceRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendGpsStatusRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendMenstrualCapabilityRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendMenstrualModifyTimeRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendNotificationRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.StopNotificationRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherCurrentRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherExtendedSupportRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherForecastRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherStartRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherSunMoonSupportRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherSupportRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.SendWeatherUnitRequest
import nodomain.freeyourgadget.gadgetbridge.util.StringUtils
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ConcurrentHashMap

/**
 * Vitaloop 精简版华为手表管理器：RFCOMM 直连 + HiChain 认证 + 定时同步。
 * 数据不落 Room，全部以 JSON 事件抛给 [onEvent]，由 Flutter 转交 Rust store。
 */
class VitaloopWatchManager private constructor(private val appContext: Context) : IHuaweiSupport {

    companion object {
        private const val TAG = "VitaloopWatch"
        private const val DEFAULT_SYNC_START = 946684800 // 2000-01-01
        private const val LAST_SYNC_KEY = "last_sync_start"
        private const val INIT_TIMEOUT_MS = 65_000
        private const val ALARM_TIMEOUT_MS = 10_000
        private const val SYNC_REQUEST_TIMEOUT_MS = 65_000
        private const val SYNC_INTERVAL_MS = 60_000L
        private const val WEAR_HEARTBEAT_INTERVAL_MS = 10_000L
        private const val WATCH_PREFS = "vitaloop_watch"
        private const val KEY_ADDRESS = "watch_address"
        private const val KEY_NAME = "watch_name"
        private const val KEY_USER_DISCONNECTED = "user_disconnected"
        private const val KEY_AUTO_SYNC = "auto_sync"
        private const val KEY_WEATHER_SYNC = "weather_sync_enabled"
        private const val KEY_WORKOUT_SYNC = "workout_sync_end"
        private const val KEY_WORKOUT_BACKFILL = "workout_backfill_v1"
        private const val KEY_WORKOUT_GPS_RETRY = "workout_gps_retry_v1"
        private const val KEY_ALARMS = "alarms"
        private const val KEY_ALARMS_PENDING = "alarms_pending_sync"
        private const val KEY_HOLIDAY_SKIP = "smart_holiday_skip"
        private const val KEY_PENDING_PLAN = "pending_training_plan"
        private const val KEY_CAMERA_REMOTE = "camera_remote_enabled"
        private const val KEY_FIND_PHONE = "find_phone_enabled"
        private const val KEY_DND = "dnd_enabled"
        private const val KEY_DND_MODE = "dnd_mode"
        private const val KEY_DND_START = "dnd_start"
        private const val KEY_DND_END = "dnd_end"
        private const val KEY_DND_REPEAT = "dnd_repeat"
        private const val KEY_DND_LIFT = "dnd_lift_wrist"
        private const val KEY_WATCH_SETTING_PREFIX = "watch_setting_"
        private const val PREF_SYNC_CALENDAR = "sync_calendar"
        private const val MAX_BUFFERED_EVENTS = 4000
        private const val EPHEMERIS_PREFS = "ephemeris_prefs"

        /** 与旧版 WatchSetting 对齐的手表开关；值为首次使用的默认值。 */
        private val WATCH_SETTING_DEFAULTS = linkedMapOf(
            "sleep" to true,
            "heart_rate" to true,
            "sedentary" to true,
            "spo2" to true,
            "lift_wrist" to true,
            "rotate_wrist" to false,
            "notification" to true,
            "temperature" to true,
            "disconnect_notify" to true,
            "work_mode" to true,
            "music" to true
        )

        private val WATCH_SETTING_LABELS = mapOf(
            "sleep" to "睡眠监测",
            "heart_rate" to "心率实时检测",
            "sedentary" to "久坐提醒",
            "spo2" to "自动血氧测量",
            "lift_wrist" to "抬腕亮屏",
            "rotate_wrist" to "翻腕切屏",
            "notification" to "消息通知",
            "temperature" to "皮肤温度测量",
            "disconnect_notify" to "断开提醒",
            "work_mode" to "自动工作模式",
            "music" to "音乐控制"
        )
        /** 首次只回看 30 天：更早的历史走旧版数据迁移，不在每轮连接里重拉 */
        private const val WORKOUT_FIRST_WINDOW_SEC = 30 * 86_400
        /** 增量回看重叠：刚同步的运动留 6 小时窗口，链路忙/文件未就绪导致的轨迹缺失靠每分钟同步自愈 */
        private const val WORKOUT_OVERLAP_SEC = 6 * 3600
        /** 掉出 6 小时窗口仍缺 GPS 的老运动：每 6 小时才回头重拉一次，避免每分钟把同一条反复请求 */
        private const val WORKOUT_RETRY_COOLDOWN_MS = 6 * 3600_000L
        /** 只回看 14 天内仍缺 GPS 的运动：手表早就淘汰的记录再怎么拉也拿不回来 */
        private const val WORKOUT_RETRY_MAX_AGE_MS = 14L * 86_400_000L
        /** 单轮运动链超过 3 分钟视为卡死，放行下一轮 */
        private const val WORKOUT_WATCHDOG_MS = 180_000L

        /** 星历检查节流：源每小时 :30 更新，10 分钟查一次足够提前备好 */
        private const val EPHEMERIS_CHECK_INTERVAL_MS = 600_000L
        private const val P2P_SYNC_INTERVAL_MS = 900_000L
        private const val WEATHER_CACHE_TTL_MS = 30 * 60_000L
        private const val STRESS_FILE_SYNC_INTERVAL_MS = 3_600_000L
        private const val SLEEP_FILE_SYNC_INTERVAL_MS = 300_000L
        private const val SLEEP_DETAIL_SYNC_INTERVAL_MS = 300_000L
        private const val TOOL_TIMEOUT_MS = 20_000L
        private const val WATCHFACE_UPLOAD_TIMEOUT_MS = 300_000L
        private const val MUSIC_UPLOAD_TIMEOUT_MS = 300_000L
        /** 地图整包要一次读进内存再走 0x28 通道，App 没开 largeHeap，上限 128 MB。 */
        private const val MAP_PUSH_MAX_BYTES = 128L * 1024 * 1024
        private const val MAP_PUSH_CONNECT_TIMEOUT_MS = 60_000L
        private const val UPLOAD_SLOT_WATCHFACE = "watchface"
        private const val UPLOAD_SLOT_APP = "app"
        private const val UPLOAD_SLOT_MUSIC = "music"
        /** 佩戴状态（0x01/0x3d）tag 0x01：GT 5 真机实测 0x02=在腕、0x01=离腕 */
        const val WEAR_STATUS_WORN = 0x02
        const val WEAR_STATUS_OFF_WRIST = 0x01
        private const val MUSIC_FILE_RESULT_ALREADY_EXISTS = 140008
        private const val DICT_PROBE_CHUNK_SIZE = 6
        private val DICT_PROBE_CLASSES = listOf(
            10001, 10003, 10004, 10005, 10006, 10007, 10008, 10009, 10010,
            200001, 200002, 200004, 200005, 200006, 200007, 200008, 200009, 200010,
            300001, 300002, 300003, 300004, 300005, 300006, 300007, 300008, 300009, 300010,
            400001, 400002, 400003, 400004, 400005, 400006, 400007, 400008, 400009, 400010,
            400011, 400013, 400014, 400015, 400016, 400017, 400018, 400019, 400020,
            400023, 400025, 400026,
            500001, 500002, 500003, 500004, 500005, 500007, 500008, 500009, 500010,
            500011, 500012, 500013, 500014, 500015, 500016, 500017, 500018, 500019, 500020,
            500021, 500022, 500023, 500024, 500025, 500026, 500027, 500028, 500029, 500030,
            500031, 500032, 500033, 500034, 500035, 500036, 500037, 500038, 500039, 500040,
            500041, 500042, 500043, 500045, 500046, 500047, 500048, 500049, 500050,
            500051, 500052, 500053, 500054, 500055, 500056, 500057, 500058, 500059, 500060,
            500061, 500062, 500063, 500064, 500065, 500066, 500067, 500068, 500069, 500070,
            500071, 500072, 500073, 500074, 500075, 500076, 500077, 500078, 500079, 500080,
            600001, 600002, 600003, 600004, 600005, 600006, 600007, 600008, 600009, 600010,
            700001, 700002, 700003, 700004, 700005, 700006, 700007, 700008, 700009, 700010,
            700011, 700012, 700013, 700014, 700015,
            800001, 800002, 800003, 800004, 800005, 800006, 800007, 800008, 800009, 800010,
            900001, 900002, 900003, 900004, 900005, 900006, 900007, 900008, 900009, 900010
        )
        const val NOT_MEASURED: Byte = -0x01

        /** 最近一次从手表收到的实时心率，供无心率带时共享轨迹回退使用 */
        @Volatile
        var latestHeartRate: Int = 0
            private set

        @Volatile
        var latestHeartRateTime: Long = 0
            private set

        fun clearLatestHeartRate() {
            latestHeartRate = 0
            latestHeartRateTime = 0
        }

        @Volatile
        private var singleton: VitaloopWatchManager? = null

        val shared: VitaloopWatchManager? get() = singleton

        /** 进程内唯一实例：后台服务与 Activity 必须共用同一条链路，否则两边各连一次手表 */
        fun getInstance(context: Context): VitaloopWatchManager {
            singleton?.let { return it }
            synchronized(this) {
                singleton?.let { return it }
                return VitaloopWatchManager(context.applicationContext).also {
                    it.init()
                    singleton = it
                }
            }
        }
    }

    /** JSON 事件回调（主线程外调用，注意线程安全） */
    @Volatile
    var onEvent: ((JSONObject) -> Unit)? = null

    /** 状态回调：connecting / authenticating / ready / disconnected / failed:msg */
    @Volatile
    var onState: ((String) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val pendingEvents = ConcurrentLinkedQueue<JSONObject>()
    private val paramsProvider = HuaweiPacket.ParamsProvider()
    private val coordinator by lazy { HuaweiCoordinator() }
    private val responseManager = HuaweiResponseManager(this)
    private val ephemerisManager by lazy { HuaweiEphemerisManager(this) }
    private val p2pManager by lazy { HuaweiP2PManager(this) }
    private val huaweiUploadManager by lazy { HuaweiUploadManager(this) }
    private var transport: HuaweiBtTransport? = null
    private var gbDevice = GBDevice("", "")
    private var protocolVersion: Byte = 0
    private var firstConnection = false
    private var androidId = ""
    private var macAddress = ""
    private var connectThread: Thread? = null
    @Volatile private var connectGeneration = 0
    private var syncThread: Thread? = null
    private var p2pThread: Thread? = null
    @Volatile private var syncing = false
    /** 健康数据链从发出第一条请求到最终回调之间都为 true，避免和 P2P/运动链交叉发包 */
    @Volatile private var roundActive = false
    @Volatile private var roundGeneration = 0
    @Volatile private var p2pSyncing = false
    @Volatile private var alarmSyncing = false
    @Volatile private var weatherSyncing = false
    @Volatile private var weatherFetching = false
    @Volatile private var weatherPending = false
    private val weatherLock = Any()
    @Volatile private var cachedWeatherSpec: WeatherSpec? = null
    @Volatile private var cachedWeatherAtMs = 0L
    @Volatile private var userInitiatedDisconnect = false
    private var lastSpo2Bucket = -1L
    private var lastRestingHrDay = -1L
    private var lastEphemerisCheckAt = 0L
    @Volatile private var p2pAvailable = false
    private var lastBatteryStatus: ByteArray? = null
    private var lastEmittedBattery = -1
    private var chargingHint = false
    private var chargingStatusKnown = false
    @Volatile private var wearStatusCode: Int? = null
    @Volatile private var lastWearPushAt = 0L
    @Volatile private var wearQueryInFlight = false
    private var wearThread: Thread? = null
    @Volatile private var p2pSetupRunning = false
    @Volatile private var lastP2PSyncAt = 0L
    @Volatile private var p2pSyncOk = false
    @Volatile private var p2pDictEventCount = 0
    @Volatile private var lastLinkBusyAt = 0L
    @Volatile private var lastStressFileSyncAt = 0L
    @Volatile private var lastSleepFileSyncAt = 0L
    @Volatile private var lastSleepDetailSyncAt = 0L
    private var lastStoredStressBucket = -1L
    private var lastStoredTemperatureBucket = -1L
    @Volatile private var gpsParametersResponse: GpsAndTime.GpsParameters.Response? = null
    @Volatile private var watchGpsStreaming = false
    @Volatile private var watchGpsStopAt = 0L
    private var watchGpsWorker: Thread? = null
    private val watchGpsPoints = java.util.concurrent.LinkedBlockingQueue<JSONObject>()
    @Volatile private var lastStreamedLocation: Location? = null
    private val watchGpsPointListener: (JSONObject) -> Unit = { point ->
        if (watchGpsStreaming) {
            watchGpsPoints.offer(point)
            while (watchGpsPoints.size > 8) watchGpsPoints.poll()
        }
    }
    @Volatile private var planPushRunning = false
    @Volatile private var routePushRunning = false
    @Volatile private var mapPushRunning = false
    @Volatile private var mapStatus = ""
    private val mapLock = Any()
    private var calendarObserver: ContentObserver? = null
    @Volatile private var toolBusy = false
    @Volatile private var toolGeneration = 0
    private val toolLock = Any()
    @Volatile private var cameraRemoteEnabled = false
    @Volatile private var findPhoneEnabled = true
    @Volatile private var lastToolMessage = ""
    private var findPhoneRingtone: Ringtone? = null
    private var mediaSessionListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private var appDeviceParams: App.AppDeviceParams? = null
    private val recentWatchfaceConfirms = ConcurrentHashMap<String, Long>()
    @Volatile private var currentMusicTitle: String? = null
    @Volatile private var currentMusicArtist: String? = null
    @Volatile private var currentMusicPlaying = false

    private data class InstalledApp(
        val packageName: String,
        val name: String,
        val version: String,
        val versionCode: Int,
    )

    private data class InstalledWatchface(
        val fileName: String,
        val version: String,
        val type: Int,
        val current: Boolean,
        val factory: Boolean,
    )

    private data class MusicTrack(
        val id: Int,
        val title: String,
        val artist: String,
        val fileName: String,
    )

    private data class MusicPlaylist(
        val id: Int,
        val name: String,
        val frameCount: Int,
        val musicIds: List<Int> = emptyList(),
    )

    private data class MusicUploadItem(
        val path: String,
        val name: String,
        val title: String,
        val artist: String,
    )

    private val installedApps = ArrayList<InstalledApp>()
    private val installedWatchfaces = ArrayList<InstalledWatchface>()
    private val watchfaceNames = LinkedHashMap<String, String>()
    private var watchfaceDeviceParams: Watchface.WatchfaceDeviceParams? = null
    @Volatile private var currentWatchface = ""
    @Volatile private var maxContactsCount = 20
    @Volatile private var watchfaceUploadProgress = -1
    @Volatile private var watchfaceInstallStatus = ""
    @Volatile private var appUploadProgress = -1
    @Volatile private var appInstallStatus = ""
    @Volatile private var musicUploadProgress = -1
    @Volatile private var musicUploadStatus = ""
    @Volatile private var watchMusicCapacity = ""
    private val watchMusicTracks = LinkedHashMap<Int, MusicTrack>()
    private val watchMusicPlaylists = ArrayList<MusicPlaylist>()
    private val musicUploadQueue = ConcurrentLinkedQueue<MusicUploadItem>()
    @Volatile private var musicUploadInFlight: MusicUploadItem? = null
    @Volatile private var musicUploadCancelled = false
    @Volatile private var musicSyncActive = false
    private var musicFrameCount = 0
    private var musicFrameLimit = 0
    private var musicCurrentFrame = 0
    private var musicEndFrame = 65535
    private var musicPlaylistFrameCounts = ArrayList<Int>()
    private var musicPlaylistIndex = 0
    private var musicPlaylistPage = 0
    private val musicPlaylistPageIds = ArrayList<Int>()

    // 运动记录：协议链是「汇总 → 采样 → 配速 → GPS 文件」，一条运动的数据要攒齐后
    // 才能一次性抛给 Rust（Dart 侧按批入库，半条记录没有意义）。
    private val fileDownloadManager by lazy { HuaweiFileDownloadManager(this) }
    private val workoutAccum = ConcurrentHashMap<Long, WorkoutAccum>()
    @Volatile private var workoutSyncing = false
    @Volatile private var workoutWindowEnd = 0
    private var workoutWatchdog: Thread? = null
    private val workoutLiveTracker by lazy {
        WorkoutLiveTracker(appContext, this) { emit(it) }
    }

    private data class WorkoutAccum(
        val number: Short,
        var totals: Workout.WorkoutTotals.Response? = null,
        val samples: MutableList<Workout.WorkoutData.Response.Data> = mutableListOf(),
        val pace: MutableList<Workout.WorkoutPace.Response.Block> = mutableListOf(),
        val segments: MutableList<Workout.WorkoutSwimSegments.Response.Block> = mutableListOf(),
        var track: List<HuaweiGpsParser.GpsPoint> = emptyList(),
        var gpsDone: Boolean = false,
    )

    // GPS 轨迹下载失败的运动（多为隧道/链路忙/文件未就绪）。汇总已入库、轨迹缺失，
    // 但增量游标一过就再也不会回拉。这里记下这些运动，让后续同步在冷却后回头补拉，
    // 补到的轨迹靠 Rust 侧 merge 填回同一条记录。轨迹一旦拉全就从表里移除。
    private data class GpsRetryEntry(val startMs: Long, val lastAttemptMs: Long)
    private val gpsRetryLock = Any()
    private var gpsRetry: LinkedHashMap<Int, GpsRetryEntry> = LinkedHashMap()
    @Volatile private var gpsRetryLoaded = false

    private fun loadGpsRetry() {
        if (gpsRetryLoaded) return
        synchronized(gpsRetryLock) {
            if (gpsRetryLoaded) return
            gpsRetry = LinkedHashMap()
            val raw = watchPrefs().getString(KEY_WORKOUT_GPS_RETRY, null)
            if (!raw.isNullOrBlank()) {
                runCatching {
                    val arr = JSONArray(raw)
                    for (i in 0 until arr.length()) {
                        val o = arr.optJSONObject(i) ?: continue
                        val number = o.optInt("n")
                        val startMs = o.optLong("s")
                        val last = o.optLong("a")
                        if (number > 0 && startMs > 0) gpsRetry[number] = GpsRetryEntry(startMs, last)
                    }
                }
            }
            gpsRetryLoaded = true
        }
    }

    private fun persistGpsRetryLocked() {
        val arr = JSONArray()
        for ((number, e) in gpsRetry) {
            arr.put(JSONObject().put("n", number).put("s", e.startMs).put("a", e.lastAttemptMs))
        }
        watchPrefs().edit().putString(KEY_WORKOUT_GPS_RETRY, arr.toString()).apply()
    }

    /** GPS 下载失败：登记这条运动，等待冷却后回头补拉 */
    private fun recordGpsRetry(number: Int, startMs: Long) {
        if (number <= 0 || startMs <= 0) return
        loadGpsRetry()
        synchronized(gpsRetryLock) {
            val prev = gpsRetry[number]
            // 已有更近的失败时间戳就保留，避免同一轮多次回调把冷却时间往后推
            val last = prev?.lastAttemptMs ?: 0L
            gpsRetry[number] = GpsRetryEntry(startMs, last)
            persistGpsRetryLocked()
        }
    }

    /** 轨迹拉全：从补拉表移除，之后不再为它回退窗口 */
    private fun clearGpsRetry(number: Int) {
        if (number <= 0) return
        loadGpsRetry()
        synchronized(gpsRetryLock) {
            if (gpsRetry.remove(number) != null) persistGpsRetryLocked()
        }
    }

    /**
     * 计算需要补拉的最老运动的起始秒：只取冷却到期且仍在保留期内的条目，
     * 顺手淘汰过期条目。返回 null 表示无需为补特拉回窗口。
     * 命中即标记本轮已尝试（lastAttemptMs=now），把下次尝试推后一个冷却周期。
     */
    private fun dueGpsRetryFloorSec(end: Int): Int? {
        loadGpsRetry()
        val now = System.currentTimeMillis()
        val cutoff = now - WORKOUT_RETRY_MAX_AGE_MS
        var oldest: Long? = null
        synchronized(gpsRetryLock) {
            var changed = false
            val it = gpsRetry.entries.iterator()
            while (it.hasNext()) {
                val e = it.next()
                if (e.value.startMs < cutoff) {
                    it.remove()
                    changed = true
                    continue
                }
                if (now - e.value.lastAttemptMs >= WORKOUT_RETRY_COOLDOWN_MS) {
                    e.setValue(e.value.copy(lastAttemptMs = now))
                    oldest = if (oldest == null) e.value.startMs else minOf(oldest!!, e.value.startMs)
                    changed = true
                }
            }
            if (changed) persistGpsRetryLocked()
        }
        val ms = oldest ?: return null
        val sec = (ms / 1000).toInt() - 1800
        return sec.coerceAtLeast(end - WORKOUT_FIRST_WINDOW_SEC)
    }

    // 本轮同步收到的数据条数：只写「同步完成」四个字查不出任何问题，
    // 必须带上耗时和条数才知道是「没数据」还是「拉了没落库」
    private val roundLock = Any()
    @Volatile private var roundEvents = 0
    @Volatile private var roundStartedAt = 0L

    // ==================== 对外 API ====================

    fun init() {
        GBApplication.init(appContext)
        cameraRemoteEnabled = watchPrefs().getBoolean(KEY_CAMERA_REMOTE, false)
        findPhoneEnabled = watchPrefs().getBoolean(KEY_FIND_PHONE, true)
    }

    @Synchronized
    fun connect(
        address: String,
        name: String,
        authKey: String = "",
        fakeAndroidId: String = "",
        account: String = "",
        huaweiAddress: String = "",
    ) {
        if (connectThread?.isAlive == true) {
            Log.i(TAG, "已有连接流程在跑，忽略重复连接 $address")
            return
        }
        userInitiatedDisconnect = false
        chargingStatusKnown = false
        chargingHint = false
        lastEmittedBattery = -1
        watchPrefs().edit().putString(KEY_ADDRESS, address).putString(KEY_NAME, name)
            .putBoolean(KEY_USER_DISCONNECTED, false).apply()
        val gen = ++connectGeneration
        val th = Thread({
            try {
                setState("connecting")
                val prefs = GBApplication.getDeviceSpecificSharedPrefs(address)
                // 旧版迁移来的凭据优先覆盖：首次抢跑时原生可能已经生成过一个随机
                // fake_android_id，只“为空才写”会让 authkey 与 fake id 不是同一对，
                // 手表 HiChain 会直接返回 -1。
                if (authKey.isNotEmpty()) {
                    prefs.edit().putString("authkey", authKey).apply()
                }
                if (fakeAndroidId.isNotEmpty()) {
                    prefs.edit().putString("fake_android_id", fakeAndroidId).apply()
                }
                // 旧版迁移来的华为账号：SendExtendedAccountRequest 只认这个 prefs，
                // 没有它手表不会把数据字典当成官方健康 App 的请求放行。
                if (account.isNotEmpty()) {
                    prefs.edit().putString("huawei_account", account).apply()
                }
                // huawei_address 是手机侧稳定身份，不是手表的蓝牙 MAC；首次抢跑可能
                // 写成了手表 MAC，迁移值存在时必须纠正回来。
                if (huaweiAddress.isNotEmpty()) {
                    prefs.edit().putString("huawei_address", huaweiAddress).apply()
                }
                firstConnection = prefs.getString("authkey", null).isNullOrEmpty()
                Log.i(
                    TAG,
                    "认证凭据: authKeyLen=${prefs.getString("authkey", null)?.length ?: 0} " +
                        "fakeAndroidIdLen=${prefs.getString("fake_android_id", null)?.length ?: 0} " +
                        "account=${if (prefs.getString("huawei_account", null).isNullOrEmpty()) "empty" else "set"} " +
                        "firstConnection=$firstConnection",
                )
                gbDevice = GBDevice(address, name)
                createRandomMacAddress()
                createAndroidID()
                val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(address)
                    ?: throw IOException("无法获取蓝牙设备 $address")
                val t = HuaweiBtTransport(device)
                t.shouldAbort = { gen != connectGeneration || userInitiatedDisconnect }
                t.onData = { data ->
                    responseManager.handleData(data)
                }
                t.onDisconnected = { err ->
                    if (transport === t) {
                        transport = null
                        workoutLiveTracker.onDisconnected()
                        stopWatchGpsStream(graceMs = 0L)
                        gpsParametersResponse = null
                        resetP2PState()
                        // 文件下载是请求-应答驱动的：断链后挂起的回调不会再落地，
                        // 不主动释放会让 isBusy 永久卡住，重连后睡眠/压力/GPS 全部只入队不执行。
                        fileDownloadManager.abortAll()
                        responseManager.reset()
                        emitDevice(false)
                        setState(if (userInitiatedDisconnect) "disconnected" else "disconnected:${err?.message ?: "对端断开"}")
                    }
                }
                val stale = transport
                transport = null
                try { stale?.close() } catch (_: Exception) {}
                responseManager.reset()
                addLog("正在建立 RFCOMM 链路 → $macAddress")
                setState("connecting")
                t.connect()
                if (gen != connectGeneration) {
                    // 连的过程中用户断开或另起了一次连接，这条链路作废
                    try { t.close() } catch (_: Exception) {}
                    return@Thread
                }
                transport = t
                addLog("链路已建立，开始 HiChain 认证")
                initializeDevice()
                // 握手是异步的（initializeDevice 只是把第一条请求发出去）。
                // 这个线程必须活着等到 ready/failed，否则前台 Activity 和后台服务
                // 几乎同时调用 connect() 时都会看到“没有连接线程”，各建一条 RFCOMM，
                // 手表会把后到的请求当成冲突，电量回 0x186A4、P2P 回 0xCF。
                val handshakeDeadline = System.currentTimeMillis() + 90_000
                while (System.currentTimeMillis() < handshakeDeadline &&
                    gen == connectGeneration && transport === t &&
                    state != "ready" && state != "disconnected" && !state.startsWith("failed")
                ) {
                    Thread.sleep(200)
                }
            } catch (e: Exception) {
                Log.e(TAG, "连接失败", e)
                // 用户已经断开或已另起连接时，这条失败信息会把「已断开」覆盖成「连接失败」
                if (gen == connectGeneration) setState("failed:${e.message ?: e.javaClass.simpleName}")
            } finally {
                // 线程结束后必须释放引用：connectThread 永远指向一条已死线程时，
                // keepAlive 会一直以为“还有连接在跑”，再也不重连。
                if (connectThread === Thread.currentThread()) connectThread = null
            }
        }, "VitaloopWatchConnect")
        connectThread = th
        th.start()
    }

    fun disconnect() {
        userInitiatedDisconnect = true
        wearThread?.interrupt()
        wearThread = null
        wearQueryInFlight = false
        WearStateBridge.publish(appContext, WEAR_STATUS_OFF_WRIST, "断连")
        workoutLiveTracker.onDisconnected()
        stopWatchGpsStream(graceMs = 0L)
        gpsParametersResponse = null
        clearLatestHeartRate()
        watchPrefs().edit().putBoolean(KEY_USER_DISCONNECTED, true).apply()
        // 连接线程可能正卡在 60 秒的 RFCOMM 页超时里，中断它并不能立刻放手；
        // 换代号让在途连接在成功那一刻自己发现「用户已经不要这条链路了」并关闭。
        connectGeneration++
        syncThread?.interrupt()
        val t = transport
        transport = null
        resetP2PState()
        try { t?.close() } catch (_: Exception) {}
        fileDownloadManager.abortAll()
        responseManager.reset()
        emitDevice(false)
        setState("disconnected")
    }

    /** 断链后 P2P 注册与 0x28 文件槽都失效，重连时必须重新握手。 */
    private fun resetP2PState() {
        try {
            p2pManager.unregisterAllService()
        } catch (e: Exception) {
            FileLogger.e(TAG, "P2P 服务注销失败", e)
        }
        p2pAvailable = false
        p2pSetupRunning = false
        unregisterMediaSessionListener()
        stopFindPhoneRing()
        synchronized(toolLock) {
            toolBusy = false
            toolGeneration++
        }
        try {
            huaweiUploadManager.setFileUploadInfo(null)
        } catch (e: Exception) {
            FileLogger.e(TAG, "清理文件上传槽失败", e)
        }
        unregisterCalendarObserver()
        stopCallForwarding()
    }

    /** 用户是否主动断开过——后台保活必须尊重这个选择，不能半夜把手表重新连上 */
    fun isUserDisconnected(): Boolean =
        userInitiatedDisconnect || watchPrefs().getBoolean(KEY_USER_DISCONNECTED, false)

    data class SavedWatch(val address: String, val name: String)

    fun savedWatch(): SavedWatch? {
        val address = watchPrefs().getString(KEY_ADDRESS, null) ?: return null
        if (address.isBlank()) return null
        return SavedWatch(address, watchPrefs().getString(KEY_NAME, "HUAWEI WATCH") ?: "HUAWEI WATCH")
    }

    /**
     * 后台保活：未连接就重连，已连接就补一次同步。
     * 连接线程可能正卡在 RFCOMM 页超时上（一次尝试约 60 秒），绝不能并发再开一条。
     */
    fun keepAlive() {
        if (!isAutoSyncEnabled() || isUserDisconnected()) return
        if (connectThread?.isAlive == true) return
        val saved = savedWatch() ?: return
        // 认证凭据由 Dart bootstrap 从 Rust 侧取出后才通过 connect() 落到设备级 prefs。
        // 这之前抢先连接会把已配对手表误判成首次 HiChain，等 Flutter 侧先发起。
        val hasAuthKey = !GBApplication.getDeviceSpecificSharedPrefs(saved.address)
            .getString("authkey", null).isNullOrEmpty()
        if (!hasAuthKey) return
        when (state) {
            "ready" -> if (transport != null) syncOnce()
            "connecting", "authenticating", "configuring" -> Unit
            else -> connect(saved.address, saved.name)
        }
    }

    private fun watchPrefs() = appContext.getSharedPreferences(WATCH_PREFS, Context.MODE_PRIVATE)

    /** 后台自动同步开关，默认开——独立运行的前提就是没人盯着也要同步 */
    fun isAutoSyncEnabled(): Boolean = watchPrefs().getBoolean(KEY_AUTO_SYNC, true)

    fun setAutoSyncEnabled(enabled: Boolean) {
        watchPrefs().edit().putBoolean(KEY_AUTO_SYNC, enabled).apply()
    }

    fun isWeatherSyncEnabled(): Boolean =
        watchPrefs().getBoolean(KEY_WEATHER_SYNC, true)

    fun setWeatherSyncEnabled(enabled: Boolean) {
        watchPrefs().edit().putBoolean(KEY_WEATHER_SYNC, enabled).apply()
        addLog("天气同步开关：${if (enabled) "开" else "关"}")
        if (enabled && state == "ready") syncWeather(force = true)
    }

    /**
     * 拉当前天气并下发手表。网络请求放在独立线程，发送前等其它同步链空闲，
     * 避免和健康/运动/闹钟链共用 RFCOMM 时把响应串错。
     */
    fun syncWeather(force: Boolean = false) {
        if (!isWeatherSyncEnabled() || transport == null) return
        val cached = cachedWeatherSpec
        val cacheAge = System.currentTimeMillis() - cachedWeatherAtMs
        if (!force && cached != null && cacheAge < WEATHER_CACHE_TTL_MS) {
            weatherPending = true
            Thread({ sendPendingWeather() }, "VitaloopWeather").apply { start() }
            return
        }
        if (weatherFetching) {
            weatherPending = true
            return
        }
        weatherFetching = true
        weatherPending = true
        Thread({
            try {
                val location = VitaloopGpsManager.getInstance(appContext)
                    .currentLocation(10_000L)
                if (location == null) {
                    addLog("天气同步：没有可用的定位，跳过本轮")
                    return@Thread
                }
                addLog("天气同步：正在获取当前位置天气…")
                val spec = WatchWeatherClient.fetch(appContext, location, null)
                if (spec == null) {
                    addLog("天气同步：天气接口失败")
                    return@Thread
                }
                cachedWeatherSpec = spec
                cachedWeatherAtMs = System.currentTimeMillis()
                weatherPending = true
                sendPendingWeather()
            } finally {
                weatherFetching = false
            }
        }, "VitaloopWeather").apply { start() }
    }

    private fun sendPendingWeather() {
        if (!weatherPending) return
        val spec = cachedWeatherSpec ?: return
        val deadline = System.currentTimeMillis() + 60_000L
        while (System.currentTimeMillis() < deadline) {
            if (state != "ready" || transport == null) return
            synchronized(weatherLock) {
                if (!weatherSyncing &&
                    !syncing && !roundActive && !workoutSyncing &&
                    !p2pSyncing && !alarmSyncing
                ) {
                    weatherSyncing = true
                    try {
                        sendWeatherToWatch(spec)
                        weatherPending = false
                    } finally {
                        weatherSyncing = false
                    }
                    return
                }
            }
            try {
                Thread.sleep(800L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
        addLog("天气同步：等待其它同步链空闲超时，稍后重试")
    }

    private fun sendWeatherToWatch(spec: WeatherSpec) {
        try {
            if (!coordinator.supportsWeather()) {
                addLog("手表不支持天气同步")
                return
            }
            val settings = Weather.Settings().apply {
                uvIndexSupported = coordinator.supportsWeatherUvIndex()
            }
            val startReq = SendWeatherStartRequest(this, settings)
            var lastReq: Request = startReq
            if (coordinator.supportsWeatherUnit()) {
                val unitReq = SendWeatherUnitRequest(this)
                lastReq.nextRequest(unitReq)
                lastReq = unitReq
            }
            val supportReq = SendWeatherSupportRequest(this, settings)
            lastReq.nextRequest(supportReq)
            lastReq = supportReq
            if (coordinator.supportsWeatherExtended()) {
                val extReq = SendWeatherExtendedSupportRequest(this, settings)
                lastReq.nextRequest(extReq)
                lastReq = extReq
            }
            if (coordinator.supportsWeatherMoonRiseSet()) {
                val sunMoonReq = SendWeatherSunMoonSupportRequest(this, settings)
                lastReq.nextRequest(sunMoonReq)
                lastReq = sunMoonReq
            }
            val currentReq = SendWeatherCurrentRequest(this, settings, spec)
            lastReq.nextRequest(currentReq)
            lastReq = currentReq
            if (coordinator.supportsWeatherForecasts()) {
                val forecastReq = SendWeatherForecastRequest(this, settings, spec)
                lastReq.nextRequest(forecastReq)
                lastReq = forecastReq
            }
            startReq.doPerform()
            addLog("天气已同步到手表：${spec.location} ${spec.currentTemp - 273}°C")
        } catch (e: Exception) {
            addLog("天气同步失败：${e.message ?: e.javaClass.simpleName}")
            FileLogger.e(TAG, "天气同步失败", e)
        }
    }

    val isConnected: Boolean get() = transport != null && gbDevice.address.isNotBlank() && state == "ready"
    @Volatile var state: String = "disconnected"
        private set

    private fun setState(s: String) {
        if (s != state) addLog("连接状态：$s")
        state = s
        onState?.invoke(s)
    }

    /**
     * 连接与同步日志。走事件通道交给 Rust 落库，手表页「连接日志」详情页读出来；
     * 只进 logcat 的话，用户点开时早就滚掉了，查不到昨天为什么没连上。
     */
    private fun addLog(msg: String) {
        Log.i(TAG, msg)
        emit(JSONObject().put("t", "log").put("ts", System.currentTimeMillis()).put("msg", msg))
    }

    private fun emit(obj: JSONObject) {
        if (obj.optString("t") != "log") synchronized(roundLock) { roundEvents++ }
        val callback = onEvent
        if (callback == null) {
            // 用户划掉 App 后 Activity 没了，但后台服务仍在同步——先攒着，界面回来时补投
            if (pendingEvents.size < MAX_BUFFERED_EVENTS) pendingEvents.add(obj)
            return
        }
        try { callback(obj) } catch (e: Exception) { Log.e(TAG, "emit failed", e) }
    }

    /**
     * 电量与连接状态。GetBatteryLevelRequest 只把读数写进内存里的 GBDevice，
     * 不抛事件的话 devices 表永远是旧版导入时的 0，手表页就会「已连接但电量 --」。
     */
    private fun emitDevice(connected: Boolean) {
        val level = gbDevice.batteryLevel
        // TLV 0x03 是充电状态：1=充电中，其它=未充电。老设备不回这个字段时，
        // 才退回用连续两次同步的电量趋势判断（上升视为充电，下降视为拔出）。
        if (!chargingStatusKnown && level >= 0 && lastEmittedBattery >= 0) {
            if (level > lastEmittedBattery) chargingHint = true
            else if (level < lastEmittedBattery) chargingHint = false
        }
        if (level >= 0) lastEmittedBattery = level
        emit(JSONObject()
            .put("t", "device")
            .put("battery", level)
            .put("charging", chargingHint)
            .put("connected", connected)
            .put("name", gbDevice.name)
            .put("address", gbDevice.address))
    }

    /**
     * 电量的 TLV 0x03 是充电/在座状态，按 Gadgetbridge 的 Huawei 实现：
     * status[i] == 1 表示第 i 块电池正在充电，其它值表示未充电。
     */
    private fun recordBatteryStatus(status: ByteArray) {
        lastBatteryStatus = status.copyOf()
        val charging = status.firstOrNull()?.toInt() == 1
        chargingStatusKnown = true
        chargingHint = charging
        addLog(
            "电量状态：${if (charging) "充电中" else "未充电"}（原始 ${status.joinToString(" ") { "%02X".format(it) }}）"
        )
        // onLevelReceived 先于本回调执行，补发一次让界面立刻拿到真实充电状态
        emitDevice(true)
    }

    /** 界面重新挂载时取回离线期间产生的数据事件 */
    fun drainPendingEvents(): List<JSONObject> {
        val drained = ArrayList<JSONObject>(pendingEvents.size)
        while (true) {
            val item = pendingEvents.poll() ?: break
            drained.add(item)
        }
        return drained
    }

    // ==================== 手表工具（联系人 / 表盘 / 音乐 / 应用 / 遥控） ====================

    fun watchToolsStatusJson(): String {
        val appArray = JSONArray()
        synchronized(installedApps) {
            installedApps.forEach {
                appArray.put(
                    JSONObject()
                        .put("package", it.packageName)
                        .put("name", it.name)
                        .put("version", it.version)
                        .put("versionCode", it.versionCode)
                )
            }
        }
        val faceArray = JSONArray()
        val faceNames = synchronized(watchfaceNames) { HashMap(watchfaceNames) }
        synchronized(installedWatchfaces) {
            installedWatchfaces.forEach {
                faceArray.put(
                    JSONObject()
                        .put("file", it.fileName)
                        .put("version", it.version)
                        .put("type", it.type)
                        .put("current", it.current)
                        .put("factory", it.factory)
                        .put("name", faceNames[it.fileName]?.takeIf { name -> name.isNotBlank() } ?: it.fileName)
                )
            }
        }
        val trackArray = JSONArray()
        synchronized(watchMusicTracks) {
            watchMusicTracks.values.forEach {
                trackArray.put(
                    JSONObject()
                        .put("id", it.id)
                        .put("title", it.title)
                        .put("artist", it.artist)
                        .put("file", it.fileName)
                )
            }
        }
        val playlistArray = JSONArray()
        synchronized(watchMusicPlaylists) {
            watchMusicPlaylists.forEach {
                playlistArray.put(
                    JSONObject()
                        .put("id", it.id)
                        .put("name", it.name)
                        .put("count", it.musicIds.size)
                )
            }
        }
        val params = watchfaceDeviceParams
        return JSONObject()
            .put("connected", state == "ready")
            .put("busy", toolBusy)
            .put("message", lastToolMessage)
            .put("cameraRemote", cameraRemoteEnabled)
            .put("findPhone", findPhoneEnabled)
            .put("contactsMax", maxContactsCount)
            .put("wearStatus", wearStatusCode ?: -1)
            .put("wearLabel", wearStatusLabel())
            .put("wristUnlock", WearStateBridge.readEnabled(appContext))
            .put("wearHeartbeatAgeMs", WearStateBridge.heartbeatAgeMs(appContext))
            .put("wearGrantMissing", WearStateBridge.grantMissing())
            .put("apps", appArray)
            .put("watchfaces", faceArray)
            .put("currentWatchface", currentWatchface)
            .put(
                "watchfaceDevice",
                params?.let {
                    JSONObject()
                        .put("version", it.maxVersion)
                        .put("width", it.width)
                        .put("height", it.height)
                        .put("fileType", it.supportFileType.toInt())
                } ?: JSONObject()
            )
            .put("watchfaceUploadProgress", watchfaceUploadProgress)
            .put("watchfaceUploadStatus", watchfaceInstallStatus)
            .put("appUploadProgress", appUploadProgress)
            .put("appUploadStatus", appInstallStatus)
            .put("musicCapacity", watchMusicCapacity)
            .put("musicUploadProgress", musicUploadProgress)
            .put("musicUploadStatus", musicUploadStatus)
            .put("musicUploadRemaining", musicUploadQueue.size + if (musicUploadInFlight != null) 1 else 0)
            .put("mapPushRunning", mapPushRunning)
            .put("mapStatus", mapStatus)
            .put("mapSupported", coordinator.supportsExpandCapability(201))
            .put("tracks", trackArray)
            .put("playlists", playlistArray)
            .toString()
    }

    private fun emitTools() {
        emit(JSONObject().put("t", "watch_tools").put("status", JSONObject(watchToolsStatusJson())))
    }

    private fun setToolMessage(message: String) {
        lastToolMessage = message
        addLog(message)
        emitTools()
    }

    private fun beginTool(name: String, timeoutMs: Long = TOOL_TIMEOUT_MS): Int? {
        val generation: Int
        synchronized(toolLock) {
            if (toolBusy) {
                setToolMessage("上一项手表操作还在进行，请稍候")
                return null
            }
            if (state != "ready" || transport == null) {
                setToolMessage("$name：手表未连接")
                return null
            }
            if (syncing || roundActive || workoutSyncing || p2pSyncing || alarmSyncing || weatherSyncing) {
                setToolMessage("$name：手表正在同步，请稍后再试")
                return null
            }
            generation = ++toolGeneration
            toolBusy = true
        }
        lastToolMessage = name
        emitTools()
        Thread({
            try {
                Thread.sleep(timeoutMs)
            } catch (_: InterruptedException) {
                return@Thread
            }
            synchronized(toolLock) {
                if (!toolBusy || toolGeneration != generation) return@Thread
            }
            setToolMessage("$name：等手表响应超时")
            endTool(generation)
        }, "VitaloopToolTimeout").apply { isDaemon = true; start() }
        return generation
    }

    private fun endTool(generation: Int? = null) {
        synchronized(toolLock) {
            if (generation != null && generation != toolGeneration) return
            toolGeneration++
            toolBusy = false
        }
        emitTools()
    }

    fun isCameraRemoteEnabled(): Boolean = cameraRemoteEnabled

    fun setCameraRemoteEnabled(enabled: Boolean) {
        cameraRemoteEnabled = enabled
        watchPrefs().edit().putBoolean(KEY_CAMERA_REMOTE, enabled).apply()
        setToolMessage(if (enabled) "遥控拍照已开启" else "遥控拍照已关闭")
    }

    fun setFindPhoneEnabled(enabled: Boolean) {
        findPhoneEnabled = enabled
        watchPrefs().edit().putBoolean(KEY_FIND_PHONE, enabled).apply()
        if (!enabled) stopFindPhoneRing()
        setToolMessage(if (enabled) "查找手机已开启" else "查找手机已关闭")
    }

    fun isDndEnabled(): Boolean = dndMode() != "off"

    private fun settingPrefKey(key: String): String = KEY_WATCH_SETTING_PREFIX + key

    private fun watchSettingDefault(key: String): Boolean =
        WATCH_SETTING_DEFAULTS[key] ?: false

    /** 读取单个手表开关，默认值与旧版 WatchSetting 一致。 */
    fun getWatchSetting(key: String): Boolean =
        watchPrefs().getBoolean(settingPrefKey(key), watchSettingDefault(key))

    /** Flutter 一次性读取全部手表开关。 */
    fun watchSettingsJson(): String {
        val out = JSONObject()
        WATCH_SETTING_DEFAULTS.forEach { (key, _) ->
            out.put(key, getWatchSetting(key))
        }
        return out.toString()
    }

    /** 把本机开关状态写入 Gadgetbridge 请求类读取的设备偏好。 */
    private fun applyGbWatchSettingPrefs() {
        val prefs = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
        val editor = prefs.edit()
            .putBoolean(HuaweiConstants.PREF_HUAWEI_TRUSLEEP, getWatchSetting("sleep"))
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_HEARTRATE_AUTOMATIC_ENABLE,
                getWatchSetting("heart_rate")
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_INACTIVITY_ENABLE,
                getWatchSetting("sedentary")
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_SPO_AUTOMATIC_ENABLE,
                getWatchSetting("spo2")
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_LIFTWRIST_NOSHED,
                getWatchSetting("lift_wrist")
            )
            .putBoolean(
                MiBandConst.PREF_MI2_ROTATE_WRIST_TO_SWITCH_INFO,
                getWatchSetting("rotate_wrist")
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_NOTIFICATION_ENABLE,
                getWatchSetting("notification")
            )
            .putBoolean(
                HuaweiConstants.PREF_HUAWEI_CONTINUOUS_SKIN_TEMPERATURE_MEASUREMENT,
                getWatchSetting("temperature")
            )
        // 久坐提醒的时间/阈值/星期只补默认值，避免覆盖手表端已调好的配置。
        if (!prefs.contains(DeviceSettingsPreferenceConst.PREF_INACTIVITY_THRESHOLD)) {
            editor.putString(DeviceSettingsPreferenceConst.PREF_INACTIVITY_THRESHOLD, "60")
        }
        if (!prefs.contains(DeviceSettingsPreferenceConst.PREF_INACTIVITY_START)) {
            editor.putString(DeviceSettingsPreferenceConst.PREF_INACTIVITY_START, "06:00")
        }
        if (!prefs.contains(DeviceSettingsPreferenceConst.PREF_INACTIVITY_END)) {
            editor.putString(DeviceSettingsPreferenceConst.PREF_INACTIVITY_END, "23:00")
        }
        if (!prefs.contains(DeviceSettingsPreferenceConst.PREF_INACTIVITY_MO)) {
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_MO, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_TU, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_WE, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_TH, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_FR, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_SA, true)
            editor.putBoolean(DeviceSettingsPreferenceConst.PREF_INACTIVITY_SU, true)
        }
        editor.apply()
    }

    private fun watchSettingRequest(key: String, enabled: Boolean): Request? = when (key) {
        "sleep" -> SetTruSleepRequest(this)
        "heart_rate" -> SetAutomaticHeartrateRequest(this)
        "sedentary" -> SetActivityReminderRequest(this)
        "spo2" -> SetAutomaticSpoRequest(this)
        "lift_wrist" -> SetActivateOnLiftRequest(this)
        "rotate_wrist" -> SetNavigateOnRotateRequest(this)
        "notification" -> SetNotificationRequest(this)
        "temperature" -> SetSkinTemperatureMeasurement(this)
        "disconnect_notify" -> SetDisconnectNotification(this, enabled)
        "work_mode" -> SetWorkModeRequest(this, enabled)
        else -> null
    }

    /** 保存并立即下发单个手表开关；未连接时等下次连接初始化链补发。 */
    fun setWatchSetting(key: String, enabled: Boolean): Boolean {
        if (!WATCH_SETTING_DEFAULTS.containsKey(key)) return false
        watchPrefs().edit().putBoolean(settingPrefKey(key), enabled).apply()
        applyGbWatchSettingPrefs()
        val label = WATCH_SETTING_LABELS[key] ?: key
        if (key == "music") {
            if (enabled) registerMediaSessionListener() else unregisterMediaSessionListener()
            addLog("$label 已${if (enabled) "开启" else "关闭"}")
            return true
        }
        if (state != "ready" || transport == null) {
            addLog("$label 已保存，手表连接后自动下发")
            return true
        }
        Thread({
            try {
                val request = watchSettingRequest(key, enabled)
                if (request == null) {
                    addLog("$label 已保存（无下发命令）")
                    return@Thread
                }
                request.setupTimeoutUntilNext(5000)
                request.doPerform()
                addLog("设置已下发：$label = ${if (enabled) "开" else "关"}")
            } catch (e: Exception) {
                addLog("$label 下发失败：${e.message ?: e.javaClass.simpleName}")
                FileLogger.e(TAG, "$label 下发失败", e)
            }
        }, "VitaloopWatchSetting").apply { isDaemon = true; start() }
        return true
    }

    private fun dndMode(): String =
        watchPrefs().getString(KEY_DND_MODE, if (watchPrefs().getBoolean(KEY_DND, false)) "always" else "off")
            ?: "off"

    private fun readDndPlan(): List<Any> {
        val mode = dndMode()
        val start = watchPrefs().getString(KEY_DND_START, "23:00") ?: "23:00"
        val end = watchPrefs().getString(KEY_DND_END, "07:00") ?: "07:00"
        val repeat = watchPrefs().getInt(KEY_DND_REPEAT, 0x7f)
        val lift = watchPrefs().getBoolean(KEY_DND_LIFT, false)
        return listOf(mode, start, end, repeat, lift)
    }

    fun dndPlanJson(): String {
        val plan = readDndPlan()
        return JSONObject()
            .put("mode", plan[0] as String)
            .put("start", plan[1] as String)
            .put("end", plan[2] as String)
            .put("repeatMask", plan[3] as Int)
            .put("liftWrist", plan[4] as Boolean)
            .toString()
    }

    /** 勿扰计划写入 Gadgetbridge 设备偏好，SendDnd*Request 从这里读。 */
    private fun applyDndPlanPrefs() {
        val plan = readDndPlan()
        val mode = plan[0] as String
        val mask = plan[3] as Int
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address).edit()
            .putString(DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB, mode)
            .putString(DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_START, plan[1] as String)
            .putString(DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_END, plan[2] as String)
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_LIFT_WRIST,
                plan[4] as Boolean
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_MO,
                mask and Alarm.ALARM_MON.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_TU,
                mask and Alarm.ALARM_TUE.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_WE,
                mask and Alarm.ALARM_WED.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_TH,
                mask and Alarm.ALARM_THU.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_FR,
                mask and Alarm.ALARM_FRI.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_SA,
                mask and Alarm.ALARM_SAT.toInt() != 0
            )
            .putBoolean(
                DeviceSettingsPreferenceConst.PREF_DO_NOT_DISTURB_SU,
                mask and Alarm.ALARM_SUN.toInt() != 0
            )
            .apply()
    }

    private fun normalizeTime(value: String, fallback: String): String {
        val parts = value.trim().split(':')
        if (parts.size != 2) return fallback
        val hour = parts[0].toIntOrNull() ?: return fallback
        val minute = parts[1].toIntOrNull() ?: return fallback
        if (hour !in 0..23 || minute !in 0..59) return fallback
        return String.format(java.util.Locale.US, "%02d:%02d", hour, minute)
    }

    /** 保存完整勿扰计划并下发；未连接时等下次连接初始化链补发。 */
    fun setDndPlan(
        mode: String,
        start: String,
        end: String,
        repeatMask: Int,
        liftWrist: Boolean
    ): Boolean {
        val normalizedMode = if (mode in listOf("off", "automatic", "always")) mode else "off"
        val normalizedStart = normalizeTime(start, "23:00")
        val normalizedEnd = normalizeTime(end, "07:00")
        watchPrefs().edit()
            .putBoolean(KEY_DND, normalizedMode != "off")
            .putString(KEY_DND_MODE, normalizedMode)
            .putString(KEY_DND_START, normalizedStart)
            .putString(KEY_DND_END, normalizedEnd)
            .putInt(KEY_DND_REPEAT, repeatMask and 0x7f)
            .putBoolean(KEY_DND_LIFT, liftWrist)
            .apply()
        applyDndPlanPrefs()
        if (state != "ready" || transport == null) {
            addLog("勿扰计划已保存，手表连接后自动下发")
            return true
        }
        Thread({
            try {
                val request: Request = if (normalizedMode == "off") {
                    SendDndDeleteRequest(this@VitaloopWatchManager)
                } else {
                    SendDndAddRequest(this@VitaloopWatchManager)
                }
                request.setupTimeoutUntilNext(5000)
                request.doPerform()
                addLog("勿扰计划已下发：$normalizedMode $normalizedStart-$normalizedEnd")
            } catch (e: Exception) {
                addLog("勿扰计划下发失败：${e.message ?: e.javaClass.simpleName}")
                FileLogger.e(TAG, "勿扰计划下发失败", e)
            }
        }, "VitaloopWatchDnd").apply { isDaemon = true; start() }
        return true
    }

    /** 兼容旧入口：开关映射为全天勿扰/关闭。 */
    fun setDndEnabled(enabled: Boolean): Boolean {
        val plan = readDndPlan()
        return setDndPlan(
            if (enabled) "always" else "off",
            plan[1] as String,
            plan[2] as String,
            plan[3] as Int,
            plan[4] as Boolean
        )
    }

    /** 手动“同步所有设置”：重发勿扰、闹钟、日历、天气、联系人，再拉表盘和应用列表。 */
    fun syncAllSettings(onDone: (String) -> Unit) {
        if (state != "ready" || transport == null) {
            onDone("手表未连接，设置会在连接后自动同步")
            return
        }
        Thread({
            val parts = mutableListOf<String>()
            applyGbWatchSettingPrefs()
            for ((key, _) in WATCH_SETTING_DEFAULTS) {
                if (key == "music") continue
                val request = runCatching {
                    watchSettingRequest(key, getWatchSetting(key))
                }.getOrNull()
                if (request == null) continue
                val ok = runCatching {
                    request.setupTimeoutUntilNext(5000)
                    request.doPerform()
                }.isSuccess
                if (!ok) parts += "${WATCH_SETTING_LABELS[key] ?: key}失败"
            }
            val dndOk = runCatching {
                applyDndPlanPrefs()
                val request: Request = if (dndMode() != "off") {
                    SendDndAddRequest(this@VitaloopWatchManager)
                } else {
                    SendDndDeleteRequest(this@VitaloopWatchManager)
                }
                request.setupTimeoutUntilNext(5000)
                request.doPerform()
            }.isSuccess
            parts += if (dndOk) "勿扰" else "勿扰失败"
            runCatching { syncAlarmsNow() }.onFailure { parts += "闹钟失败" }
            if (calendarSyncEnabled() && hasCalendarPermission()) {
                if (runCatching { syncCalendarNow() }.getOrDefault(false)) parts += "日历"
            }
            if (isWeatherSyncEnabled()) {
                runCatching { syncWeather(force = true) }.onSuccess { parts += "天气" }
            }
            runCatching { syncContactsToWatch() }.onSuccess { parts += "联系人" }
            if (coordinator.supportsMenstrual()) {
                runCatching { syncMenstrualCapability() }.onSuccess { parts += "经期" }
            }
            runCatching { requestAppList() }
            runCatching { requestWatchfaces() }
            val msg = "已下发：" + parts.joinToString("、")
            addLog("同步所有设置：$msg")
            onDone(msg)
        }, "VitaloopSyncAllSettings").apply { isDaemon = true; start() }
    }

    /** 恢复手表出厂设置：手表收到后还会自行弹窗让用户确认。 */
    fun factoryReset() {
        if (state != "ready" || transport == null) {
            addLog("恢复出厂失败：手表未连接")
            return
        }
        Thread({
            try {
                SendFactoryResetRequest(this).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                addLog("已发送恢复出厂设置请求，请在手表端确认")
            } catch (e: Exception) {
                addLog("恢复出厂失败: ${e.message}")
                FileLogger.e(TAG, "恢复出厂失败", e)
            }
        }, "VitaloopFactoryReset").apply { isDaemon = true; start() }
    }

    private fun vibrator(): Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        (appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        appContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }

    private fun startFindPhoneRing(force: Boolean = false) {
        if (!force && !findPhoneEnabled) {
            addLog("收到查找手机请求，但开关已关闭")
            return
        }
        if (findPhoneRingtone?.isPlaying == true) return
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            findPhoneRingtone = RingtoneManager.getRingtone(appContext, uri).also {
                it.isLooping = true
                it.play()
            }
            vibrator()?.let {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    it.vibrate(VibrationEffect.createOneShot(30_000L, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    it.vibrate(30_000L)
                }
            }
            addLog("手表请求查找手机，手机响铃中")
        } catch (e: Exception) {
            FileLogger.e(TAG, "查找手机响铃失败", e)
            setToolMessage("查找手机响铃失败：${e.message}")
        }
    }

    private fun stopFindPhoneRing() {
        try {
            findPhoneRingtone?.stop()
            findPhoneRingtone = null
            vibrator()?.cancel()
            addLog("查找手机已停止")
        } catch (e: Exception) {
            FileLogger.e(TAG, "停止查找手机响铃失败", e)
        }
    }

    fun testFindPhone() {
        startFindPhoneRing(force = true)
    }

    fun stopFindPhone() {
        stopFindPhoneRing()
        if (state != "ready" || transport == null) return
        Thread({
            try {
                StopFindPhoneRequest(this).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                setToolMessage("已停止手表查找手机")
            } catch (e: Exception) {
                FileLogger.e(TAG, "停止查找手机失败", e)
                setToolMessage("停止查找手机失败：${e.message}")
            }
        }, "VitaloopFindPhoneStop").apply { isDaemon = true; start() }
    }

    fun requestAppList() {
        val generation = beginTool("读取手表应用列表") ?: return
        Thread({
            try {
                GetAppNames(this).let {
                    it.setupTimeoutUntilNext(8_000)
                    it.setFinalizeReq(object : Request.RequestCallback() {
                        override fun call() {
                            setToolMessage("应用列表已刷新")
                            endTool(generation)
                        }

                        override fun handleException(e: Request.ResponseParseException) {
                            setToolMessage("读取应用列表失败：${e.message}")
                            endTool(generation)
                        }
                    })
                    it.doPerform()
                }
            } catch (e: Exception) {
                setToolMessage("读取应用列表失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopApps").apply { isDaemon = true; start() }
    }

    fun deleteWatchApp(packageName: String) {
        if (packageName.isBlank()) return
        val generation = beginTool("删除手表应用") ?: return
        Thread({
            try {
                SendAppDelete(this, packageName).let {
                    it.setupTimeoutUntilNext(8_000)
                    it.setFinalizeReq(object : Request.RequestCallback() {
                        override fun call() {
                            synchronized(installedApps) {
                                installedApps.removeAll { app -> app.packageName == packageName }
                            }
                            setToolMessage("已请求删除应用：$packageName")
                            endTool(generation)
                        }

                        override fun handleException(e: Request.ResponseParseException) {
                            setToolMessage("删除应用失败：${e.message}")
                            endTool(generation)
                        }
                    })
                    it.doPerform()
                }
            } catch (e: Exception) {
                setToolMessage("删除应用失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopAppDelete").apply { isDaemon = true; start() }
    }

    fun syncContactsToWatch() {
        val generation = beginTool("同步联系人") ?: return
        Thread({
            try {
                val countReq = GetContactsCount(this)
                countReq.setupTimeoutUntilNext(8_000)
                countReq.setFinalizeReq(object : Request.RequestCallback() {
                    override fun call() {
                        val contacts = readPhoneContacts(maxContactsCount.coerceAtLeast(20))
                        if (contacts.isEmpty()) {
                            setToolMessage("没有可同步的联系人")
                            endTool(generation)
                            return
                        }
                        try {
                            SendSetContactsRequest(
                                this@VitaloopWatchManager,
                                ArrayList(contacts),
                                maxContactsCount.coerceAtLeast(contacts.size)
                            ).let {
                                it.setupTimeoutUntilNext(15_000)
                                it.setFinalizeReq(object : Request.RequestCallback() {
                                    override fun call() {
                                        setToolMessage("联系人已同步到手表：${contacts.size} 个")
                                        endTool(generation)
                                    }

                                    override fun handleException(e: Request.ResponseParseException) {
                                        setToolMessage("联系人同步失败：${e.message}")
                                        endTool(generation)
                                    }
                                })
                                it.doPerform()
                            }
                        } catch (e: Exception) {
                            setToolMessage("联系人同步失败：${e.message}")
                            endTool(generation)
                        }
                    }

                    override fun handleException(e: Request.ResponseParseException) {
                        setToolMessage("读取联系人容量失败：${e.message}")
                        endTool(generation)
                    }
                })
                countReq.doPerform()
            } catch (e: Exception) {
                setToolMessage("联系人同步失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopContacts").apply { isDaemon = true; start() }
    }

    private fun readPhoneContacts(limit: Int): List<Contact> {
        val result = ArrayList<Contact>()
        try {
            val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            appContext.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                val idIdx = cursor.getColumnIndexOrThrow(
                    ContactsContract.CommonDataKinds.Phone.CONTACT_ID
                )
                val nameIdx = cursor.getColumnIndexOrThrow(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
                )
                val numberIdx = cursor.getColumnIndexOrThrow(
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                )
                while (cursor.moveToNext() && result.size < limit.coerceAtMost(maxContactsCount.coerceAtLeast(20))) {
                    val id = cursor.getString(idIdx) ?: continue
                    val name = cursor.getString(nameIdx)?.trim() ?: continue
                    val number = cursor.getString(numberIdx)?.trim() ?: continue
                    if (name.isBlank() || number.isBlank()) continue
                    result.add(object : Contact {
                        override fun getContactId(): String = id
                        override fun getName(): String = name
                        override fun getNumber(): String = number
                    })
                }
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取联系人失败", e)
        }
        return result
    }

    fun requestWatchfaces() {
        val generation = beginTool("读取表盘列表") ?: return
        synchronized(installedWatchfaces) {
            installedWatchfaces.clear()
            synchronized(watchfaceNames) { watchfaceNames.clear() }
            currentWatchface = ""
        }
        Thread({
            try {
                val paramsReq = GetWatchfaceParams(this)
                val listReq = GetWatchfacesList(this)
                paramsReq.setupTimeoutUntilNext(8_000)
                paramsReq.nextRequest(listReq)
                listReq.setupTimeoutUntilNext(8_000)
                listReq.setFinalizeReq(object : Request.RequestCallback() {
                    override fun call() {
                        setToolMessage("表盘列表已刷新")
                        if (installedWatchfaces.isEmpty()) endTool(generation)
                    }

                    override fun handleException(e: Request.ResponseParseException) {
                        setToolMessage("读取表盘失败：${e.message}")
                        endTool(generation)
                    }
                })
                paramsReq.doPerform()
            } catch (e: Exception) {
                setToolMessage("读取表盘失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopWatchfaces").apply { isDaemon = true; start() }
    }

    private fun requestWatchfaceNamesLocked(list: List<Watchface.InstalledWatchfaceInfo>, generation: Int) {
        try {
            GetWatchfacesNames(this, list).let {
                it.setupTimeoutUntilNext(8_000)
                it.setFinalizeReq(object : Request.RequestCallback() {
                    override fun call() {
                        emitTools()
                        endTool(generation)
                    }

                    override fun handleException(e: Request.ResponseParseException) {
                        setToolMessage("表盘名称读取失败：${e.message}")
                        endTool(generation)
                    }
                })
                it.doPerform()
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取表盘名称失败", e)
            setToolMessage("表盘名称读取失败：${e.message}")
            endTool(generation)
        }
    }

    fun activateWatchface(faceId: String, version: String) {
        sendWatchfaceOperation(faceId, version, Watchface.WatchfaceOperation.operationActive, "切换表盘")
    }

    fun deleteWatchface(faceId: String, version: String) {
        sendWatchfaceOperation(faceId, version, Watchface.WatchfaceOperation.operationDelete, "删除表盘")
    }

    private fun sendWatchfaceOperation(faceId: String, version: String, operation: Byte, action: String) {
        val generation = beginTool(action) ?: return
        Thread({
            try {
                SendWatchfaceOperation(this, "${faceId}_$version", operation).let {
                    it.setupTimeoutUntilNext(8_000)
                    it.setFinalizeReq(object : Request.RequestCallback() {
                        override fun call() {
                            if (operation == Watchface.WatchfaceOperation.operationDelete) {
                                synchronized(installedWatchfaces) {
                                    installedWatchfaces.removeAll { face -> face.fileName == faceId }
                                }
                            } else {
                                currentWatchface = faceId
                                synchronized(installedWatchfaces) {
                                    val idx = installedWatchfaces.indexOfFirst { face -> face.fileName == faceId }
                                    if (idx >= 0) {
                                        val old = installedWatchfaces[idx]
                                        installedWatchfaces[idx] = old.copy(current = true)
                                    }
                                }
                            }
                            setToolMessage("$action：$faceId")
                            endTool(generation)
                        }

                        override fun handleException(e: Request.ResponseParseException) {
                            setToolMessage("$action 失败：${e.message}")
                            endTool(generation)
                        }
                    })
                    it.doPerform()
                }
            } catch (e: Exception) {
                setToolMessage("$action 失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopWatchfaceOp").apply { isDaemon = true; start() }
    }

    fun installWatchface(path: String, name: String, version: String, mode: String) {
        if (state != "ready" || transport == null) {
            watchfaceInstallStatus = "手表未连接"
            emitTools()
            return
        }
        val safeName = name.trim().replace("_", "")
        val safeVersion = version.trim()
        if (safeName.isBlank() || safeVersion.isBlank()) {
            watchfaceInstallStatus = "表盘名称和版本不能为空"
            emitTools()
            return
        }
        Thread({
            try {
                val source = File(path).readBytes()
                if (source.isEmpty()) {
                    watchfaceInstallStatus = "表盘文件为空"
                    emitTools()
                    return@Thread
                }
                val payloadMode = runCatching {
                    WatchfacePackage.PayloadMode.valueOf(mode.trim().uppercase())
                }.getOrDefault(WatchfacePackage.PayloadMode.BIN)
                val prepared = WatchfacePackage.prepare(source, payloadMode)
                val fileName = "${safeName}_$safeVersion"
                val versionWarning = watchfaceDeviceParams?.let { params ->
                    when {
                        prepared.declaredVersion.isBlank() -> "包里没写 version，手表可能拒收"
                        WatchfacePackage.isVersionAcceptable(
                            prepared.declaredVersion,
                            params.maxVersion,
                        ) -> null
                        else -> "包版本 ${prepared.declaredVersion} 与手表引擎 ${params.maxVersion} 不匹配"
                    }
                }
                val info = HuaweiUploadManager.FileUploadInfo()
                info.fileName = fileName
                info.fileType = FileUpload.Filetype.watchface
                info.owner = UPLOAD_SLOT_WATCHFACE
                info.setBytes(prepared.payload)
                info.setFileUploadCallback(object : HuaweiUploadManager.FileUploadCallback {
                    override fun onUploadStart() {
                        watchfaceInstallStatus = "手表已接受表盘，开始传输 $fileName"
                        emitTools()
                    }

                    override fun onUploadProgress(progress: Int) {
                        watchfaceUploadProgress = progress
                        emitTools()
                    }

                    override fun onUploadComplete() {
                        watchfaceUploadProgress = 100
                        watchfaceInstallStatus = "表盘文件已传完，正在通知手表注册"
                        emitTools()
                        Thread({
                            try {
                                SendWatchfaceConfirm(this@VitaloopWatchManager, fileName).let {
                                    it.setupTimeoutUntilNext(8_000)
                                    it.doPerform()
                                }
                                watchfaceInstallStatus = "表盘已安装：$fileName"
                                emitTools()
                                Thread.sleep(500)
                                requestWatchfaces()
                            } catch (e: Exception) {
                                watchfaceInstallStatus = "表盘确认失败：${e.message}"
                                emitTools()
                            }
                        }, "VitaloopWatchfaceConfirm").apply { isDaemon = true; start() }
                    }

                    override fun onError(code: Int) {
                        watchfaceUploadProgress = -1
                        watchfaceInstallStatus = "表盘被手表拒绝，错误码 $code"
                        emitTools()
                    }
                })
                watchfaceUploadProgress = 0
                watchfaceInstallStatus =
                    "准备上传 $fileName：${prepared.payload.size} 字节（${prepared.note}）" +
                        (versionWarning?.let { "\n注意：$it" } ?: "")
                emitTools()
                if (!huaweiUploadManager.claimFileUploadSlot(info)) {
                    watchfaceUploadProgress = -1
                    watchfaceInstallStatus = "文件通道正被${slotOwnerText(huaweiUploadManager.fileUploadOwner)}占用"
                    emitTools()
                    return@Thread
                }
                SendFileUploadInfo(this, huaweiUploadManager).doPerform()
            } catch (e: Exception) {
                watchfaceUploadProgress = -1
                watchfaceInstallStatus = "表盘上传失败：${e.message}"
                FileLogger.e(TAG, "表盘上传失败", e)
                emitTools()
            }
        }, "VitaloopWatchfaceUpload").apply { isDaemon = true; start() }
    }

    fun installWatchApp(path: String, packageName: String) {
        val pkg = packageName.trim()
        if (!pkg.matches(Regex("[A-Za-z][A-Za-z0-9_.]*"))) {
            appInstallStatus = "包名格式不正确"
            emitTools()
            return
        }
        if (state != "ready" || transport == null) {
            appInstallStatus = "手表未连接"
            emitTools()
            return
        }
        Thread({
            try {
                val data = File(path).readBytes()
                if (data.isEmpty()) {
                    appInstallStatus = "应用文件为空"
                    emitTools()
                    return@Thread
                }
                val fileName = "${pkg}_INSTALL"
                val info = HuaweiUploadManager.FileUploadInfo()
                info.fileName = fileName
                info.fileType = FileUpload.Filetype.app
                info.owner = UPLOAD_SLOT_APP
                info.setBytes(data)
                info.setFileUploadCallback(object : HuaweiUploadManager.FileUploadCallback {
                    override fun onUploadStart() {
                        appInstallStatus = "手表已接受应用，开始传输 $pkg"
                        emitTools()
                    }

                    override fun onUploadProgress(progress: Int) {
                        appUploadProgress = progress
                        emitTools()
                    }

                    override fun onUploadComplete() {
                        appUploadProgress = 100
                        appInstallStatus = "应用安装包已传完：$pkg"
                        emitTools()
                        Thread({
                            Thread.sleep(2_000)
                            requestAppList()
                        }, "VitaloopAppRefresh").apply { isDaemon = true; start() }
                    }

                    override fun onError(code: Int) {
                        appUploadProgress = -1
                        appInstallStatus = "应用安装被手表拒绝，错误码 $code"
                        emitTools()
                    }
                })
                appUploadProgress = 0
                appInstallStatus = "准备上传应用：$fileName（${data.size} 字节）"
                emitTools()
                if (!huaweiUploadManager.claimFileUploadSlot(info)) {
                    appUploadProgress = -1
                    appInstallStatus = "文件通道正被${slotOwnerText(huaweiUploadManager.fileUploadOwner)}占用"
                    emitTools()
                    return@Thread
                }
                SendFileUploadInfo(this, huaweiUploadManager).doPerform()
            } catch (e: Exception) {
                appUploadProgress = -1
                appInstallStatus = "应用上传失败：${e.message}"
                FileLogger.e(TAG, "应用上传失败", e)
                emitTools()
            }
        }, "VitaloopAppUpload").apply { isDaemon = true; start() }
    }

    fun uploadMusic(paths: List<String>) {
        if (paths.isEmpty()) return
        val items = paths.mapNotNull { path ->
            val file = File(path)
            if (!file.isFile || file.length() == 0L) return@mapNotNull null
            val title: String
            val artist: String
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                    ?.takeIf { it.isNotBlank() }
                    ?: file.name.substringBeforeLast('.').ifBlank { "未命名歌曲" }
                artist = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?.takeIf { it.isNotBlank() }
                    ?: "未知艺术家"
            } catch (_: Exception) {
                return@mapNotNull null
            } finally {
                runCatching { retriever.release() }
            }
            MusicUploadItem(path, file.name, title, artist)
        }
        if (items.isEmpty()) {
            musicUploadStatus = "没有可上传的音频文件"
            emitTools()
            return
        }
        val existing = musicUploadQueue.map { it.name }.toMutableSet()
        musicUploadInFlight?.let { existing.add(it.name) }
        val fresh = items.filter { existing.add(it.name) }
        musicUploadCancelled = false
        musicUploadQueue.addAll(fresh)
        musicUploadStatus = if (fresh.isEmpty()) {
            "所选歌曲已在上传队列中"
        } else {
            "已加入 ${fresh.size} 首，待传 ${musicUploadQueue.size + if (musicUploadInFlight != null) 1 else 0} 首"
        }
        emitTools()
        pumpMusicUpload()
    }

    fun cancelMusicUpload() {
        musicUploadCancelled = true
        val dropped = musicUploadQueue.size
        musicUploadQueue.clear()
        musicUploadStatus = if (musicUploadInFlight == null) {
            "已取消音乐上传（丢弃 $dropped 首）"
        } else {
            "已取消后续上传：当前这首传完后停止"
        }
        emitTools()
    }

    private fun pumpMusicUpload() {
        if (musicUploadInFlight != null || musicUploadCancelled) return
        if (state != "ready" || transport == null) {
            if (musicUploadQueue.isNotEmpty()) {
                musicUploadStatus = "手表未连接，队列保留 ${musicUploadQueue.size} 首"
                emitTools()
            }
            return
        }
        val item = musicUploadQueue.poll() ?: run {
            musicUploadStatus = "音乐上传队列已完成"
            musicUploadProgress = -1
            emitTools()
            return
        }
        musicUploadInFlight = item
        musicUploadProgress = 0
        musicUploadStatus = "开始上传：${item.title} - ${item.artist}"
        emitTools()
        Thread({ uploadMusicFile(item) }, "VitaloopMusicUpload").apply { isDaemon = true; start() }
    }

    private fun uploadMusicFile(item: MusicUploadItem) {
        val settled = java.util.concurrent.atomic.AtomicBoolean(false)
        fun settle(requeue: Boolean, message: String) {
            if (!settled.compareAndSet(false, true)) return
            musicUploadInFlight = null
            if (requeue) {
                musicUploadQueue.add(item)
            }
            musicUploadStatus = message
            emitTools()
            if (!musicUploadCancelled) {
                Thread({
                    Thread.sleep(500)
                    pumpMusicUpload()
                }, "VitaloopMusicNext").apply { isDaemon = true; start() }
            }
        }
        try {
            val data = File(item.path).readBytes()
            val info = HuaweiUploadManager.FileUploadInfo()
            info.fileName = item.name
            info.fileType = FileUpload.Filetype.music
            info.owner = UPLOAD_SLOT_MUSIC
            info.setBytes(data)
            info.setFileUploadCallback(object : HuaweiUploadManager.FileUploadCallback {
                override fun onUploadStart() {
                    musicUploadStatus = "手表已接受音频，开始传输 ${item.name}"
                    emitTools()
                }

                override fun onUploadProgress(progress: Int) {
                    musicUploadProgress = progress
                    emitTools()
                }

                override fun onUploadComplete() {
                    musicUploadProgress = 100
                    settle(false, "已上传：${item.title} - ${item.artist}")
                }

                override fun onError(code: Int) {
                    musicUploadProgress = -1
                    if (code == MUSIC_FILE_RESULT_ALREADY_EXISTS) {
                        settle(false, "手表已有同名曲目，跳过：${item.name}")
                    } else {
                        settle(false, "音乐上传被拒绝（错误码 $code）：${item.name}")
                    }
                }
            })
            var waited = 0L
            while (!huaweiUploadManager.isFileUploadSlotFree(UPLOAD_SLOT_MUSIC)) {
                if (waited >= 60_000) {
                    settle(true, "文件通道繁忙，${item.name} 稍后重试")
                    return
                }
                Thread.sleep(500)
                waited += 500
            }
            if (!huaweiUploadManager.claimFileUploadSlot(info)) {
                settle(true, "文件通道繁忙，${item.name} 已回到队列")
                return
            }
            SendFileUploadInfo(this, huaweiUploadManager).doPerform()
        } catch (e: Exception) {
            musicUploadProgress = -1
            settle(false, "音乐上传失败：${e.message}")
        }
    }

    fun requestMusicLibrary() {
        val generation = beginTool("读取手表音乐库", 130_000) ?: return
        musicSyncActive = true
        synchronized(watchMusicTracks) { watchMusicTracks.clear() }
        synchronized(watchMusicPlaylists) { watchMusicPlaylists.clear() }
        musicPlaylistFrameCounts = ArrayList()
        musicPlaylistIndex = 0
        musicPlaylistPage = 0
        musicPlaylistPageIds.clear()
        musicUploadStatus = "正在读取手表音乐库..."
        emitTools()
        Thread({
            try {
                GetMusicInfoParams(this).let {
                    it.setupTimeoutUntilNext(12_000)
                    it.doPerform()
                }
            } catch (e: Exception) {
                musicSyncActive = false
                setToolMessage("音乐库读取失败：${e.message}")
                endTool(generation)
            }
        }, "VitaloopMusicLibrary").apply { isDaemon = true; start() }
    }

    private fun requestNextMusicFrame() {
        if (!musicSyncActive) return
        if (musicCurrentFrame >= musicFrameLimit) {
            requestMusicPlaylists()
            return
        }
        try {
            GetMusicList(this, musicCurrentFrame, musicEndFrame).let {
                it.setupTimeoutUntilNext(10_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取音乐列表失败", e)
            requestMusicPlaylists()
        }
    }

    private fun requestMusicPlaylists() {
        if (!musicSyncActive) return
        try {
            GetMusicPlaylist(this).let {
                it.setupTimeoutUntilNext(10_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取歌单失败", e)
            finishMusicLibrary()
        }
    }

    private fun requestCurrentMusicPlaylist() {
        if (!musicSyncActive) return
        if (musicPlaylistIndex >= watchMusicPlaylists.size) {
            finishMusicLibrary()
            return
        }
        val frameCount = musicPlaylistFrameCounts.getOrElse(musicPlaylistIndex) { 0 }
        if (frameCount <= 0) {
            musicPlaylistIndex++
            musicPlaylistPage = 0
            musicPlaylistPageIds.clear()
            requestCurrentMusicPlaylist()
            return
        }
        musicPlaylistPage = 0
        musicPlaylistPageIds.clear()
        requestCurrentMusicPlaylistPage()
    }

    private fun requestCurrentMusicPlaylistPage() {
        if (!musicSyncActive) return
        val playlist = watchMusicPlaylists.getOrNull(musicPlaylistIndex) ?: run {
            finishMusicLibrary()
            return
        }
        try {
            GetMusicPlaylistMusics(this, playlist.id, musicPlaylistPage).let {
                it.setupTimeoutUntilNext(10_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取歌单歌曲失败", e)
            musicPlaylistIndex++
            musicPlaylistPage = 0
            musicPlaylistPageIds.clear()
            requestCurrentMusicPlaylist()
        }
    }

    private fun finishMusicLibrary() {
        musicSyncActive = false
        musicUploadStatus = "音乐库已同步：${watchMusicTracks.size} 首，${watchMusicPlaylists.size} 个歌单"
        emitTools()
        endTool()
    }

    private fun slotOwnerText(owner: String?): String = when (owner) {
        UPLOAD_SLOT_MUSIC -> "音乐上传"
        UPLOAD_SLOT_WATCHFACE -> "表盘上传"
        UPLOAD_SLOT_APP -> "应用安装"
        "calendar" -> "日历同步"
        else -> "其他任务"
    }

    // ==================== 握手 ====================

    private fun initializeDevice() {
        setState("authenticating")
        createSecretKey()
        val linkParamsReq = GetLinkParamsRequest(this)
        linkParamsReq.setFinalizeReq(object : Request.RequestCallback() {
            override fun call() {
                val deviceStatusReq = GetDeviceStatusRequest(this@VitaloopWatchManager, true)
                deviceStatusReq.setFinalizeReq(object : Request.RequestCallback() {
                    override fun call() {
                        // authMode 必须在安全协商之前设置：请求载荷里带 authMode，
                        // 为 0 时手表不应答（旧 app 在 initializeDeviceDealHiChain 里同样先设）
                        paramsProvider.setAuthMode(if (paramsProvider.getDeviceSupportType().toInt() == 4) 4.toByte() else 2.toByte())
                        val securityNegoReq = GetSecurityNegotiationRequest(this@VitaloopWatchManager)
                        securityNegoReq.setFinalizeReq(object : Request.RequestCallback() {
                            override fun call() {
                                startHiChain(securityNegoReq.authType)
                            }
                        })
                        perform(securityNegoReq, "安全协商")
                    }
                })
                perform(deviceStatusReq, "设备状态")
            }
        })
        perform(linkParamsReq, "链路参数")
    }

    private fun startHiChain(authType: Int) {
        val secret = paramsProvider.getSecretKey()
        Log.i(
            TAG,
            "HiChain 开始: authType=0x${authType.toString(16)} firstConnection=$firstConnection " +
                "supportType=${paramsProvider.getDeviceSupportType()} " +
                "authMode=${paramsProvider.getAuthMode()} " +
                "authVersion=${paramsProvider.getAuthVersion()} " +
                "authAlgo=${paramsProvider.getAuthAlgo()} " +
                "encryptMethod=${paramsProvider.getEncryptMethod()} " +
                "androidIdLen=${androidId.length} secretLen=${secret?.size ?: -1}",
        )
        paramsProvider.setAuthMode(if (paramsProvider.getDeviceSupportType().toInt() == 4) 4.toByte() else 2.toByte())
        val hiChainReq = GetHiChainRequest(this, firstConnection)
        hiChainReq.setFinalizeReq(object : Request.RequestCallback() {
            override fun call() {
                configureDevice()
            }

            override fun handleException(e: Request.ResponseParseException) {
                Log.e(TAG, "认证异常: ${e.message}")
                setState("failed:认证失败 ${e.message}")
            }

            override fun timeout(request: Request) {
                setState("failed:认证超时")
            }
        })
        perform(hiChainReq, "HiChain 认证")
    }

    private fun configureDevice() {
        setState("configuring")
        val initQueue = listOf(
            GetProductInformationRequest(this),
            SetTimeRequest(this, true),
            GetBatteryLevelNotifyRequest(this, { emitDevice(true) }, ::recordBatteryStatus),
            GetSupportedServicesRequest(this) // MUST BE LAST - 触发动态服务初始化
        )
        chain(initQueue, object : Request.RequestCallback() {
            override fun call() {
                onReady()
            }
        })
    }

    private fun onReady() {
        setState("ready")
        emitDevice(true)
        // 每次建立连接都强制接受下一轮睡眠文件同步，保证打开 App/后台重连后
        // 不沿用进程里的旧节流时间，起床后第一次连接就能拿到最终评分和时长。
        lastSleepFileSyncAt = 0
        lastSleepDetailSyncAt = 0
        refreshWearStatus("连接初始化")
        registerMediaSessionListener()
        if (isWeatherSyncEnabled()) syncWeather()
        workoutLiveTracker.onReady()
        startCallForwarding()
        // 自动心率/血氧/睡眠测量，保证手表端持续产生数据。
        // GetSettingRelatedRequest 必须排在前面：TruSleep 新版文件、GPS 直取等能力位
        // 都从它返回的设置里读，缺了它 supportsTruSleepNewSync() 永远是 false，
        // 睡眠文件会被当成调试日志文件下载而直接失败。
        applyGbWatchSettingPrefs()
        val queue = mutableListOf<Request>(
            // 旧版顺序：扩展能力 → 账号 → 设置 → 协议确认。账号请求缺失时，
            // 手表会把 P2P 数据字典当成未授权 App 的请求（0x7F 100004）。
            GetExpandCapabilityRequest(this),
            SendExtendedAccountRequest(this),
            GetSettingRelatedRequest(this),
            // 旧版会先确认健康数据协议；少了这一步，手表只放行设置类命令，
            // P2P 数据字典（HRV/静息心率/体温等）会被静默拒绝。
            AcceptAgreementsRequest(this),
            SetAutomaticHeartrateRequest(this),
            SetAutomaticSpoRequest(this),
            SetTruSleepRequest(this),
            SetActivateOnLiftRequest(this),
            SetNavigateOnRotateRequest(this),
            GetNotificationCapabilitiesRequest(this),
            GetNotificationConstraintsRequest(this),
            SetNotificationRequest(this),
            SetWearMessagePushRequest(this),
            SetActivityReminderRequest(this),
            SetSkinTemperatureMeasurement(this),
            SetDisconnectNotification(this, getWatchSetting("disconnect_notify")),
            SetWorkModeRequest(this, getWatchSetting("work_mode")),
            SetTimeZoneIdRequest(this),
            SetDateFormatRequest(this),
            SendFitnessUserInfoRequest(this)
        )
        if (coordinator.supportsMenstrual()) {
            queue += SendMenstrualCapabilityRequest(this)
        }
        applyDndPlanPrefs()
        queue += if (dndMode() != "off") {
            SendDndAddRequest(this)
        } else {
            SendDndDeleteRequest(this)
        }
        // 不要在初始化配置链之前就占用 alarmSyncing：这条链一超时，
        // 健康数据同步会永远被当成「正在同步闹钟」而跳过。
        // 真正开始读闹钟时 startAlarmReadChain 会自己置位并带 30 秒兜底。
        chain(queue, object : Request.RequestCallback() {
            override fun call() {
                sendGpsAndTimeToWatch()
                startAlarmReadChain()
            }

            override fun handleException(e: Request.ResponseParseException) {
                addLog("初始化配置异常，继续读取闹钟：${e.message}")
                sendGpsAndTimeToWatch()
                startAlarmReadChain()
            }
        })
        startSyncLoop()
        startWearHeartbeat()
        startP2PLoop()
        // 星历：配了自托管地址就先把本地文件备好，再主动协商一次，避免开跑后
        // 才等手表来要、白白卡 30 秒才出首个定位点。
        refreshEphemerisIfConfigured()
        maybeProactiveEphemerisPush()
        ensureGpsParameters()
    }

    private fun chain(queue: List<Request>, done: Request.RequestCallback?) {
        for (i in 1 until queue.size) {
            queue[i - 1].setupTimeoutUntilNext(INIT_TIMEOUT_MS)
            queue[i - 1].nextRequest(queue[i])
        }
        queue.last().setupTimeoutUntilNext(INIT_TIMEOUT_MS)
        if (done != null) queue.last().setFinalizeReq(done)
        try {
            queue.first().doPerform()
        } catch (e: IOException) {
            Log.e(TAG, "请求链下发失败", e)
            setState("failed:${e.message}")
            done?.handleException(Request.ResponseParseException("请求链下发失败", e))
        }
    }

    private fun perform(req: Request, what: String) {
        try {
            req.doPerform()
        } catch (e: IOException) {
            Log.e(TAG, "$what 请求失败", e)
            setState("failed:$what 失败: ${e.message}")
        }
    }

    // ==================== 同步循环 ====================

    private fun startSyncLoop() {
        if (syncThread?.isAlive == true) return
        syncThread = Thread({
            try { Thread.sleep(3000) } catch (_: InterruptedException) { return@Thread }
            while (!Thread.currentThread().isInterrupted && transport != null) {
                maybeRefreshEphemeris()
                if (state == "ready") {
                    refreshWearStatus("定时")
                    // 先给 P2P 一次机会：syncOnce 一发出请求 roundActive 就为 true，
                    // 如果先同步健康数据，maybeSyncP2P 永远会看到“链路忙”，字典同步就饿死了。
                    maybeSyncP2P()
                    if (!p2pSyncing) syncOnce()
                }
                try { Thread.sleep(SYNC_INTERVAL_MS) } catch (_: InterruptedException) { return@Thread }
            }
        }, "VitaloopWatchSync").apply { start() }
    }

    /**
     * 主动向手表查询一次佩戴状态（在腕/离腕，0x01/0x3d）。
     * 上游 Gadgetbridge 的能力判定会让 GT 5 永远不发这条请求，这里无条件发，
     * 不支持的手表回错误包即可，超时由 setupTimeoutUntilNext 兜底。
     */
    fun refreshWearStatus(reason: String) {
        if (state != "ready" || transport == null) return
        if (wearQueryInFlight) return
        wearQueryInFlight = true
        Thread({
            try {
                GetWearStatusNotifyRequest(this) { code ->
                    applyWearStatus(code, reason)
                }.let {
                    it.setupTimeoutUntilNext(INIT_TIMEOUT_MS)
                    it.doPerform()
                }
            } catch (e: Exception) {
                FileLogger.w(TAG, "佩戴状态查询失败($reason): ${e.message}")
            } finally {
                wearQueryInFlight = false
            }
        }, "VitaloopWearQuery").start()
    }

    /**
     * 手表开户外运动时会周期性发 GpsStatus.enableGps。除了一次性 GPS+时间，
     * 新版还按 1Hz 把手机定位走 GpsData（0x18/0x03）发给手表，省掉手表冷启动搜星。
     */
    private fun ensureGpsParameters() {
        if (gpsParametersResponse != null) return
        if (state != "ready" || transport == null) return
        Thread({
            try {
                GetGpsParameterRequest(this).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
            } catch (e: Exception) {
                FileLogger.w(TAG, "查询手表 GPS 参数失败: ${e.message}")
            }
        }, "VitaloopGpsParams").apply { isDaemon = true; start() }
    }

    /** 连接就绪后下发一次手机坐标和时间，旧版就是这么把手表首个定位预热起来的。 */
    private fun sendGpsAndTimeToWatch() {
        if (state != "ready" || transport == null) return
        val gps = VitaloopGpsManager.getInstance(appContext)
        if (!gps.hasPermissions()) return
        Thread({
            val location = gps.currentLocation(8_000) ?: return@Thread
            try {
                SendGpsAndTimeToDeviceRequest(
                    this,
                    location.latitude,
                    location.longitude,
                ).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                addLog("GPS+时间已同步到手表")
                FileLogger.i(
                    TAG,
                    "GPS + time synced lat=${location.latitude} lng=${location.longitude}",
                )
            } catch (e: Exception) {
                addLog("GPS+时间同步失败: ${e.message}")
                FileLogger.w(TAG, "GPS + time sync failed: ${e.message}")
            }
        }, "VitaloopGpsTime").apply { isDaemon = true; start() }
    }

    private fun startWatchGpsStream() {
        watchGpsStopAt = 0L
        if (watchGpsStreaming) return
        if (state != "ready" || transport == null) return
        val gps = VitaloopGpsManager.getInstance(appContext)
        if (!gps.hasPermissions()) {
            addLog("手表请求 GPS：缺少手机定位权限，无法辅助定位")
            FileLogger.w(TAG, "watch GPS stream skipped: no location permission")
            return
        }
        watchGpsStreaming = true
        lastStreamedLocation = null
        watchGpsPoints.clear()
        gps.addPointListener(watchGpsPointListener)
        if (!gps.start("watch-gps")) {
            watchGpsStreaming = false
            gps.removePointListener(watchGpsPointListener)
            addLog("手表请求 GPS：手机定位启动失败")
            return
        }
        ensureGpsParameters()
        watchGpsWorker = Thread({
            while (watchGpsStreaming && !Thread.currentThread().isInterrupted) {
                val stopAt = watchGpsStopAt
                if (stopAt > 0L && System.currentTimeMillis() >= stopAt) {
                    doStopWatchGpsStream()
                    return@Thread
                }
                val point = watchGpsPoints.poll(
                    250L,
                    java.util.concurrent.TimeUnit.MILLISECONDS,
                ) ?: continue
                val params = gpsParametersResponse
                if (params == null) {
                    ensureGpsParameters()
                    continue
                }
                sendGpsPoint(point, params)
            }
        }, "VitaloopWatchGps").apply {
            isDaemon = true
            start()
        }
        addLog("手表请求 GPS：开始下发手机定位")
        FileLogger.i(TAG, "watch GPS stream started")
    }

    /**
     * 手表在搜星页会先 true、约 0.3 秒后再发 false；立即停会把这一轮辅助掐断。
     * 因此 false 只是设置一个宽限截止时间，期间再来 true 会取消停止。
     */
    private fun stopWatchGpsStream(graceMs: Long = 4_000L) {
        if (!watchGpsStreaming) return
        if (graceMs <= 0L) {
            doStopWatchGpsStream()
            return
        }
        watchGpsStopAt = System.currentTimeMillis() + graceMs
    }

    private fun doStopWatchGpsStream() {
        if (!watchGpsStreaming) return
        watchGpsStreaming = false
        watchGpsStopAt = 0L
        watchGpsWorker?.interrupt()
        watchGpsWorker = null
        watchGpsPoints.clear()
        lastStreamedLocation = null
        val gps = VitaloopGpsManager.getInstance(appContext)
        gps.removePointListener(watchGpsPointListener)
        gps.stop("watch-gps")
        addLog("停止下发手机定位")
        FileLogger.i(TAG, "watch GPS stream stopped")
    }

    private fun sendGpsPoint(point: JSONObject, params: GpsAndTime.GpsParameters.Response) {
        val lat = point.optDouble("lat", Double.NaN)
        val lon = point.optDouble("lon", Double.NaN)
        if (lat.isNaN() || lon.isNaN()) return
        val now = System.currentTimeMillis()
        val previous = lastStreamedLocation
        if (previous != null && now - previous.time < 900L) return
        val location = Location("phone").apply {
            latitude = lat
            longitude = lon
            time = point.optLong("ts", now).takeIf { it > 0L } ?: now
            speed = point.optDouble("speed", 0.0).toFloat().coerceAtLeast(0f)
            altitude = point.optDouble("alt", 0.0)
            val accuracy = point.optDouble("accuracy", 0.0)
            if (accuracy > 0.0) this.accuracy = accuracy.toFloat()
            val bearing = point.optDouble("bearing", 0.0)
            if (bearing >= 0.0) this.bearing = bearing.toFloat()
        }
        try {
            SendGpsDataRequest(this, location, previous, params).let {
                it.setupTimeoutUntilNext(3_000)
                it.doPerform()
            }
            lastStreamedLocation = location
        } catch (e: Exception) {
            FileLogger.w(TAG, "下发手表 GPS 失败: ${e.message}")
        }
    }

    fun syncMenstrualCapability() {
        if (state != "ready" || transport == null) return
        Thread({
            try {
                SendMenstrualCapabilityRequest(this).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                addLog("已同步经期追踪能力")
            } catch (e: Exception) {
                addLog("经期能力同步失败: ${e.message}")
                FileLogger.e(TAG, "经期能力同步失败", e)
            }
        }, "VitaloopMenstrual").apply { isDaemon = true; start() }
    }

    private fun sendMenstrualModifyTimeAck() {
        Thread({
            try {
                SendMenstrualModifyTimeRequest(this).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                addLog("经期时间已同步")
            } catch (e: Exception) {
                addLog("经期时间同步失败: ${e.message}")
                FileLogger.e(TAG, "经期时间同步失败", e)
            }
        }, "VitaloopMenstrualAck").apply { isDaemon = true; start() }
    }

    /**
     * 「在腕免密解锁」打开时每 10 秒续一次心跳。
     * 查不到响应时 `awen_watch_wear_at` 不前进，解锁侧 45 秒后自动收回放行。
     */
    private fun startWearHeartbeat() {
        if (wearThread?.isAlive == true) return
        wearThread = Thread({
            while (!Thread.currentThread().isInterrupted && transport != null) {
                if (WearStateBridge.readEnabled(appContext) && state == "ready") {
                    if (System.currentTimeMillis() - lastWearPushAt > 3_000L) {
                        refreshWearStatus("心跳")
                    } else {
                        WearStateBridge.publish(
                            appContext,
                            wearStatusCode ?: WEAR_STATUS_OFF_WRIST,
                            "心跳(沿用推送)",
                        )
                    }
                }
                try {
                    Thread.sleep(WEAR_HEARTBEAT_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "VitaloopWearHeartbeat").apply { start() }
    }

    /** 佩戴状态的唯一落点：界面值、断连语义和 Settings.Secure 发布都走这里。 */
    private fun applyWearStatus(code: Int, reason: String) {
        if (code < 0) {
            FileLogger.w(TAG, "佩戴状态响应里没有 tag 0x01($reason)，保持原值")
            return
        }
        val previous = wearStatusCode
        wearStatusCode = code
        lastWearPushAt = System.currentTimeMillis()
        if (previous != code) {
            FileLogger.i(
                TAG,
                "佩戴状态变化($reason): ${wearStatusLabel(previous)} -> ${wearStatusLabel(code)}",
            )
            emitTools()
        }
        WearStateBridge.publish(appContext, code, reason)
    }

    fun wearStatusLabel(code: Int? = wearStatusCode): String = when (code) {
        null -> "未查询"
        WEAR_STATUS_WORN -> "在腕"
        WEAR_STATUS_OFF_WRIST -> "离腕"
        else -> "未知(0x${Integer.toHexString(code)})"
    }

    fun syncOnce(manual: Boolean = false) {
        // 运动链与健康数据链共用同一条 RFCOMM，不能交叉发请求
        if (syncing || roundActive || workoutSyncing || p2pSyncing || alarmSyncing || weatherSyncing || transport == null) {
            if (manual) {
                val reason = when {
                    transport == null -> "蓝牙通道未就绪"
                    weatherSyncing -> "正在同步手表天气"
                    p2pSyncing -> "正在同步压力/HRV 数据字典"
                    workoutSyncing -> "正在同步运动记录"
                    alarmSyncing -> "正在同步手表闹钟"
                    roundActive || syncing -> "上一轮健康数据同步还没结束"
                    else -> "同步通道忙"
                }
                addLog("手动同步跳过：$reason")
            }
            return
        }
        syncing = true
        roundActive = true
        val generation = ++roundGeneration
        armRoundWatchdog(generation)
        synchronized(roundLock) { roundEvents = 0 }
        roundStartedAt = System.currentTimeMillis()
        try {
            val end = (System.currentTimeMillis() / 1000).toInt()
            val syncStart = getLastSyncStart()
            val batteryReq = GetBatteryLevelNotifyRequest(
                this,
                { emitDevice(true) },
                ::recordBatteryStatus,
            )
            val sleepCountReq = GetSleepDataCountRequest(this, syncStart, end)
            // 电量不是健康数据链的必要条件：GT5 在忙/刚重连时会用 0x186A4 拒绝电量请求。
            // 以前整条链会因此中止，睡眠/步数/压力全都不再同步；这里失败也继续往下走。
            val batteryDone = java.util.concurrent.atomic.AtomicBoolean(false)
            fun continueAfterBattery(reason: String?) {
                if (!batteryDone.compareAndSet(false, true)) return
                if (reason != null) addLog(reason)
                perform(sleepCountReq, "睡眠")
            }
            val stepCountReq = GetStepDataCountRequest(this, syncStart, end)
            val fitnessTotalsReq = GetFitnessTotalsRequest(this)
            fitnessTotalsReq.setFinalizeReq(object : Request.RequestCallback() {
                override fun call() {
                    if (generation == roundGeneration) roundActive = false
                    saveLastSyncEnd(end)
                    emit(JSONObject().put("t", "sync_done").put("end", end))
                    emitDevice(true)
                    addLog("同步完成：窗口 ${syncWindowText(syncStart, end)}，${elapsedText()}，本轮 ${roundEvents} 条数据")
                    downloadTruSleepData(end - 30 * 86_400, end)
                    downloadDictTrueSleepData()
                    maybeSyncStressFile()
                    startWorkoutSync(end)
                }
            })
            stepCountReq.setFinalizeReq(object : Request.RequestCallback() {
                override fun call() {
                    perform(fitnessTotalsReq, "每日汇总")
                }
            })
            sleepCountReq.setFinalizeReq(object : Request.RequestCallback() {
                override fun call() {
                    perform(stepCountReq, "步数")
                }
            })
            sleepCountReq.setupTimeoutUntilNext(SYNC_REQUEST_TIMEOUT_MS)
            stepCountReq.setupTimeoutUntilNext(SYNC_REQUEST_TIMEOUT_MS)
            fitnessTotalsReq.setupTimeoutUntilNext(SYNC_REQUEST_TIMEOUT_MS)
            // 电量每次同步重新取一次：GetBatteryLevelRequest 只写内存里的 GBDevice，
            // 不显式抛事件的话 devices 表里永远是旧版导入时的 0。
            batteryReq.setFinalizeReq(object : Request.RequestCallback() {
                override fun call() {
                    emitDevice(true)
                    continueAfterBattery(null)
                }

                override fun handleException(e: Request.ResponseParseException) {
                    continueAfterBattery("电量读取失败，继续同步健康数据")
                }

                override fun timeout(request: Request) {
                    continueAfterBattery("电量请求超时，继续同步健康数据")
                }
            })
            batteryReq.setupTimeoutUntilNext(SYNC_REQUEST_TIMEOUT_MS)
            batteryReq.doPerform()
        } catch (e: Exception) {
            Log.e(TAG, "同步失败", e)
            addLog("同步失败：${e.message ?: e.javaClass.simpleName}")
        } finally {
            syncing = false
        }
    }

    /**
     * 用户打开 App / 手动同步时强制补一次睡眠文件。
     * 夜间最后一版睡眠摘要通常在起床后才生成，不能被 5 分钟节流挡住。
     */
    fun forceSleepSync() {
        lastSleepFileSyncAt = 0
        lastSleepDetailSyncAt = 0
        syncOnce(manual = true)
    }

    /**
     * 手动回拉最近 N 天：重置增量游标和各类文件的节流时间。
     * 某次批量入库失败、或手表补传睡眠/压力/HRV 后，下一次增量不会覆盖旧窗口，
     * 这里给用户一个不用清数据就能补回来的入口。
     */
    fun resyncRecent(days: Int = 7) {
        val span = days.coerceIn(1, 30)
        val from = ((System.currentTimeMillis() / 1000) - span * 86_400L).toInt()
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
            .edit()
            .putLong(LAST_SYNC_KEY, from * 1000L)
            .apply()
        // 运动链有独立游标：把它的终点退回到 from，下一轮窗口就会覆盖 [from-24h, now]，
        // 重新拉一遍这些运动的 GPS 明细（缺失轨迹的手动补回入口）。
        watchPrefs().edit().putLong(KEY_WORKOUT_SYNC, from * 1000L).apply()
        lastP2PSyncAt = 0
        lastStressFileSyncAt = 0
        lastSleepFileSyncAt = 0
        lastSleepDetailSyncAt = 0
        addLog("手动重同步：回看最近 $span 天")
        syncOnce()
    }

    /** 健康链异常时 finalize 不一定会回调；超时兜底，避免 roundActive 永久卡住后续同步 */
    private fun armRoundWatchdog(generation: Int) {
        Thread({
            try {
                Thread.sleep(120_000)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (roundActive && generation == roundGeneration) {
                roundActive = false
                addLog("健康文件同步超时，下一轮重试")
            }
        }, "VitaloopRoundWatchdog").apply {
            isDaemon = true
            start()
        }
    }

    /**
     * P2P 数据字典：HRV、压力、静息心率、情绪、体温等。
     * 服务注册后先等手表回 0xca，再按游标同步；手表不回的分类由服务内部 8s 超时跳过。
     */
    private fun setupP2P() {
        if (p2pSetupRunning || p2pAvailable || transport == null) return
        p2pSetupRunning = true
        Thread({
            try {
                // 旧版在字典服务之前会先注册 hw.unitedevice.track 并下发心率区间。
                // GT5 把这当成“官方健康 App 在线”的标志；少了它，字典请求会被直接回 0xCF。
                if (p2pManager.getRegisteredService(HuaweiP2PTrackService.MODULE) == null) {
                    runCatching {
                        HuaweiP2PTrackService(p2pManager, 36, 54, 195).register()
                        addLog("P2P 心率区间服务已注册")
                    }.onFailure {
                        FileLogger.e(TAG, "P2P 心率区间服务注册失败", it)
                    }
                }
                p2pManager.registerService(HuaweiP2PDataDictionarySyncService(p2pManager))
                val service = p2pManager.getRegisteredService(
                    HuaweiP2PDataDictionarySyncService.MODULE
                ) as? HuaweiP2PDataDictionarySyncService
                var available = false
                for (i in 0 until 12) {
                    available = service?.isAvailable() == true
                    if (available) break
                    Thread.sleep(500)
                }
                p2pAvailable = available
                addLog("P2P 数据字典服务可用: $available")
                if (available) {
                    runCatching {
                        if (HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager) == null) {
                            HuaweiP2PCoursePlanService(p2pManager).register()
                            addLog("训练计划服务已注册")
                        }
                    }.onFailure {
                        FileLogger.e(TAG, "训练计划服务注册失败", it)
                        addLog("训练计划服务注册失败：${it.message ?: it.javaClass.simpleName}")
                    }
                    registerCalendarObserver()
                    val hasPendingPlan =
                        !(watchPrefs().getString(KEY_PENDING_PLAN, "") ?: "").isBlank()
                    if (calendarSyncEnabled() && !hasPendingPlan) {
                        runCatching { ensureCalendarService() }.onFailure {
                            FileLogger.e(TAG, "日历同步服务注册失败", it)
                            addLog("日历同步服务注册失败：${it.message ?: it.javaClass.simpleName}")
                        }
                    }
                    maybePushPendingPlan {
                        if (calendarSyncEnabled()) {
                            runCatching { ensureCalendarService() }.onFailure {
                                FileLogger.e(TAG, "日历同步服务注册失败", it)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                FileLogger.e(TAG, "P2P 数据字典初始化失败", e)
                addLog("P2P 数据字典初始化失败：${e.message ?: e.javaClass.simpleName}")
            } finally {
                p2pSetupRunning = false
            }
        }, "VitaloopP2PSetup").apply { isDaemon = true; start() }
    }

    // ==================== 训练计划 / 日历同步 ====================

    private fun calendarPrefs() =
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)

    private fun calendarSyncEnabled(): Boolean =
        gbDevice.address.isNotBlank() &&
            calendarPrefs().getBoolean(PREF_SYNC_CALENDAR, false)

    private fun hasCalendarPermission(): Boolean = try {
        if (android.os.Build.VERSION.SDK_INT < 23) {
            true
        } else {
            appContext.checkSelfPermission(android.Manifest.permission.READ_CALENDAR) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    } catch (_: Exception) {
        false
    }

    private fun ensureCalendarService(): HuaweiP2PCalendarService? {
        if (!coordinator.supportsCalendar()) return null
        var service = HuaweiP2PCalendarService.getRegisteredInstance(p2pManager)
        if (service == null) {
            service = HuaweiP2PCalendarService(p2pManager)
            service.register()
            addLog("日历同步服务已注册")
        }
        return service
    }

    private fun registerCalendarObserver() {
        if (!calendarSyncEnabled() || !hasCalendarPermission()) return
        if (calendarObserver != null) return
        val observer = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                if (!calendarSyncEnabled()) return
                HuaweiP2PCalendarService.getRegisteredInstance(p2pManager)
                    ?.scheduleUpdate(2_000)
            }
        }
        try {
            appContext.contentResolver.registerContentObserver(
                CalendarContract.Events.CONTENT_URI,
                true,
                observer,
            )
            calendarObserver = observer
        } catch (e: Exception) {
            FileLogger.e(TAG, "日历变更监听注册失败", e)
        }
    }

    private fun unregisterCalendarObserver() {
        val observer = calendarObserver ?: return
        calendarObserver = null
        try {
            appContext.contentResolver.unregisterContentObserver(observer)
        } catch (e: Exception) {
            FileLogger.e(TAG, "日历变更监听注销失败", e)
        }
    }

    fun calendarStatusJson(): String {
        val service = HuaweiP2PCalendarService.getRegisteredInstance(p2pManager)
        return JSONObject()
            .put("enabled", calendarSyncEnabled())
            .put("permission", hasCalendarPermission())
            .put("registered", service != null)
            .put("ready", state == "ready")
            .toString()
    }

    /**
     * 开关日历同步。true 时注册服务并让手表立刻拉一次；false 时通知手表停用。
     * 运行时权限由 Activity 先申请，这里只处理已授权后的状态。
     */
    fun setCalendarSyncEnabled(enabled: Boolean): Boolean {
        if (gbDevice.address.isBlank()) return false
        calendarPrefs().edit().putBoolean(PREF_SYNC_CALENDAR, enabled).apply()
        if (enabled) {
            registerCalendarObserver()
            if (state == "ready" && p2pAvailable) {
                val service = ensureCalendarService()
                service?.restartSynchronization()
            }
            addLog("日历同步已开启")
        } else {
            unregisterCalendarObserver()
            HuaweiP2PCalendarService.getRegisteredInstance(p2pManager)?.notifySyncDisabled()
            addLog("日历同步已关闭")
        }
        return true
    }

    fun syncCalendarNow(): Boolean {
        if (!calendarSyncEnabled() || !hasCalendarPermission()) return false
        if (state != "ready" || !p2pAvailable) return false
        val service = ensureCalendarService() ?: return false
        registerCalendarObserver()
        service.restartSynchronization()
        return true
    }

    private fun maybePushPendingPlan(onDone: (() -> Unit)? = null) {
        if (planPushRunning) return
        val raw = watchPrefs().getString(KEY_PENDING_PLAN, "") ?: ""
        if (raw.isBlank()) return
        pushTrainingPlanJson(raw, notifyQueued = false) { result ->
            FileLogger.i(TAG, "待下发训练计划结果: $result")
            onDone?.invoke()
        }
    }

    /**
     * 下发 Flutter 生成的训练计划。[onResult] 回 JSON：ok / queued / message。
     * 手表未就绪时先落本机，连接并完成 P2P 注册后自动补发。
     */
    fun pushTrainingPlanJson(
        raw: String,
        notifyQueued: Boolean = true,
        onResult: ((String) -> Unit)? = null,
    ) {
        if (raw.isBlank()) {
            onResult?.invoke(JSONObject().put("ok", false).put("message", "训练计划为空").toString())
            return
        }
        val plan = try {
            TrainingPlanPayload.fromJson(raw)
        } catch (e: Exception) {
            FileLogger.e(TAG, "训练计划解析失败", e)
            onResult?.invoke(
                JSONObject().put("ok", false)
                    .put("message", "训练计划格式错误：${e.message ?: e.javaClass.simpleName}")
                    .toString()
            )
            return
        }
        if (state != "ready" || transport == null) {
            watchPrefs().edit().putString(KEY_PENDING_PLAN, raw).apply()
            if (notifyQueued) {
                onResult?.invoke(
                    JSONObject().put("ok", true).put("queued", true)
                        .put("message", "已保存，连接手表后自动下发").toString()
                )
            }
            return
        }
        if (!p2pAvailable) {
            // 连接刚就绪或健康数据还在同步时不能抢发 P2P：等链路空闲后
            // setupP2P 注册好服务，再从这个待发槽自动补发。
            watchPrefs().edit().putString(KEY_PENDING_PLAN, raw).apply()
            if (notifyQueued) {
                onResult?.invoke(
                    JSONObject().put("ok", true).put("queued", true)
                        .put("message", "已保存，手表空闲后自动下发").toString()
                )
            }
            return
        }
        if (planPushRunning) {
            onResult?.invoke(
                JSONObject().put("ok", false).put("queued", true)
                    .put("message", "上一份计划还在传输，请稍后再试").toString()
            )
            return
        }
        planPushRunning = true
        Thread({
            var result: Result<String> = Result.failure(IllegalStateException("训练计划服务未就绪"))
            try {
                val deadline = System.currentTimeMillis() + 30_000
                var service = HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager)
                while (service == null && System.currentTimeMillis() < deadline &&
                    state == "ready" && transport != null
                ) {
                    Thread.sleep(300)
                    service = HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager)
                }
                if (service == null) {
                    result = Result.failure(IllegalStateException("训练计划服务未注册"))
                } else {
                    result = TrainingPlanSender(service).pushPlan(plan)
                }
            } catch (e: Exception) {
                result = Result.failure(e)
                FileLogger.e(TAG, "训练计划下发异常", e)
            } finally {
                planPushRunning = false
            }
            val text = result.fold(
                onSuccess = { it },
                onFailure = { it.message ?: "训练计划下发失败" },
            )
            addLog("训练计划: $text")
            if (result.isSuccess) {
                val stored = watchPrefs().getString(KEY_PENDING_PLAN, "")
                if (stored == raw) watchPrefs().edit().remove(KEY_PENDING_PLAN).apply()
            }
            onResult?.invoke(
                JSONObject().put("ok", result.isSuccess).put("message", text).toString()
            )
        }, "VitaloopPlanPush").apply { isDaemon = true; start() }
    }

    fun finishTrainingPlan(planId: String, onResult: ((String) -> Unit)? = null) {
        if (planId.isBlank()) {
            onResult?.invoke(JSONObject().put("ok", false).put("message", "缺少计划 ID").toString())
            return
        }
        // 用户删掉本机计划后，断线期间排队的那份也不能在下次连接时偷偷下发。
        watchPrefs().edit().remove(KEY_PENDING_PLAN).apply()
        if (state != "ready" || transport == null) {
            onResult?.invoke(
                JSONObject().put("ok", false).put("message", "手表未连接").toString()
            )
            return
        }
        Thread({
            val service = HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager)
            val result = if (service == null) {
                Result.failure<String>(IllegalStateException("训练计划服务未注册"))
            } else {
                TrainingPlanSender(service).finishPlan(planId)
            }
            val text = result.fold(
                onSuccess = { it },
                onFailure = { it.message ?: "完结失败" },
            )
            if (result.isSuccess) watchPrefs().edit().remove(KEY_PENDING_PLAN).apply()
            addLog("完结训练计划: $text")
            onResult?.invoke(
                JSONObject().put("ok", result.isSuccess).put("message", text).toString()
            )
        }, "VitaloopPlanFinish").apply { isDaemon = true; start() }
    }

    /**
     * 下发一条本机路线到手表。[raw] 是 Flutter 传来的 JSON：
     * { name, distance_m, points: [{lat, lon}] }；点统一是 GCJ-02，编码器会转回 WGS-84。
     */
    fun pushRouteJson(raw: String, onResult: ((String) -> Unit)? = null) {
        fun fail(message: String) {
            onResult?.invoke(JSONObject().put("ok", false).put("message", message).toString())
        }
        if (state != "ready" || transport == null) {
            fail("手表未连接")
            return
        }
        if (routePushRunning) {
            fail("上一份路线还在传输，请稍后再试")
            return
        }
        val route = runCatching {
            val obj = JSONObject(raw)
            val name = obj.optString("name").trim().ifBlank { "路线" }
            val distance = obj.optDouble("distance_m", 0.0)
            val array = obj.optJSONArray("points") ?: JSONArray()
            val points = ArrayList<WatchRoutePoint>(array.length())
            for (i in 0 until array.length()) {
                val point = array.optJSONObject(i) ?: continue
                val lat = point.optDouble("lat", Double.NaN)
                val lon = point.optDouble("lon", Double.NaN)
                if (!lat.isFinite() || !lon.isFinite()) continue
                if (lat !in -89.9999..89.9999 || lon !in -180.0001..180.0001) continue
                if (lat == 0.0 && lon == 0.0) continue
                points.add(WatchRoutePoint(lat, lon))
            }
            if (points.size < 2) null else WatchRoute(name, distance, points)
        }.getOrNull()
        if (route == null) {
            fail("路线至少需要 2 个有效轨迹点")
            return
        }

        routePushRunning = true
        Thread({
            var result: Result<String> = Result.failure(IllegalStateException("路线服务未就绪"))
            try {
                val deadline = System.currentTimeMillis() + 15_000
                var service = HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager)
                while (service == null && System.currentTimeMillis() < deadline &&
                    state == "ready" && transport != null
                ) {
                    Thread.sleep(300)
                    service = HuaweiP2PCoursePlanService.getRegisteredInstance(p2pManager)
                }
                result = if (service == null) {
                    Result.failure(IllegalStateException("路线服务未注册，请确认手表已连接"))
                } else {
                    runBlocking {
                        HuaweiRouteSender(service).pushRoute(
                            route,
                            supportsRouteCp = coordinator.supportsExpandCapability(218),
                        )
                    }
                }
            } catch (e: Exception) {
                result = Result.failure(e)
                FileLogger.e(TAG, "路线下发异常", e)
            } finally {
                routePushRunning = false
            }
            val text = result.fold(
                onSuccess = { it },
                onFailure = { it.message ?: "路线发送失败" },
            )
            addLog("路线: $text")
            onResult?.invoke(
                JSONObject().put("ok", result.isSuccess).put("message", text).toString()
            )
        }, "VitaloopRoutePush").apply { isDaemon = true; start() }
    }

    // ==================== 离线地图 ====================

    /**
     * 只读探测：ping mapkit → 查手表剩余空间 → 查表上已有地图。
     * 用来在不发文件的前提下确认这条链路通不通。
     */
    fun probeOfflineMap(onResult: ((String) -> Unit)? = null) {
        fun fail(message: String) {
            mapStatus = message
            emitTools()
            onResult?.invoke(JSONObject().put("ok", false).put("message", message).toString())
        }
        if (!tryBeginMapOperation()) {
            fail("已有地图操作在进行中，请等待完成")
            return
        }
        Thread({
            var result: Result<String> = Result.failure(IllegalStateException("地图服务未就绪"))
            try {
                mapStatus = "正在等待手表连接…"
                emitTools()
                result = ensureReadyForMap().mapCatching {
                    mapStatus = "正在查询手表地图空间…"
                    emitTools()
                    runBlocking {
                        HuaweiMapSender(requireMapService()).probe().getOrThrow()
                    }
                }
            } catch (e: Exception) {
                result = Result.failure(e)
                FileLogger.e(TAG, "地图探测异常", e)
            } finally {
                mapPushRunning = false
            }
            val text = result.fold(
                onSuccess = { it },
                onFailure = { it.message ?: "探测失败" },
            )
            mapStatus = text
            addLog("地图探测: $text")
            emitTools()
            onResult?.invoke(
                JSONObject().put("ok", result.isSuccess).put("message", text).toString()
            )
        }, "VitaloopMapProbe").apply { isDaemon = true; start() }
    }

    /**
     * 从系统选择器返回的 Uri 推送离线地图。地图包本体只有华为 map-drcn 云有，
     * 本 App 不联网取包，只原样转发用户自己拿到的文件。
     */
    fun pushOfflineMapUri(uri: String, onResult: ((String) -> Unit)? = null) {
        fun fail(message: String) {
            mapStatus = message
            emitTools()
            onResult?.invoke(JSONObject().put("ok", false).put("message", message).toString())
        }
        if (!tryBeginMapOperation()) {
            fail("已有地图操作在进行中，请等待完成")
            return
        }
        Thread({
            var result: Result<String> = Result.failure(IllegalStateException("地图服务未就绪"))
            try {
                result = ensureReadyForMap().mapCatching {
                    if (!coordinator.supportsExpandCapability(201)) {
                        throw IllegalStateException("这块手表不支持离线地图（能力位 201）")
                    }
                    val parsed = Uri.parse(uri)
                    val fileName = queryDisplayName(parsed)
                        ?: parsed.lastPathSegment
                        ?: "map.bin"
                    val size = resolveOpenableSize(parsed)
                    if (size > MAP_PUSH_MAX_BYTES) {
                        throw IllegalStateException(
                            "地图文件 ${size / (1024 * 1024)} MB 太大，手机内存放不下" +
                                "（上限 ${MAP_PUSH_MAX_BYTES / (1024 * 1024)} MB），本次未发送"
                        )
                    }
                    mapStatus = "正在读取地图文件 $fileName…"
                    emitTools()
                    val bytes = appContext.contentResolver.openInputStream(parsed)?.use {
                        it.readBytes()
                    } ?: throw IllegalStateException("无法读取所选地图文件")
                    if (bytes.isEmpty()) {
                        throw IllegalStateException("地图文件为空，已取消")
                    }
                    FileLogger.i(TAG, "选中地图文件: $fileName bytes=${bytes.size}")
                    mapStatus = "正在与手表握手并传输地图（${bytes.size / (1024 * 1024)} MB）…"
                    emitTools()
                    runBlocking {
                        HuaweiMapSender(requireMapService()).pushMap(fileName, bytes).getOrThrow()
                    }
                }
            } catch (e: Exception) {
                result = Result.failure(e)
                FileLogger.e(TAG, "地图推送异常", e)
            } finally {
                mapPushRunning = false
            }
            val text = result.fold(
                onSuccess = { it },
                onFailure = { it.message ?: "地图发送失败" },
            )
            mapStatus = text
            addLog("地图: $text")
            emitTools()
            onResult?.invoke(
                JSONObject().put("ok", result.isSuccess).put("message", text).toString()
            )
        }, "VitaloopMapPush").apply { isDaemon = true; start() }
    }

    /**
     * 推送前等待连接。用户点“推送”时手表可能刚休眠或正在后台重连，
     * 直接报“未就绪”会让一次有效推送失败；这里触发重连并等待 READY。
     */
    private fun ensureReadyForMap(): Result<Unit> {
        if (state == "ready" && transport != null) return Result.success(Unit)
        if (isUserDisconnected()) {
            return Result.failure(IllegalStateException("手表已被手动断开，请先在手表页重新连接"))
        }
        val saved = savedWatch()
            ?: return Result.failure(IllegalStateException("还没有绑定手表，请先连接并认证手表"))
        if (connectThread?.isAlive != true) {
            mapStatus = "手表未连接，正在自动重连…"
            emitTools()
            connect(saved.address, saved.name)
        }
        val deadline = System.currentTimeMillis() + MAP_PUSH_CONNECT_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            if (state == "ready" && transport != null) return Result.success(Unit)
            // connect() 是异步的，刚发起时 state 还停在 disconnected；连接线程活着就继续等。
            if (state.startsWith("failed") ||
                (state.startsWith("disconnected") && connectThread?.isAlive != true)
            ) {
                return Result.failure(
                    IllegalStateException("手表连接失败：${state.substringAfter(':', "请重新连接")}")
                )
            }
            try {
                Thread.sleep(300L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        return Result.failure(
            IllegalStateException("手表连接超时，请确认手表蓝牙已开启且在手机附近")
        )
    }

    private fun requireMapService(): HuaweiP2PMapService {
        HuaweiP2PMapService.getRegisteredInstance(p2pManager)?.let { return it }
        val service = HuaweiP2PMapService(p2pManager)
        service.register()
        return service
    }

    /** 地图等待方按命令号挂在服务里，同一时刻只允许一次操作在飞。 */
    private fun tryBeginMapOperation(): Boolean = synchronized(mapLock) {
        if (mapPushRunning) {
            false
        } else {
            mapPushRunning = true
            true
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path?.substringAfterLast('/')
        return try {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveOpenableSize(uri: Uri): Long {
        if (uri.scheme == "file") return uri.path?.let { java.io.File(it).length() } ?: 0L
        return try {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else 0L
            } ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    /**
     * 处理手表驱动的文件上传（训练计划、日历都走这条 0x28 通道）。
     * 顺序：文件信息 → 文件哈希 → 上传协商 → 分片（重复）→ 上传完成。
     */
    private fun handleFileUploadPacket(packet: HuaweiPacket) {
        val info = huaweiUploadManager.fileUploadInfo
        try {
            when (packet.commandId) {
                FileUpload.FileInfoSend.id -> {
                    if (packet !is FileUpload.FileInfoSend.Response) return
                    if (info == null) {
                        addLog("上传文件信息到达但无待上传文件")
                    } else if (packet.result != 100000) {
                        info.fileUploadCallback?.onError(packet.result)
                        huaweiUploadManager.setFileUploadInfo(null)
                    }
                }
                FileUpload.FileHashSend.id -> {
                    if (packet !is FileUpload.FileHashSend.Response) return
                    if (info == null) {
                        addLog("上传文件哈希请求但无待上传文件")
                    } else {
                        info.fileId = packet.fileId
                        SendFileUploadHash(this, huaweiUploadManager).doPerform()
                    }
                }
                FileUpload.FileUploadConsultAck.id -> {
                    if (packet !is FileUpload.FileUploadConsultAck.Response) return
                    if (info == null) {
                        addLog("上传协商请求但无待上传文件")
                    } else {
                        info.setFileUploadParams(packet.fileUploadParams)
                        info.fileUploadCallback?.onUploadStart()
                        SendFileUploadAck(
                            this,
                            packet.fileUploadParams.no_encrypt,
                            info.fileId,
                        ).doPerform()
                    }
                }
                FileUpload.FileNextChunkParams.id -> {
                    if (packet !is FileUpload.FileNextChunkParams) return
                    if (info == null) {
                        addLog("上传分片请求但无待上传文件")
                    } else {
                        info.setUploadChunkSize(packet.nextchunkSize)
                        info.currentUploadPosition = packet.bytesUploaded
                        val progress = if (info.fileSize > 0) {
                            Math.round(packet.bytesUploaded.toFloat() / info.fileSize * 100)
                        } else {
                            0
                        }
                        info.fileUploadCallback?.onUploadProgress(progress)
                        SendFileUploadChunk(this, huaweiUploadManager).doPerform()
                    }
                }
                FileUpload.FileUploadResult.id -> {
                    if (packet !is FileUpload.FileUploadResult.Response) return
                    if (info == null) {
                        addLog("上传完成请求但无待上传文件")
                    } else {
                        val fileId = info.fileId
                        if (packet.status.toInt() != 0) {
                            FileLogger.w(TAG, "FileUploadResult status=${packet.status}")
                        }
                        info.fileUploadCallback?.onUploadComplete()
                        huaweiUploadManager.setFileUploadInfo(null)
                        SendFileUploadComplete(this, fileId).doPerform()
                    }
                }
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "文件上传处理异常", e)
            addLog("文件上传异常：${e.message ?: e.javaClass.simpleName}")
        }
    }

    /**
     * P2P 单独一条 2 秒轮询：健康链一空闲就注册字典服务并同步。
     * 不能等 60 秒的同步主循环——手表的 P2P 授权只在这个窗口内有效。
     */
    private fun startP2PLoop() {
        if (p2pThread?.isAlive == true) return
        p2pThread = Thread({
            while (!Thread.currentThread().isInterrupted && transport != null) {
                if (state == "ready") maybeSyncP2P()
                try {
                    Thread.sleep(2_000)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "VitaloopP2PSync").apply { isDaemon = true; start() }
    }

    private fun maybeSyncP2P() {
        if (!p2pAvailable) {
            // 和旧版一致：等健康/文件/运动链全部跑完并静置 5 秒后再注册。
            // 注册时的 ping 就是手表的授权，太早注册到真正发请求时已经过期。
            if (!p2pSetupRunning && roundGeneration > 0 &&
                System.currentTimeMillis() - lastLinkBusyAt >= 5_000
            ) {
                setupP2P()
            }
            return
        }
        val now = System.currentTimeMillis()
        // 数据字典是独立的一条 P2P 请求链：手表在健康/运动/文件链还没走完时收到字典
        // 请求会直接回 0xCF（ACK 失败），所以这里必须等所有链都空闲。
        if (state != "ready" || syncing || roundActive || workoutSyncing || p2pSyncing || alarmSyncing || weatherSyncing) {
            lastLinkBusyAt = now
            return
        }
        // 旧版在整条链收尾后约 5 秒才发字典请求；刚空出来时手表仍在收尾，会回 0xCF。
        if (roundGeneration == 0 || now - lastLinkBusyAt < 5_000) return
        val interval = if (p2pSyncOk) P2P_SYNC_INTERVAL_MS else 60_000L
        if (now - lastP2PSyncAt < interval) return
        syncP2PDictionaries()
    }

    private fun syncP2PDictionaries() {
        val dictService = p2pManager.getRegisteredService(
            HuaweiP2PDataDictionarySyncService.MODULE
        ) as? HuaweiP2PDataDictionarySyncService
        if (dictService == null) {
            p2pAvailable = false
            addLog("P2P 数据字典服务未注册，本轮跳过")
            return
        }
        var available = dictService.isAvailable()
        if (!available) {
            val latch = java.util.concurrent.CountDownLatch(1)
            dictService.ensureAvailable { code, _ ->
                available = (code.toByte() == 0xCA.toByte())
                latch.countDown()
            }
            try {
                latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                return
            }
        }
        if (!available) {
            p2pAvailable = false
            addLog("P2P 数据字典服务不可用，本轮跳过")
            return
        }
        // 旧版日志：ping 0xCA 之后约 5 秒才发第一条字典请求，立刻发会被回 0xCF。
        try {
            Thread.sleep(5_000)
        } catch (_: InterruptedException) {
            return
        }
        lastP2PSyncAt = System.currentTimeMillis()
        p2pSyncing = true
        val known = dictService.checkSupported(
            coordinator,
            mutableListOf(
                HuaweiDictTypes.SKIN_TEMPERATURE_CLASS,
                HuaweiDictTypes.BODY_TEMPERATURE_CLASS,
                HuaweiDictTypes.HRV_CLASS
            )
        ).toMutableList()
        val fixed = listOf(
            HuaweiDictTypes.EMOTION_CLASS,
            HuaweiDictTypes.SLEEP_APNEA_CLASS,
            HuaweiDictTypes.SLEEP_ON_OFF_BED_CLASS,
            HuaweiDictTypes.HOURLY_STATUS_CLASS,
            HuaweiDictTypes.STRESS_CLASS,
            HuaweiDictTypes.RESTING_HEART_RATE_CLASS,
            HuaweiDictTypes.BODY_TEMPERATURE_CLASS,
            HuaweiDictTypes.ARRHYTHMIA_CLASS,
            HuaweiDictTypes.DAILY_RING_CLASS
        )
        for (cls in fixed) if (!known.contains(cls)) known.add(cls)
        val prefs = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
        // 旧版探测到过的分类继续同步，不再做全量盲探。
        prefs.getStringSet("dict_found_classes", emptySet())
            ?.forEach { cls ->
                cls.toIntOrNull()?.let { if (!known.contains(it)) known.add(it) }
            }
        // 华为未在开源协议里文档化的分类按小片探测；无数据分类每轮要等 8 秒超时，
        // 一次塞完会挤掉正常同步，所以跨轮推进并持久化进度。
        if (!prefs.getBoolean("dict_probe_done", false)) {
            val probeIndex = prefs.getInt("dict_probe_index", 0)
            val chunk = DICT_PROBE_CLASSES.drop(probeIndex).take(DICT_PROBE_CHUNK_SIZE)
            if (chunk.isNotEmpty()) {
                for (cls in chunk) if (!known.contains(cls)) known.add(cls)
                val nextIndex = probeIndex + chunk.size
                prefs.edit()
                    .putInt("dict_probe_index", nextIndex)
                    .putBoolean("dict_probe_done", nextIndex >= DICT_PROBE_CLASSES.size)
                    .apply()
                addLog("P2P 探测分片: $probeIndex/${DICT_PROBE_CLASSES.size} → $nextIndex")
            } else {
                prefs.edit().putBoolean("dict_probe_done", true).apply()
            }
        }
        addLog("P2P 数据字典同步分类: ${known.joinToString(",")}")
        val before = p2pDictEventCount
        try {
            dictService.startSync(known, object : HuaweiP2PDataDictionarySyncService.DictionarySyncCallback {
                override fun onComplete(complete: Boolean) {
                    p2pSyncing = false
                    val got = p2pDictEventCount - before
                    p2pSyncOk = got > 0
                    addLog("P2P 数据字典同步完成: $complete，收到 $got 条")
                }
            })
        } catch (e: Exception) {
            p2pSyncing = false
            FileLogger.e(TAG, "P2P 数据字典同步失败", e)
            addLog("P2P 数据字典同步失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    /** TruSleep 状态文件：GT5 的普通睡眠计数常回 0，准确总睡眠段在这里。 */
    private fun downloadTruSleepData(start: Int, end: Int) {
        val now = System.currentTimeMillis()
        if (now - lastSleepFileSyncAt < SLEEP_FILE_SYNC_INTERVAL_MS) return
        if (!coordinator.supportsTruSleep()) {
            addLog("手表不支持 TruSleep 文件，跳过睡眠文件同步")
            return
        }
        lastSleepFileSyncAt = now
        fileDownloadManager.addToQueue(
            HuaweiFileDownloadManager.FileRequest.sleepStateFileRequest(
                coordinator.supportsTruSleepNewSync(),
                start,
                end,
                object : HuaweiFileDownloadManager.FileDownloadCallback() {
                    override fun downloadComplete(fileRequest: HuaweiFileDownloadManager.FileRequest) {
                        val data = fileRequest.data
                        FileLogger.i(TAG, "TruSleep 文件完成: ${fileRequest.filename} size=${data.size}")
                        if (data.isEmpty()) return
                        try {
                            val results = HuaweiTruSleepParser.parseState(data)
                            results.forEach {
                                addSleepActivity(it.startTime, it.endTime, 0x06, 0x0a)
                            }
                            addLog("TruSleep 同步完成: ${results.size} 段")
                        } catch (e: Exception) {
                            FileLogger.e(TAG, "TruSleep 解析失败", e)
                            addLog("TruSleep 解析失败：${e.message ?: e.javaClass.simpleName}")
                        }
                    }

                    override fun downloadException(e: HuaweiFileDownloadManager.HuaweiFileDownloadException) {
                        FileLogger.e(TAG, "TruSleep 文件下载失败", e)
                        addLog("TruSleep 文件下载失败：${e.message ?: e.javaClass.simpleName}")
                    }
                }
            ),
            true
        )
    }

    /**
     * 睡眠详情文件（字典 700013 / sequence_data）：手表算好的分钟级分期，
     * 以及睡眠 HRV、呼吸率。TruSleep 状态文件只有整段窗口，这两类数据只能从这里拿。
     */
    private fun downloadDictTrueSleepData() {
        if (!coordinator.supportsDictSleepSync()) {
            addLog("手表不支持睡眠详情文件，跳过 HRV / 呼吸率同步")
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastSleepDetailSyncAt < SLEEP_DETAIL_SYNC_INTERVAL_MS) return
        lastSleepDetailSyncAt = now
        val to = (now / 1000).toInt()
        // 详情文件按“最近几晚”取，不能从上一次同步时间开始：增量窗口常常只有几分钟，
        // 手表会直接回空文件（旧版也是固定回看 3 天）。
        val from = to - 3 * 86_400
        FileLogger.i(TAG, "请求睡眠详情文件(700013) window=$from..$to")
        fileDownloadManager.addToQueue(
            HuaweiFileDownloadManager.FileRequest.sequenceDataFileRequest(
                from,
                to,
                HuaweiDictTypes.SLEEP_DETAILS_CLASS,
                object : HuaweiFileDownloadManager.FileDownloadCallback() {
                    override fun downloadComplete(fileRequest: HuaweiFileDownloadManager.FileRequest) {
                        val data = fileRequest.data
                        FileLogger.i(TAG, "睡眠详情文件完成: size=${data.size}")
                        if (data.isEmpty()) return
                        try {
                            val fileData = HuaweiSequenceDataFileParser.parseSequenceFileData(data) ?: return
                            var nights = 0
                            for (seq in fileData.sequenceDataList) {
                                val summary = HuaweiTrueSleepSequenceDataParser().parseData(fileData, seq) ?: continue
                                nights++
                                HuaweiTrueSleepSequenceDataParser.correctSummary(summary)
                                emitSleepDetailSummary(seq, summary)
                                val details = seq.details
                                if (details != null && details.isNotEmpty()) {
                                    val startSec = when {
                                        summary.fallAsleepTime > 0 -> summary.fallAsleepTime
                                        summary.bedTime > 0 -> summary.bedTime
                                        else -> seq.startTime.toLong()
                                    }
                                    HuaweiTrueSleepSequenceDataParser.parseSleepDetails(details, startSec)
                                        ?.let { emitSleepDetailStages(it) }
                                }
                            }
                            addLog("睡眠详情同步完成: $nights 晚")
                            FileLogger.i(TAG, "睡眠详情文件: dictId=${fileData.dictId} 段数=${fileData.sequenceDataList.size} 晚数=$nights")
                        } catch (e: Exception) {
                            FileLogger.e(TAG, "睡眠详情解析失败", e)
                            addLog("睡眠详情解析失败：${e.message ?: e.javaClass.simpleName}")
                        }
                    }

                    override fun downloadException(e: HuaweiFileDownloadManager.HuaweiFileDownloadException) {
                        FileLogger.e(TAG, "睡眠详情文件下载失败", e)
                        addLog("睡眠详情文件下载失败：${e.message ?: e.javaClass.simpleName}")
                    }
                }
            ),
            true
        )
    }

    private fun emitSleepDetailSummary(
        seq: HuaweiSequenceDataFileParser.SequenceData,
        summary: HuaweiTrueSleepSequenceDataParser.SleepSummary
    ) {
        val startSec = when {
            summary.fallAsleepTime > 0 -> summary.fallAsleepTime
            summary.bedTime > 0 -> summary.bedTime
            else -> seq.startTime.toLong()
        }
        // 首页、准备度都按「醒来那天」取昨夜数据；用入睡时刻会落到前一天，
        // 出现睡眠时长有、HRV 却是空的矛盾。
        val wakeSec = listOf(summary.wakeupTime, summary.risingTime)
            .filter { it > startSec }
            .maxOrNull()
            ?: seq.endTime.toLong()
        val ts = (if (wakeSec > startSec) wakeSec else startSec) * 1000
        if (summary.avgHrv > 0) {
            emit(
                JSONObject()
                    .put("t", "sleep_hrv")
                    .put("ts", ts)
                    .put("start", startSec * 1000)
                    .put("avg", summary.avgHrv)
                    .put("min", summary.minHrvBaseline)
                    .put("max", summary.maxHrvBaseline)
                    .put("delta", summary.hrvDayToBaseline)
            )
            emit(JSONObject().put("t", "hrv").put("ts", ts).put("v", summary.avgHrv))
            addLog("睡眠 HRV: 平均 ${summary.avgHrv}，基线 ${summary.minHrvBaseline}-${summary.maxHrvBaseline}")
        }
        if (summary.avgBreathRate > 0) {
            emit(JSONObject().put("t", "respiration").put("ts", ts).put("v", summary.avgBreathRate))
            addLog("睡眠呼吸率: 平均 ${summary.avgBreathRate}，最低 ${summary.minBreathRate.toInt()}，最高 ${summary.maxBreathRate.toInt()} 次/分")
        }
        emitSleepBedWindow(
            summary.bedTime,
            summary.fallAsleepTime,
            summary.wakeupTime,
            summary.risingTime,
            summary.sleepScore,
            summary.sleepEfficiency,
            summary.wakeCount
        )
    }

    /** 分钟级分期按连续相同阶段合并后下发；时间单位是秒，和 TruSleep 文件一致。 */
    private fun emitSleepDetailStages(stages: List<HuaweiTrueSleepSequenceDataParser.SleepStage>) {
        if (stages.isEmpty()) return
        var segStart = stages.first().time
        var segStage = sleepDetailStageName(stages.first().stage)
        var prevTime = segStart
        for (i in 1 until stages.size) {
            val stage = stages[i]
            val name = sleepDetailStageName(stage.stage)
            if (name != segStage || stage.time != prevTime + 60) {
                emitSleepDetailSegment(segStart, prevTime + 60, segStage)
                segStart = stage.time
                segStage = name
            }
            prevTime = stage.time
        }
        emitSleepDetailSegment(segStart, prevTime + 60, segStage)
    }

    private fun emitSleepDetailSegment(startSec: Long, endSec: Long, stage: String) {
        if (stage == "unknown" || endSec <= startSec) return
        emit(JSONObject()
            .put("t", "sleep_segment")
            .put("start", startSec)
            .put("end", endSec)
            .put("stage", stage)
            .put("source", 0x0d))
    }

    private fun sleepDetailStageName(status: Int): String = when (status and 0xFF) {
        1 -> "light"
        2 -> "rem"
        3 -> "deep"
        4 -> "awake"
        5, 6 -> "sleep"
        else -> "unknown"
    }

    /** 压力真通道：0x2C/1 rrisqi_data.bin，v3 记录第 12 字节就是手表算好的分值。 */
    private fun maybeSyncStressFile() {
        val now = System.currentTimeMillis()
        if (now - lastStressFileSyncAt < STRESS_FILE_SYNC_INTERVAL_MS) return
        lastStressFileSyncAt = now
        downloadStressFile(7)
    }

    private fun downloadStressFile(days: Int) {
        val end = (System.currentTimeMillis() / 1000).toInt()
        val start = end - days * 86_400
        FileLogger.i(TAG, "请求压力文件(0x2C/1) window=$start..$end")
        fileDownloadManager.addToQueue(
            HuaweiFileDownloadManager.FileRequest.periodRriFileRequest(
                start,
                end,
                object : HuaweiFileDownloadManager.FileDownloadCallback() {
                    override fun downloadComplete(fileRequest: HuaweiFileDownloadManager.FileRequest) {
                        val data = fileRequest.data
                        FileLogger.i(TAG, "压力文件完成: ${fileRequest.filename} ${HuaweiPeriodRriFileParser.describe(data)}")
                        if (data.isEmpty()) return
                        try {
                            val result = HuaweiPeriodRriFileParser.parse(data)
                            if (result.version != 3) {
                                addLog("压力：手表给的是原始 RR 数据（v${result.version}），暂不入库")
                                return
                            }
                            var stored = 0
                            for (record in result.records) {
                                if (record.score !in 1..100) continue
                                emit(
                                    JSONObject()
                                        .put("t", "stress")
                                        .put("ts", record.startTimeSec * 1000L)
                                        .put("v", record.score)
                                )
                                stored++
                            }
                            addLog("压力同步完成: $stored 条")
                        } catch (e: Exception) {
                            FileLogger.e(TAG, "压力文件解析失败", e)
                            addLog("压力文件解析失败：${e.message ?: e.javaClass.simpleName}")
                        }
                    }

                    override fun downloadException(e: HuaweiFileDownloadManager.HuaweiFileDownloadException) {
                        FileLogger.e(TAG, "压力文件下载失败", e)
                        addLog("压力文件下载失败：${e.message ?: e.javaClass.simpleName}")
                    }
                }
            ),
            true
        )
    }

    /** 同步窗口 = 上次成功位置 → 现在；从 2000-01-01 起说明是全量重拉 */
    private fun syncWindowText(fromSeconds: Int, toSeconds: Int): String {
        val from = if (fromSeconds <= DEFAULT_SYNC_START) "全量" else formatTs(fromSeconds)
        return "$from → ${formatTs(toSeconds)}"
    }

    private fun formatTs(seconds: Int): String =
        Instant.ofEpochSecond(seconds.toLong()).atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("MM-dd HH:mm"))

    private fun elapsedText(): String {
        val ms = System.currentTimeMillis() - roundStartedAt
        return if (ms < 1000) "${ms}ms" else "${ms / 1000}s"
    }

    private fun getLastSyncStart(): Int {
        val saved = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address).getLong(LAST_SYNC_KEY, 0L)
        return if (saved > 0) (saved / 1000).toInt() else DEFAULT_SYNC_START
    }

    private fun saveLastSyncEnd(endSeconds: Int) {
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
            .edit().putLong(LAST_SYNC_KEY, endSeconds * 1000L).apply()
    }

    // ==================== GPS 星历 ====================

    /**
     * 星历链路：设置里填了自托管 ephemeris.zip 地址后，
     * 连接就绪 / 每 10 分钟 / 手表开口要星历时都会自动补下载，
     * 本地文件有效期内由 [HuaweiEphemerisManager] 直接按手表请求分片上传。
     */
    fun setEphemerisUrl(url: String) {
        HuaweiEphemerisUpdater.setUrl(appContext, url)
        if (url.isNotBlank()) refreshEphemerisIfConfigured()
    }

    /** 星历状态：本地文件新旧、手表最近一次协商、下载进度，供详情页展示 */
    fun ephemerisStatus(): JSONObject {
        val info = HuaweiEphemerisUpdater.getFileInfo(appContext)
        val prefs = appContext.getSharedPreferences(EPHEMERIS_PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        return JSONObject()
            .put("url", HuaweiEphemerisUpdater.getUrl(appContext))
            .put("exists", info.exists)
            .put("size", info.sizeBytes)
            .put("fileTime", info.fileTimeMillis ?: 0L)
            .put("agnssTime", info.agnssEpochMillis ?: 0L)
            .put("agnssCrc", info.agnssCrc16 ?: -1)
            .put("agnssUnchangedMs", info.agnssUnchangedMs ?: -1L)
            .put("ageMs", if (info.fileTimeMillis == null) -1L else now - info.fileTimeMillis)
            .put("needsRefresh", HuaweiEphemerisUpdater.needsRefresh(appContext))
            .put("downloading", HuaweiEphemerisUpdater.isDownloading())
            .put("error", HuaweiEphemerisUpdater.lastError() ?: "")
            .put("consultTag", prefs.getString("last_consult_tag", "") ?: "")
            .put("consultVer", prefs.getInt("last_consult_ver", -1))
            .put("consultMs", prefs.getLong("last_consult_ms", 0L))
    }

    /** App 启动时后台自检：本地缺文件或已过期才补下载，不等手表先连上。 */
    fun ensureEphemerisDownloaded() {
        refreshEphemerisIfConfigured()
    }

    /** 手动强制下载一次（详情页「立即下载」），结果通过回调回显 */
    fun downloadEphemerisNow(onDone: (String) -> Unit) {
        if (HuaweiEphemerisUpdater.getUrl(appContext).isBlank()) {
            onDone("未配置星历下载地址")
            return
        }
        if (HuaweiEphemerisUpdater.isDownloading()) {
            onDone("星历下载正在进行中")
            return
        }
        Thread {
            val result = HuaweiEphemerisUpdater.downloadIfNeeded(appContext, force = true)
            val msg = result.fold(
                onSuccess = { "星历下载成功（time=$it）" },
                onFailure = { "星历下载失败：${it.message}" }
            )
            addLog(msg)
            if (result.isSuccess) {
                addLog("星历文件已就绪，准备推送到手表")
                maybeProactiveEphemerisPush()
            }
            onDone(msg)
        }.start()
    }

    fun isWorkoutRealtimeEnabled(): Boolean = workoutLiveTracker.isEnabled()

    fun setWorkoutRealtimeEnabled(enabled: Boolean): Boolean =
        workoutLiveTracker.setEnabled(enabled)

    fun workoutRealtimeStatusJson(): String =
        workoutLiveTracker.statusJson().toString()

    fun workoutLiveSnapshotJson(): String = workoutLiveTracker.snapshotJson()

    /** 由通知监听服务调用：把手机通知推到手表。 */
    fun pushNotification(
        title: String?,
        sender: String?,
        body: String?,
        sourceAppId: String?,
        type: NotificationType?,
    ) {
        if (sourceAppId == "com.awen.lynkcar") return
        if (state != "ready" || transport == null) return
        if (!watchPrefs().getBoolean("notification_forward", true)) return
        Thread({
            try {
                val spec = NotificationSpec().apply {
                    this.title = title
                    this.sender = sender
                    this.body = body
                    this.sourceAppId = sourceAppId
                    this.type = type ?: NotificationType.UNKNOWN
                }
                val request = SendNotificationRequest(this@VitaloopWatchManager)
                request.buildNotificationTLVFromNotificationSpec(spec)
                request.setupTimeoutUntilNext(5_000)
                request.doPerform()
                addLog("通知已推送到手表: ${sourceAppId ?: "系统"} ${title ?: ""}")
            } catch (e: Exception) {
                FileLogger.e(TAG, "通知推送失败", e)
            }
        }, "VitaloopNotify").apply { isDaemon = true; start() }
    }

    fun clearNotification() {
        if (state != "ready") return
        Thread({
            try {
                StopNotificationRequest(this@VitaloopWatchManager).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
            } catch (e: Exception) {
                FileLogger.e(TAG, "清除通知失败", e)
            }
        }, "VitaloopNotifyClear").apply { isDaemon = true; start() }
    }

    // ==================== 来电转发与手表通话控制 ====================

    private var phoneStateListener: PhoneStateListener? = null
    private var callListenerRegistered = false
    private var callRinging = false

    /** 连接就绪后监听手机来电，并把来电推到手表。 */
    fun startCallForwarding() {
        if (!watchPrefs().getBoolean("notification_forward", true)) return
        if (appContext.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            addLog("来电转发未开启：缺少电话状态权限")
            return
        }
        mainHandler.post {
            if (callListenerRegistered) return@post
            try {
                val telephony =
                    appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                        ?: return@post
                val listener = phoneStateListener ?: object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        when (state) {
                            TelephonyManager.CALL_STATE_RINGING -> {
                                callRinging = true
                                val name = phoneNumber?.let { lookupContactName(it) }
                                pushCallNotification(name ?: phoneNumber)
                            }
                            TelephonyManager.CALL_STATE_IDLE -> {
                                if (callRinging) {
                                    callRinging = false
                                    clearNotification()
                                }
                            }
                        }
                    }
                }.also { phoneStateListener = it }
                @Suppress("DEPRECATION")
                telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
                callListenerRegistered = true
                addLog("来电转发已开启")
            } catch (e: Exception) {
                FileLogger.e(TAG, "开启来电转发失败", e)
            }
        }
    }

    fun stopCallForwarding() {
        mainHandler.post {
            try {
                val telephony =
                    appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                val listener = phoneStateListener
                if (listener != null && telephony != null) {
                    @Suppress("DEPRECATION")
                    telephony.listen(listener, PhoneStateListener.LISTEN_NONE)
                }
            } catch (e: Exception) {
                FileLogger.e(TAG, "停止来电转发失败", e)
            }
            phoneStateListener = null
            callListenerRegistered = false
            callRinging = false
        }
    }

    private fun lookupContactName(number: String): String? = try {
        val uri = ContactsContract.PhoneLookup.CONTENT_FILTER_URI.buildUpon()
            .appendPath(number)
            .build()
        appContext.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(ContactsContract.PhoneLookup.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            } else {
                null
            }
        }
    } catch (e: Exception) {
        FileLogger.e(TAG, "联系人姓名查询失败", e)
        null
    }

    private fun pushCallNotification(name: String?) {
        if (state != "ready" || transport == null) return
        if (!watchPrefs().getBoolean("notification_forward", true)) return
        Thread({
            try {
                val spec = CallSpec().apply {
                    this.name = name?.takeIf { it.isNotBlank() } ?: "未知来电"
                    this.number = ""
                }
                val request = SendNotificationRequest(this@VitaloopWatchManager)
                request.buildNotificationTLVFromCallSpec(spec)
                request.setupTimeoutUntilNext(5_000)
                request.doPerform()
                addLog("来电已推送到手表: ${spec.name}")
            } catch (e: Exception) {
                FileLogger.e(TAG, "来电推送失败", e)
            }
        }, "VitaloopCallNotify").apply { isDaemon = true; start() }
    }

    /** 处理手表上的接听/挂断按钮；权限不足时明确提示，不谎报成功。 */
    private fun handleWatchCallAction(action: Calls.AnswerCallResponse.Action) {
        if (action == Calls.AnswerCallResponse.Action.UNKNOWN) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            addLog("当前 Android 版本不支持从手表控制通话")
            clearNotification()
            return
        }
        if (appContext.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            addLog("手表通话控制未授权，请在权限管理里允许「接听/挂断电话」")
            return
        }
        val telecom = appContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        if (telecom == null) {
            addLog("系统电话服务不可用")
            return
        }
        try {
            when (action) {
                Calls.AnswerCallResponse.Action.CALL_ACCEPT -> {
                    telecom.acceptRingingCall()
                    addLog("已接听手机来电")
                }
                Calls.AnswerCallResponse.Action.CALL_REJECT -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                        addLog("Android 8.x 不支持从手表拒接来电")
                        return
                    }
                    telecom.endCall()
                    addLog("已拒接手机来电")
                }
                Calls.AnswerCallResponse.Action.UNKNOWN -> Unit
            }
            callRinging = false
            clearNotification()
        } catch (e: SecurityException) {
            addLog("手表通话控制失败：权限被系统拒绝")
            FileLogger.e(TAG, "手表通话控制权限失败", e)
        } catch (e: Exception) {
            addLog("手表通话控制失败: ${e.message}")
            FileLogger.e(TAG, "手表通话控制失败", e)
        }
    }

    private fun refreshEphemerisIfConfigured() {
        if (HuaweiEphemerisUpdater.getUrl(appContext).isBlank()) return
        if (!HuaweiEphemerisUpdater.needsRefresh(appContext)) return
        HuaweiEphemerisUpdater.refreshInBackground(appContext)
    }

    /**
     * 主动推送：手表只在开运动那一刻才来要星历（实测开跑后要等 ~30s 星历传完才出首个定位点），
     * 所以连接就绪后延迟 10s 主动喂一次。是否真推由 manager 内部的去重与时效判断决定。
     */
    private fun maybeProactiveEphemerisPush() {
        Thread {
            try {
                Thread.sleep(10_000)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (!isConnected) return@Thread
            try {
                ephemerisManager.tryProactivePush()
                addLog("已向手表发起星历主动协商")
            } catch (e: Exception) {
                FileLogger.e(TAG, "星历主动推送异常", e)
                addLog("星历主动推送失败：${e.message}")
            }
        }.start()
    }

    /** 同步循环里的定期检查：源每小时更新，提前把文件备好，手表来要时不用等下载 */
    private fun maybeRefreshEphemeris() {
        val now = System.currentTimeMillis()
        if (now - lastEphemerisCheckAt < EPHEMERIS_CHECK_INTERVAL_MS) return
        lastEphemerisCheckAt = now
        refreshEphemerisIfConfigured()
    }

    // ==================== 数据回调（JSON 事件） ====================

    override fun addStepData(timestamp: Int, steps: Short, calories: Short, distance: Short, spo: Byte, heartrate: Byte, restingHeartRate: Byte) {
        if (heartrate.toInt() != NOT_MEASURED.toInt() && heartrate.toInt() > 0) {
            latestHeartRate = heartrate.toInt()
            latestHeartRateTime = System.currentTimeMillis()
            emit(JSONObject()
                .put("t", "hr")
                .put("ts", timestamp * 1000L)
                .put("bpm", heartrate.toInt()))
        }
        if (spo.toInt() != NOT_MEASURED.toInt() && spo.toInt() > 0) {
            val bucket = timestamp / 60L
            if (bucket != lastSpo2Bucket) {
                lastSpo2Bucket = bucket
                emit(JSONObject()
                    .put("t", "spo2")
                    .put("ts", timestamp * 1000L)
                    .put("v", spo.toInt()))
            }
        }
        if (restingHeartRate.toInt() != NOT_MEASURED.toInt() && restingHeartRate.toInt() > 0) {
            val day = timestamp / 86400L
            if (day != lastRestingHrDay) {
                lastRestingHrDay = day
                emit(JSONObject()
                    .put("t", "resting_hr")
                    .put("ts", timestamp * 1000L)
                    .put("v", restingHeartRate.toInt()))
            }
        }
        emit(JSONObject()
            .put("t", "step_sample")
            .put("ts", timestamp.toLong())
            .put("steps", steps.toInt())
            .put("calories", (calories.toInt() + 500) / 1000)
            .put("distance", distance.toInt()))
    }

    override fun addSleepActivity(timestampStart: Int, timestampEnd: Int, type: Byte, source: Byte) {
        val stage = when (type.toInt() and 0xFF) {
            0x01 -> "light"
            0x02 -> "rem"
            0x03 -> "deep"
            0x04 -> "awake"
            0x05, 0x06 -> "sleep"
            else -> "unknown"
        }
        emit(JSONObject()
            .put("t", "sleep_segment")
            .put("start", timestampStart.toLong())
            .put("end", timestampEnd.toLong())
            .put("stage", stage)
            .put("source", source.toInt()))
    }

    override fun addTotalFitnessData(steps: Int, calories: Int, distance: Int) {
        emit(JSONObject()
            .put("t", "fitness_totals")
            .put("steps", steps)
            .put("calories", calories)
            .put("distance", distance))
    }

    override fun addDictData(dictData: List<HuaweiP2PDataDictionarySyncService.DictData>) {
        for (dict in dictData) {
            p2pDictEventCount++
            val sampleCursor = maxOf(dict.startTimestamp, dict.endTimestamp)
            val cursor = if (sampleCursor > 0) sampleCursor else dict.modifyTimestamp
            GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
                .edit()
                .putLong("dict_last_${dict.dictClass}", cursor)
                .putStringSet(
                    "dict_found_classes",
                    (GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
                        .getStringSet("dict_found_classes", emptySet()) ?: emptySet())
                        .plus(dict.dictClass.toString())
                )
                .apply()
            when (dict.dictClass) {
                HuaweiDictTypes.HRV_CLASS -> handleHrvDict(dict)
                HuaweiDictTypes.STRESS_CLASS -> handleStressDict(dict)
                HuaweiDictTypes.RESTING_HEART_RATE_CLASS -> handleRestingHeartRateDict(dict)
                HuaweiDictTypes.SKIN_TEMPERATURE_CLASS -> handleSkinTemperatureDict(dict)
                HuaweiDictTypes.BODY_TEMPERATURE_CLASS -> handleBodyTemperatureDict(dict)
                HuaweiDictTypes.SLEEP_ON_OFF_BED_CLASS -> handleSleepOnOffBedDict(dict)
                HuaweiDictTypes.EMOTION_CLASS -> handleEmotionDict(dict)
                HuaweiDictTypes.ARRHYTHMIA_CLASS -> handleArrhythmiaDict(dict)
                HuaweiDictTypes.SLEEP_APNEA_CLASS -> handleSleepApneaDict(dict)
                HuaweiDictTypes.HOURLY_STATUS_CLASS -> handleHourlyStatusDict(dict)
                HuaweiDictTypes.DAILY_RING_CLASS -> handleDailyRingDict(dict)
            }
        }
    }

    override fun getLastDataDictLastTimestamp(dictClass: Int): Long =
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
            .getLong("dict_last_$dictClass", 0L)

    private fun handleHrvDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.HRV_RMSSD_VALUE || value.tag.toInt() != 10) continue
            val rmssd = dictDouble(value.value) ?: continue
            if (rmssd !in 1.0..300.0) continue
            emit(
                JSONObject()
                    .put("t", "hrv")
                    .put("ts", dict.startTimestamp)
                    .put("v", rmssd)
            )
            addLog("HRV(RMSSD): ${Math.round(rmssd)}ms")
        }
    }

    private fun handleStressDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.STRESS_SCORE_VALUE || value.tag.toInt() != 10) continue
            val score = when (value.value.size) {
                4 -> ByteBuffer.wrap(value.value).int
                8 -> (dictDouble(value.value) ?: continue).let { Math.round(it).toInt() }
                else -> continue
            }
            if (score !in 1..100) continue
            val bucket = dict.startTimestamp / 60_000L
            if (bucket == lastStoredStressBucket) continue
            lastStoredStressBucket = bucket
            emit(
                JSONObject()
                    .put("t", "stress")
                    .put("ts", dict.startTimestamp)
                    .put("v", score)
            )
            addLog("压力: $score")
        }
    }

    private fun handleRestingHeartRateDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.tag.toInt() != 10) continue
            if (value.dataType != HuaweiDictTypes.RESTING_HEART_RATE_VALUE &&
                value.dataType != 2018
            ) continue
            val bpm = Math.round(dictDouble(value.value) ?: continue).toInt()
            if (bpm !in 30..150) continue
            emit(
                JSONObject()
                    .put("t", "resting_hr")
                    .put("ts", dict.startTimestamp)
                    .put("v", bpm)
            )
        }
    }

    private fun handleSkinTemperatureDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.SKIN_TEMPERATURE_VALUE || value.tag.toInt() != 10) continue
            val temperature = dictDouble(value.value) ?: continue
            if (temperature !in 20.0..42.0) continue
            val bucket = dict.startTimestamp / 60_000L
            if (bucket == lastStoredTemperatureBucket) continue
            lastStoredTemperatureBucket = bucket
            emit(
                JSONObject()
                    .put("t", "skin_temp")
                    .put("ts", dict.startTimestamp)
                    .put("v", temperature)
            )
        }
    }

    private fun handleBodyTemperatureDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.BODY_TEMPERATURE_VALUE || value.tag.toInt() != 10) continue
            val temperature = dictDouble(value.value) ?: continue
            if (temperature !in 34.0..42.0) continue
            emit(
                JSONObject()
                    .put("t", "body_temp")
                    .put("ts", dict.startTimestamp)
                    .put("v", temperature)
            )
        }
    }

    private fun handleSleepOnOffBedDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        var bed = 0L
        var fallAsleep = 0L
        var wake = 0L
        var rising = 0L
        for (value in dict.data) {
            val epochMs = decodeDictEpochMillis(value.value) ?: continue
            when (value.dataType) {
                HuaweiDictTypes.SLEEP_BED_TIME_VALUE -> bed = epochMs
                HuaweiDictTypes.SLEEP_FALL_ASLEEP_TIME_VALUE -> fallAsleep = epochMs
                HuaweiDictTypes.SLEEP_WAKEUP_TIME_VALUE -> wake = epochMs
                HuaweiDictTypes.SLEEP_RISING_TIME_VALUE -> rising = epochMs
            }
        }
        emitSleepBedWindow(bed / 1000, fallAsleep / 1000, wake / 1000, rising / 1000)
    }

    /** 上床/入睡/醒来/离床统一按毫秒事件入库；0 表示该字段缺失。 */
    private fun emitSleepBedWindow(
        bedSec: Long,
        fallAsleepSec: Long,
        wakeSec: Long,
        risingSec: Long,
        sleepScore: Int = -1,
        sleepEfficiency: Int = -1,
        wakeCount: Int = -1,
    ) {
        val sessionStartSec = listOf(bedSec, fallAsleepSec, wakeSec, risingSec)
            .filter { it > 0 }
            .minOrNull()
            ?: return
        val event = JSONObject()
            .put("t", "sleep_bed")
            .put("session_start", sessionStartSec * 1000)
        if (bedSec > 0) event.put("bed", bedSec * 1000)
        if (fallAsleepSec > 0) event.put("fall_asleep", fallAsleepSec * 1000)
        if (wakeSec > 0) event.put("wake", wakeSec * 1000)
        if (risingSec > 0) event.put("rising", risingSec * 1000)
        if (fallAsleepSec > 0 && wakeSec > fallAsleepSec) {
            event.put("duration_min", (wakeSec - fallAsleepSec) / 60)
        }
        if (sleepScore in 1..100) event.put("score", sleepScore)
        if (sleepEfficiency in 1..100) event.put("efficiency", sleepEfficiency)
        if (wakeCount >= 0) event.put("wake_count", wakeCount)
        emit(event)
        addLog(
            "睡眠会话: 上床 ${formatEpoch(bedSec)}，入睡 ${formatEpoch(fallAsleepSec)}，" +
                "醒来 ${formatEpoch(wakeSec)}，评分 $sleepScore，效率 $sleepEfficiency"
        )
    }

    private fun decodeDictEpochMillis(bytes: ByteArray?): Long? {
        if (bytes == null || bytes.size < 8) return null
        val le = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val be = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val candidates = listOf(
            le.getLong(0),
            be.getLong(0),
            le.getDouble(0).toLong(),
            be.getDouble(0).toLong()
        )
        return candidates.firstNotNullOfOrNull { raw ->
            when {
                raw in 1_500_000_000L..4_100_000_000L -> raw * 1000
                raw in 1_500_000_000_000L..4_100_000_000_000L -> raw
                else -> null
            }
        }
    }

    private fun formatEpoch(seconds: Long): String =
        if (seconds <= 0) "--" else java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
            .format(java.util.Date(seconds * 1000))

    private fun handleEmotionDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        var status = 0
        var valence: Double? = null
        var arousal: Double? = null
        for (value in dict.data) {
            if (value.tag.toInt() != 10) continue
            val v = dictDouble(value.value) ?: continue
            when (value.dataType) {
                HuaweiDictTypes.EMOTION_STATUS_VALUE -> if (v in 0.0..99.0) status = Math.round(v).toInt()
                HuaweiDictTypes.EMOTION_VALENCE_VALUE -> if (v in 0.0..100.0) valence = v
                HuaweiDictTypes.EMOTION_AROUSAL_VALUE -> if (v in 0.0..100.0) arousal = v
            }
        }
        if (status == 0 && valence == null && arousal == null) return
        val event = JSONObject()
            .put("t", "emotion")
            .put("ts", dict.startTimestamp)
            .put("status", status)
        if (valence != null) event.put("valence", valence)
        if (arousal != null) event.put("arousal", arousal)
        emit(event)
    }

    private fun handleArrhythmiaDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        var result: Int? = null
        var measureType = 0
        for (value in dict.data) {
            when (value.dataType) {
                HuaweiDictTypes.PPG_IRREGULAR_HEARTBEAT_VALUE ->
                    result = decodeDictInt(value.value, 1, 5)
                HuaweiDictTypes.ARRHYTHMIA_MEASURE_TYPE_VALUE ->
                    measureType = decodeDictInt(value.value, 0, 1) ?: 0
            }
        }
        val type = result ?: return
        emit(
            JSONObject()
                .put("t", "arrhythmia")
                .put("ts", dict.startTimestamp)
                .put("result", type)
                .put("measure_type", measureType)
        )
        addLog("脉搏心律失常: 结果码 $type")
    }

    /** 睡眠呼吸暂停（P2P 字典 500002）：每条是当晚的风险级别。 */
    private fun handleSleepApneaDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.SLEEP_APNEA_LEVEL_VALUE || value.tag.toInt() != 10) continue
            val level = dictDouble(value.value) ?: continue
            if (level !in 0.0..10.0) continue
            emit(
                JSONObject()
                    .put("t", "apnea")
                    .put("ts", dict.startTimestamp)
                    .put("level", Math.round(level).toInt())
            )
            addLog("睡眠呼吸暂停: 级别=${Math.round(level).toInt()}")
        }
    }

    /** 每小时状态（P2P 字典 200005）：活动小时达标，值恒为 1。 */
    private fun handleHourlyStatusDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        for (value in dict.data) {
            if (value.dataType != HuaweiDictTypes.HOURLY_STATUS_VALUE || value.tag.toInt() != 10) continue
            val v = dictDouble(value.value) ?: continue
            emit(
                JSONObject()
                    .put("t", "active_hour")
                    .put("ts", dict.startTimestamp)
                    .put("v", Math.round(v).toInt())
            )
        }
    }

    /**
     * 官方每日活动三环（P2P 字典 300002）。
     * 手表每天 23:59:59 落一条当天汇总，单位保持官方口径：热量毫卡、分钟、小时。
     */
    private fun handleDailyRingDict(dict: HuaweiP2PDataDictionarySyncService.DictData) {
        var stepGoal = 0
        var stepUser = 0
        var stepState = 0
        var calorieGoalMilli = 0
        var calorieUserMilli = 0
        var calorieState = 0
        var durationGoalMin = 0
        var durationUserMin = 0
        var durationState = 0
        var activeGoalHours = 0
        var activeUserHours = 0
        var activeState = 0
        for (value in dict.data) {
            if (value.tag.toInt() != 10) continue
            val v = dictDouble(value.value) ?: continue
            when (value.dataType) {
                HuaweiDictTypes.RING_STEP_GOAL_VALUE -> stepGoal = v.toInt()
                HuaweiDictTypes.RING_STEP_USER_VALUE -> stepUser = v.toInt()
                HuaweiDictTypes.RING_STEP_GOAL_STATE_VALUE -> stepState = v.toInt()
                HuaweiDictTypes.RING_CALORIE_GOAL_VALUE -> calorieGoalMilli = v.toInt()
                HuaweiDictTypes.RING_CALORIE_USER_VALUE -> calorieUserMilli = v.toInt()
                HuaweiDictTypes.RING_CALORIE_GOAL_STATE_VALUE -> calorieState = v.toInt()
                HuaweiDictTypes.RING_DURATION_GOAL_VALUE -> durationGoalMin = v.toInt()
                HuaweiDictTypes.RING_DURATION_USER_VALUE -> durationUserMin = v.toInt()
                HuaweiDictTypes.RING_DURATION_GOAL_STATE_VALUE -> durationState = v.toInt()
                HuaweiDictTypes.RING_ACTIVE_GOAL_VALUE -> activeGoalHours = v.toInt()
                HuaweiDictTypes.RING_ACTIVE_USER_VALUE -> activeUserHours = v.toInt()
                HuaweiDictTypes.RING_ACTIVE_GOAL_STATE_VALUE -> activeState = v.toInt()
            }
        }
        if (stepUser <= 0 && calorieUserMilli <= 0 && durationUserMin <= 0 && activeUserHours <= 0) return
        emit(
            JSONObject()
                .put("t", "daily_ring")
                .put("end", dict.startTimestamp)
                .put("step_goal", stepGoal)
                .put("step_user", stepUser)
                .put("step_state", stepState)
                .put("calorie_goal_milli", calorieGoalMilli)
                .put("calorie_user_milli", calorieUserMilli)
                .put("calorie_state", calorieState)
                .put("duration_goal_min", durationGoalMin)
                .put("duration_user_min", durationUserMin)
                .put("duration_state", durationState)
                .put("active_goal_hours", activeGoalHours)
                .put("active_user_hours", activeUserHours)
                .put("active_state", activeState)
        )
        addLog(
            "每日三环: 步数=$stepUser/$stepGoal 热量=$calorieUserMilli/$calorieGoalMilli " +
                "锻炼=${durationUserMin}分 活动小时=$activeUserHours/$activeGoalHours"
        )
    }

    private fun dictDouble(bytes: ByteArray?): Double? {
        if (bytes == null || bytes.size < 8) return null
        return try {
            ByteBuffer.wrap(bytes).double
        } catch (_: Exception) {
            null
        }
    }

    private fun decodeDictInt(bytes: ByteArray?, min: Int, max: Int): Int? {
        if (bytes == null || bytes.isEmpty()) return null
        val le = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val be = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val candidates = when (bytes.size) {
            1 -> listOf(bytes[0].toInt() and 0xFF)
            2 -> listOf(le.getShort(0).toInt(), be.getShort(0).toInt())
            4 -> listOf(le.getInt(0), le.getFloat(0).toInt(), be.getInt(0), be.getFloat(0).toInt())
            8 -> listOf(
                le.getLong(0).toInt(), le.getDouble(0).toInt(),
                be.getLong(0).toInt(), be.getDouble(0).toInt()
            )
            else -> emptyList()
        }
        return candidates.firstOrNull { it in min..max }
    }

    // ==================== IHuaweiSupport 其余实现 ====================

    override fun getParamsProvider(): HuaweiPacket.ParamsProvider = paramsProvider
    override fun getHuaweiCoordinator(): HuaweiCoordinator = coordinator
    override fun getHuaweiType(): HuaweiCoordinatorSupplier.HuaweiDeviceType = HuaweiCoordinatorSupplier.HuaweiDeviceType.BR
    override fun getAndroidId(): ByteArray = androidId.toByteArray(Charsets.UTF_8)
    override fun getMacAddress(): ByteArray = macAddress.toByteArray(Charsets.UTF_8)
    override fun getDeviceMac(): String = gbDevice.address
    override fun getDevice(): GBDevice = gbDevice

    override fun getSecretKey(): ByteArray {
        val authKey = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address).getString("authkey", null)
        return if (authKey.isNullOrEmpty()) ByteArray(0) else StringUtils.hexToBytes(authKey)
    }

    override fun setSecretKey(authKey: ByteArray) {
        GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
            .edit().putString("authkey", StringUtils.bytesToHex(authKey)).apply()
        paramsProvider.setSecretKey(authKey)
    }

    override fun getContext(): Context = appContext
    override fun getProtocolVersion(): Byte = protocolVersion
    override fun setProtocolVersion(protocolVersion: Byte) { this.protocolVersion = protocolVersion }

    @Synchronized
    override fun write(data: ByteArray) {
        transport?.write(data)
    }

    override fun waitMillis(millis: Int) {
        try { Thread.sleep(millis.toLong()) } catch (_: InterruptedException) {}
    }

    override fun addInProgressRequest(request: Request) {
        responseManager.addHandler(request)
    }

    override fun removeInProgressRequests(vararg requests: Request) {
        responseManager.removeHandlers(listOf(*requests))
    }

    override fun evaluateGBDeviceEvent(event: Any?) {
        // 电量等设备事件暂不上抛
    }

    override fun startBatteryRunnerDelayed(): Boolean = false

    override fun initializeDynamicServices() {
        // 动态服务就绪后先下发配置，再读手表闹钟，最后进入定时同步。
        onReady()
    }

    // ==================== 闹钟 ====================

    fun alarmsJson(): String {
        val address = alarmAddress()
        if (address.isBlank()) return "[]"
        return Gson().toJson(getSavedAlarms(address))
    }

    /** 保存本机闹钟；连接就绪时立即同步，否则等下次连接后补发。 */
    fun saveAlarmsJson(json: String): Boolean {
        val address = alarmAddress()
        if (address.isBlank()) return false
        val alarms = try {
            Gson().fromJson(json, Array<WatchAlarm>::class.java)?.toList() ?: emptyList()
        } catch (e: Exception) {
            FileLogger.e(TAG, "解析闹钟 JSON 失败", e)
            return false
        }
        saveAlarms(address, alarms)
        GBApplication.getDeviceSpecificSharedPrefs(address)
            .edit().putBoolean(KEY_ALARMS_PENDING, true).apply()
        addLog("闹钟已保存到本机（${alarms.size} 条）")
        syncAlarmsNow()
        return true
    }

    fun syncAlarmsNow() {
        val address = alarmAddress()
        if (address.isBlank()) return
        val alarms = getSavedAlarms(address)
        if (alarms.isEmpty()) {
            addLog("本机没有闹钟可同步")
            return
        }
        if (!coordinator.supportsChangingAlarm()) {
            addLog("当前手表不支持修改闹钟")
            return
        }
        if (state != "ready") {
            addLog("手表未连接，闹钟将在下次连接时同步")
            return
        }
        Thread({
            val deadline = System.currentTimeMillis() + 60_000
            while (System.currentTimeMillis() < deadline && linkBusyExceptAlarm()) {
                try { Thread.sleep(400) } catch (_: InterruptedException) { return@Thread }
            }
            if (linkBusyExceptAlarm()) {
                addLog("手表链路忙，闹钟将在下次连接时同步")
                return@Thread
            }
            sendAlarmsToWatch(alarms, "用户保存")
        }, "VitaloopWatchAlarms").apply { start() }
    }

    private fun alarmAddress(): String =
        gbDevice.address.ifBlank { watchPrefs().getString(KEY_ADDRESS, null) ?: "" }

    /** 是否启用“周末/法定节假日自动跳过”，默认开启。 */
    fun isHolidaySkipEnabled(address: String = alarmAddress()): Boolean =
        address.isNotBlank() &&
            GBApplication.getDeviceSpecificSharedPrefs(address)
                .getBoolean(KEY_HOLIDAY_SKIP, true)

    fun setHolidaySkipEnabled(enabled: Boolean, address: String = alarmAddress()): Boolean {
        if (address.isBlank()) return false
        GBApplication.getDeviceSpecificSharedPrefs(address)
            .edit().putBoolean(KEY_HOLIDAY_SKIP, enabled).apply()
        addLog(if (enabled) "已开启周末/节假日跳过" else "已关闭周末/节假日跳过")
        syncAlarmsNow()
        return true
    }

    /** 今天是否按工作日处理（关闭跳过时永远返回 true）。 */
    fun isTodayWorkday(address: String = alarmAddress()): Boolean {
        if (!isHolidaySkipEnabled(address)) return true
        return HolidayCalendar.isWorkday(appContext, LocalDate.now())
    }

    private fun linkBusy(): Boolean =
        state != "ready" || syncing || roundActive || workoutSyncing || p2pSyncing || weatherSyncing

    private fun linkBusyExceptAlarm(): Boolean = linkBusy() || alarmSyncing

    private fun startAlarmReadChain() {
        val address = gbDevice.address
        if (address.isBlank()) {
            alarmSyncing = false
            return
        }
        if (!coordinator.supportsChangingAlarm()) {
            alarmSyncing = false
            addLog("当前手表不支持读取/修改闹钟")
            return
        }
        alarmSyncing = true
        Thread({
            val deadline = System.currentTimeMillis() + 30_000
            while (System.currentTimeMillis() < deadline && linkBusy()) {
                try { Thread.sleep(300) } catch (_: InterruptedException) {
                    alarmSyncing = false
                    return@Thread
                }
            }
            if (linkBusy()) {
                alarmSyncing = false
                addLog("链路忙，本轮跳过闹钟读取")
                return@Thread
            }
            performAlarmRead(address)
        }, "VitaloopWatchAlarmRead").apply { start() }
    }

    private fun performAlarmRead(address: String) {
        val queue = listOf(GetEventAlarmList(this), GetSmartAlarmList(this))
        for (i in 1 until queue.size) {
            queue[i - 1].setupTimeoutUntilNext(ALARM_TIMEOUT_MS)
            queue[i - 1].nextRequest(queue[i])
        }
        queue.last().setupTimeoutUntilNext(ALARM_TIMEOUT_MS)
        queue.last().setFinalizeReq(object : Request.RequestCallback() {
            override fun call() {
                alarmSyncing = false
                val prefs = GBApplication.getDeviceSpecificSharedPrefs(address)
                val pending = prefs.getBoolean(KEY_ALARMS_PENDING, false)
                val saved = getSavedAlarms(address)
                addLog("已读取手表闹钟 ${saved.size} 条")
                if (pending) {
                    if (saved.isNotEmpty()) sendAlarmsToWatch(saved, "补发本地修改")
                } else if (saved.isNotEmpty()) {
                    sendAlarmsToWatch(saved, "连接初始化")
                }
            }

            override fun handleException(e: Request.ResponseParseException) {
                alarmSyncing = false
                addLog("读取闹钟失败：${e.message}")
            }
        })
        try {
            queue.first().doPerform()
        } catch (e: Exception) {
            alarmSyncing = false
            FileLogger.e(TAG, "闹钟读取链下发失败", e)
            addLog("读取闹钟失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun sendAlarmsToWatch(alarms: List<WatchAlarm>, reason: String) {
        if (!coordinator.supportsChangingAlarm()) return
        val effective = if (!isTodayWorkday()) {
            alarms.map { it.copy(isEnabled = false) }
        } else {
            alarms
        }
        if (effective != alarms) {
            addLog("今日休息（周末/节假日），闹钟已临时跳过")
        }
        alarmSyncing = true
        val queue = mutableListOf<Request>()
        val smart = effective.firstOrNull { it.index == 0 }
        if (smart != null && coordinator.supportsSmartAlarm(gbDevice)) {
            val req = AlarmsRequest(this, true)
            req.buildSmartAlarm(smart)
            queue += req
        }
        val events = AlarmsRequest(this, false)
        // 1..5 全部下发：缺失的槽位用禁用占位清掉，否则手表上删掉的闹钟还会响。
        for (index in 1..5) {
            val alarm = effective.firstOrNull { it.index == index }
                ?: WatchAlarm(index, false, 0, 0, 0, "闹钟")
            events.addEventAlarm(alarm, false)
        }
        queue += events
        for (i in 1 until queue.size) {
            queue[i - 1].setupTimeoutUntilNext(ALARM_TIMEOUT_MS)
            queue[i - 1].nextRequest(queue[i])
        }
        queue.last().setupTimeoutUntilNext(ALARM_TIMEOUT_MS)
        queue.last().setFinalizeReq(object : Request.RequestCallback() {
            override fun call() {
                alarmSyncing = false
                val address = gbDevice.address
                if (address.isNotBlank()) {
                    GBApplication.getDeviceSpecificSharedPrefs(address)
                        .edit().putBoolean(KEY_ALARMS_PENDING, false).apply()
                }
                addLog("闹钟已同步到手表（$reason）")
            }

            override fun handleException(e: Request.ResponseParseException) {
                alarmSyncing = false
                addLog("闹钟同步失败：${e.message}")
            }
        })
        try {
            queue.first().doPerform()
        } catch (e: Exception) {
            alarmSyncing = false
            FileLogger.e(TAG, "闹钟同步链下发失败", e)
            addLog("闹钟同步失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun getSavedAlarms(address: String): List<WatchAlarm> {
        if (address.isBlank()) return emptyList()
        val json = GBApplication.getDeviceSpecificSharedPrefs(address)
            .getString(KEY_ALARMS, null) ?: return emptyList()
        return try {
            Gson().fromJson(json, Array<WatchAlarm>::class.java)?.toList() ?: emptyList()
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取本地闹钟失败", e)
            emptyList()
        }
    }

    private fun saveAlarms(address: String, alarms: List<WatchAlarm>) {
        if (address.isBlank()) return
        val normalized = alarms
            .filter { it.index in 0..5 }
            .distinctBy { it.index }
            .sortedBy { it.index }
            .map {
                it.copy(
                    hourOfDay = it.hourOfDay.coerceIn(0, 23),
                    minuteOfHour = it.minuteOfHour.coerceIn(0, 59),
                    repeatMask = it.repeatMask and 0x7f,
                )
            }
        GBApplication.getDeviceSpecificSharedPrefs(address)
            .edit().putString(KEY_ALARMS, Gson().toJson(normalized)).apply()
    }

    override fun downloadQueueEmpty(needSync: Boolean) {}
    override fun isWorkoutDeleted(workoutNumber: Int): Boolean = false

    override fun addWorkoutTotalsData(packet: Workout.WorkoutTotals.Response): Long? {
        val key = packet.number.toLong()
        val acc = workoutAccum.getOrPut(key) { WorkoutAccum(packet.number) }
        acc.totals = packet
        return key
    }

    override fun addWorkoutSampleData(workoutId: Long?, dataList: List<Workout.WorkoutData.Response.Data>) {
        val acc = workoutAccum[workoutId ?: return] ?: return
        synchronized(acc.samples) { acc.samples.addAll(dataList) }
    }

    override fun addWorkoutPaceData(workoutId: Long?, paceList: List<Workout.WorkoutPace.Response.Block>, number: Short) {
        val acc = workoutAccum[workoutId ?: return] ?: return
        synchronized(acc.pace) { acc.pace.addAll(paceList) }
    }

    override fun addWorkoutSwimSegmentsData(workoutId: Long?, segmentsList: List<Workout.WorkoutSwimSegments.Response.Block>, number: Short) {
        val acc = workoutAccum[workoutId ?: return] ?: return
        synchronized(acc.segments) { acc.segments.addAll(segmentsList) }
    }

    override fun downloadWorkoutGpsFiles(workoutId: Short, databaseId: Long?, extraCallbackAction: Runnable?) {
        val key = databaseId ?: workoutId.toLong()
        val acc = workoutAccum.getOrPut(key) { WorkoutAccum(workoutId) }
        var finished = false
        val finish = {
            if (!finished) {
                finished = true
                acc.gpsDone = true
                emitWorkout(acc)
            }
            extraCallbackAction?.run()
        }
        val retryNumber = workoutId.toInt()
        val retryStartMs = (acc.totals?.startTime?.toLong() ?: 0L) * 1000L
        try {
            fileDownloadManager.addToQueue(
                HuaweiFileDownloadManager.FileRequest.workoutGpsFileRequest(
                    coordinator.supportsGpsNewSync(),
                    workoutId,
                    key,
                    object : HuaweiFileDownloadManager.FileDownloadCallback() {
                        override fun downloadComplete(fileRequest: HuaweiFileDownloadManager.FileRequest) {
                            val data = fileRequest.data
                            if (data.isNotEmpty()) {
                                runCatching { HuaweiGpsParser.parseHuaweiGps(data).toList() }
                                    .onSuccess { points ->
                                        acc.track = points
                                        clearGpsRetry(retryNumber)
                                        addLog("运动 #$workoutId 轨迹下载完成：${points.size} 个点")
                                    }
                                    .onFailure { addLog("运动 #$workoutId 轨迹解析失败：${it.message}") }
                            } else {
                                // 手表明确回了空文件：这条没有 GPS（室内运动），别再为它回退窗口
                                clearGpsRetry(retryNumber)
                                addLog("运动 #$workoutId 无 GPS 轨迹（室内运动）")
                            }
                            finish()
                        }

                        override fun downloadException(e: HuaweiFileDownloadManager.HuaweiFileDownloadException) {
                            // 下载失败≠没有轨迹：链路忙/文件未就绪都可能是暂时的，登记后冷却重拉
                            recordGpsRetry(retryNumber, retryStartMs)
                            addLog("运动 #$workoutId 轨迹下载失败：${e.message}")
                            finish()
                        }
                    }
                ),
                true
            )
        } catch (e: Exception) {
            recordGpsRetry(retryNumber, retryStartMs)
            addLog("运动 #$workoutId 轨迹请求失败：${e.message ?: e.javaClass.simpleName}")
            finish()
        }
    }

    override fun endOfWorkoutSync() {
        workoutSyncing = false
        workoutWatchdog?.interrupt()
        workoutWatchdog = null
        val count = workoutAccum.size
        workoutAccum.clear()
        if (workoutWindowEnd > 0) {
            watchPrefs().edit()
                .putLong(KEY_WORKOUT_SYNC, workoutWindowEnd * 1000L)
                .putBoolean(KEY_WORKOUT_BACKFILL, true)
                .apply()
        }
        addLog("运动记录同步完成：本轮 $count 条（GPS ${if (coordinator.supportsGpsNewSync()) "直取" else "列表"}模式）")
    }

    /** 运动记录链：汇总→采样→配速→GPS 文件；整条链独立于健康数据同步 */
    private fun startWorkoutSync(end: Int) {
        if (workoutSyncing || alarmSyncing || weatherSyncing || transport == null) return
        workoutSyncing = true
        workoutWindowEnd = end
        workoutAccum.clear()
        val saved = watchPrefs().getLong(KEY_WORKOUT_SYNC, 0L)
        val backfill = !watchPrefs().getBoolean(KEY_WORKOUT_BACKFILL, false)
        val start = if (!backfill && saved > 0) {
            val natural = (saved / 1000).toInt() - WORKOUT_OVERLAP_SEC
            // 有到期的缺轨迹老记录时，把窗口起点再往前拉到那条之前，让全链重跑补齐
            dueGpsRetryFloorSec(end)?.let { minOf(natural, it) } ?: natural
        } else {
            end - WORKOUT_FIRST_WINDOW_SEC
        }
        armWorkoutWatchdog()
        addLog("开始同步运动记录：${syncWindowText(start, end)}")
        try {
            // 先问一次设备设置里的 gpsNewSync 能力：GT5 走 2C 直取 <id>_gps.bin，
            // 否则退回 0A 列表模式。能力缓存为空时该请求会自跳过。
            chain(
                listOf(GetSettingRelatedRequest(this), GetWorkoutCountRequest(this, start, end)),
                null
            )
        } catch (e: Exception) {
            workoutSyncing = false
            workoutWatchdog?.interrupt()
            workoutWatchdog = null
            addLog("运动记录同步失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun armWorkoutWatchdog() {
        workoutWatchdog?.interrupt()
        workoutWatchdog = Thread({
            try {
                Thread.sleep(WORKOUT_WATCHDOG_MS)
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (workoutSyncing) {
                workoutSyncing = false
                workoutAccum.clear()
                addLog("运动记录同步超时，下一轮重试")
            }
        }, "VitaloopWorkoutWatchdog").apply {
            isDaemon = true
            start()
        }
    }

    /** 把一条运动攒齐的数据一次性抛给 Rust；字段名与 [rust/src/watch.rs] 的 ingest 对齐 */
    private fun emitWorkout(acc: WorkoutAccum) {
        val p = acc.totals ?: return
        val samples = synchronized(acc.samples) { acc.samples.toList() }
        val hrArr = JSONArray()
        val altArr = JSONArray()
        val dynArr = JSONArray()
        var hrSum = 0L
        var hrCount = 0
        var sampleMax = 0
        val intervalSec = if (samples.size >= 2) {
            (samples[1].timestamp - samples[0].timestamp).coerceAtLeast(1)
        } else {
            5
        }
        for (d in samples) {
            val bpm = d.heartRate.toInt() and 0xFF
            if (bpm in 1..254) {
                hrArr.put(JSONObject().put("hr", bpm))
                hrSum += bpm
                hrCount++
                if (bpm > sampleMax) sampleMax = bpm
            }
            val alt = d.altitude
            if (alt != null && alt > 0) altArr.put(JSONObject().put("alt", alt))
            val rawStepRate = d.stepRate.toInt() and 0xFF
            val stepRate = if (rawStepRate > 0) {
                (rawStepRate * 60 + intervalSec / 2) / intervalSec
            } else {
                0
            }
            val cadence = when {
                stepRate > 0 -> stepRate
                d.rideCadence > 0 -> d.rideCadence.toInt()
                else -> d.cadence.toInt()
            }
            val power = if (d.cyclingPower > 0) d.cyclingPower.toInt() else d.ap.toInt()
            val speedKmh = if (d.speed > 0) d.speed * 0.36 else 0.0
            val hasDynamics = cadence > 0 || power > 0 || speedKmh > 0 ||
                d.stepLength > 0 || d.groundContactTime > 0 || d.hangTime > 0 ||
                d.spo2 > 0 || d.vo > 0f || d.gtb > 0f || d.vr > 0f
            if (hasDynamics) {
                val item = JSONObject()
                    .put("t", d.timestamp.toLong() * 1000L)
                    .put("cad", cadence)
                    .put("pwr", power)
                    .put("spd", speedKmh)
                if (stepRate > 0) item.put("sr", stepRate)
                if (d.stepLength > 0) item.put("sl", d.stepLength)
                if (d.groundContactTime > 0) item.put("gct", d.groundContactTime)
                if (d.hangTime > 0) item.put("ht", d.hangTime)
                if (d.spo2 > 0) item.put("spo2", d.spo2)
                if (d.vo > 0f) item.put("vo", d.vo)
                if (d.gtb > 0f) item.put("gtb", d.gtb * 100f)
                if (d.vr > 0f) item.put("vr", d.vr)
                dynArr.put(item)
            }
        }
        val trackArr = JSONArray()
        for (point in acc.track) {
            val item = JSONObject()
                .put("t", point.timestamp.toLong() * 1000L)
                .put("lat", point.latitude)
                .put("lon", point.longitude)
            if (point.altitudeSupported) item.put("alt", point.altitude)
            trackArr.put(item)
        }
        val paceArr = JSONArray()
        synchronized(acc.pace) {
            for ((index, b) in acc.pace.withIndex()) {
                val item = JSONObject()
                    .put("i", index)
                    .put("distance", b.distance.toInt())
                    .put("d", b.distance.toInt())
                    .put("pace", b.pace)
                    .put("type", b.type.toInt())
                    .put("point", b.pointIndex.toInt())
                if (b.hasCorrection) item.put("corr", b.correction.toInt())
                paceArr.put(item)
            }
        }
        val segArr = JSONArray()
        synchronized(acc.segments) {
            for (s in acc.segments) {
                segArr.put(
                    JSONObject()
                        .put("distance", s.distance.toInt())
                        .put("pace", s.pace)
                        .put("segment", s.segment.toInt())
                        .put("strokes", s.strokes.toInt())
                        .put("swolf", s.avgSwolf.toInt())
                        .put("time", s.time)
                        .put("swim_type", s.swimType.toInt())
                )
            }
        }
        val recoveryArr = JSONArray()
        p.recoveryHeartRates?.forEach { recoveryArr.put(it.toInt() and 0xFF) }
        val extendObj = JSONObject()
        for ((fieldId, value) in p.extendStats) extendObj.put(fieldId.toString(), value)
        val paceZones = JSONArray()
        val zoneMins = intArrayOf(
            p.runPaceZone1Min.toInt(),
            p.runPaceZone2Min.toInt(),
            p.runPaceZone3Min.toInt(),
            p.runPaceZone4Min.toInt(),
            p.runPaceZone5Min.toInt(),
        )
        val zoneTimes = intArrayOf(
            p.runPaceZone1Time.toInt(),
            p.runPaceZone2Time.toInt(),
            p.runPaceZone3Time.toInt(),
            p.runPaceZone4Time.toInt(),
            p.runPaceZone5Time.toInt(),
        )
        for (i in 0 until 5) {
            if (zoneMins[i] <= 0 && zoneTimes[i] < 0) continue
            val max = if (i == 4) p.runPaceZone5Max.toInt() else zoneMins[i + 1]
            val zone = JSONObject().put("zone", i + 1)
            if (zoneMins[i] > 0) zone.put("min", zoneMins[i])
            if (max > 0) zone.put("max", max)
            if (zoneTimes[i] >= 0) zone.put("time", zoneTimes[i])
            paceZones.put(zone)
        }
        val avgHr = if (hrCount > 0) (hrSum / hrCount).toInt() else 0
        val maxHr = maxOf(sampleMax, p.maxHeartRatePeak.toInt() and 0xFF)
        val obj = JSONObject()
            .put("t", "workout")
            .put("number", p.number.toInt())
            .put("type", p.type.toInt())
            .put("start", p.startTime)
            .put("end", p.endTime)
            .put("duration", p.duration)
            .put("total_time", p.totalTime)
            .put("distance", p.distance)
            .put("calories", p.calories)
            .put("steps", p.stepCount)
            .put("load", p.workoutLoad)
            .put("aerobic", p.workoutAerobicEffect)
            .put("anaerobic", p.workoutAnaerobicEffect.toInt())
            .put("recovery", p.recoveryTime.toInt())
            .put("max_met", p.maxMET)
            .put("elevation_gain", p.elevationGain ?: 0)
            .put("elevation_loss", p.elevationLoss ?: 0)
            .put("avg_hr", avgHr)
            .put("max_hr", maxHr)
            .put("samples", hrArr)
            .put("altitude", altArr)
            .put("dynamics", dynArr)
            .put("track", trackArr)
            .put("splits", paceArr)
            .put("segments", segArr)
            .put("recovery_hrs", recoveryArr)
            .put("training_points", p.trainingPoints)
            .put("epoc", p.epoc)
            .put("alg_type", p.algType.toInt() and 0xFF)
        if (extendObj.length() > 0) obj.put("stat_extend", extendObj)
        if (paceZones.length() > 0) obj.put("run_pace_zones", paceZones)
        p.maxAltitude?.let { obj.put("max_altitude", it) }
        p.minAltitude?.let { obj.put("min_altitude", it) }
        emit(obj)
        addLog("运动记录 #${p.number}：类型=${p.type} 距离=${p.distance}m 时长=${p.duration}s 采样=${hrArr.length()}")
    }
    override fun onAsyncPacket(packet: HuaweiPacket) {
        Log.d(TAG, "Async packet svc=0x${Integer.toHexString(packet.serviceId.toInt() and 0xff)} cmd=0x${Integer.toHexString(packet.commandId.toInt() and 0xff)}")
        workoutLiveTracker.onAsyncPacket(packet)
        if (packet.serviceId == Calls.id &&
            packet.commandId == Calls.AnswerCallResponse.id &&
            packet is Calls.AnswerCallResponse
        ) {
            handleWatchCallAction(packet.action)
            return
        }
        if (packet.serviceId == DeviceConfig.id &&
            packet.commandId == DeviceConfig.WearStatus.id.toByte()
        ) {
            val code = packet.tlv?.getByte(0x01, (-1).toByte())?.toInt()?.and(0xFF) ?: -1
            applyWearStatus(code, "手表推送")
            return
        }
        if (packet.serviceId == FileUpload.id) {
            handleFileUploadPacket(packet)
            return
        }
        if (packet.serviceId == FindPhone.id &&
            packet.commandId == FindPhone.Response.id &&
            packet is FindPhone.Response
        ) {
            if (packet.start) startFindPhoneRing() else stopFindPhoneRing()
            return
        }
        if (packet.serviceId == CameraRemote.id &&
            packet.commandId == CameraRemote.CameraRemoteStatus.id &&
            packet is CameraRemote.CameraRemoteStatus.Response
        ) {
            packet.event?.let { handleCameraRemoteEvent(it) }
            return
        }
        if (packet.serviceId == MusicControl.id) {
            handleMusicControlPacket(packet)
            return
        }
        if (packet.serviceId == Weather.id) {
            FileLogger.d(TAG, "手表请求天气同步")
            if (isWeatherSyncEnabled()) syncWeather()
            return
        }
        if (packet.serviceId == Watchface.id &&
            packet.commandId == Watchface.WatchfaceConfirm.id &&
            packet is Watchface.WatchfaceConfirm.Response
        ) {
            handleWatchfaceConfirm(packet)
            return
        }
        if (packet.serviceId == GpsAndTime.id) {
            handleGpsAndTimePacket(packet)
            return
        }
        if (packet.serviceId == Menstrual.id &&
            packet.commandId == Menstrual.ModifyTime.id &&
            packet is Menstrual.ModifyTime.Response
        ) {
            sendMenstrualModifyTimeAck()
            return
        }
        if (packet is P2P.P2PCommand.Response) {
            try {
                p2pManager.handlePacket(packet)
            } catch (e: Exception) {
                FileLogger.e(TAG, "P2P 包处理失败", e)
            }
            return
        }
        try {
            when (packet) {
                // 手表开口要星历：本地有可用文件就先应答、后台补新文件（不阻塞手表协议线程），
                // 完全没有文件时才阻塞等一次短超时下载，否则这次请求被静默忽略、AGNSS 补星历失效
                is Ephemeris.OperatorData.OperatorIncomingRequest -> {
                    if (packet.operationInfo.toInt() == 1 &&
                        HuaweiEphemerisUpdater.getUrl(appContext).isNotBlank() &&
                        HuaweiEphemerisUpdater.needsRefresh(appContext)
                    ) {
                        if (HuaweiEphemerisUpdater.hasUsableFile(appContext)) {
                            FileLogger.i(TAG, "手表请求星历：本地文件偏旧，后台刷新，本次用现有文件应答")
                            HuaweiEphemerisUpdater.refreshInBackground(appContext)
                        } else {
                            FileLogger.i(TAG, "手表请求星历：本地无可用文件，阻塞补下载（最多 6s）")
                            val refreshed = HuaweiEphemerisUpdater.downloadBlocking(appContext)
                            if (refreshed != null) {
                                FileLogger.i(TAG, "手表请求前补下载星历成功 time=${refreshed.getOrNull()}")
                            } else {
                                FileLogger.w(TAG, "手表请求前补下载星历失败/超时，本次按现有文件处理")
                            }
                        }
                    }
                    ephemerisManager.handleOperatorRequest(packet.operationInfo, packet.operationTime)
                }
                is EphemerisFileUpload.FileList.FileListIncomingRequest ->
                    ephemerisManager.handleFileSendRequest(packet.fileType, packet.productId)
                is EphemerisFileUpload.FileConsult.FileConsultIncomingRequest ->
                    ephemerisManager.handleFileConsultIncomingRequest(
                        packet.responseCode, packet.protocolVersion, packet.bitmapEnable,
                        packet.transferSize, packet.maxDataSize, packet.timeOut, packet.fileType
                    )
                is EphemerisFileUpload.QuerySingleFileInfo.QuerySingleFileInfoIncomingRequest ->
                    ephemerisManager.handleSingleFileIncomingRequest(packet.fileName)
                is EphemerisFileUpload.DataRequest.DataRequestIncomingRequest ->
                    ephemerisManager.handleDataRequestIncomingRequest(
                        packet.responseCode, packet.fileName, packet.offset, packet.len, packet.bitmap
                    )
                is EphemerisFileUpload.UploadData.UploadDataResponse ->
                    ephemerisManager.handleFileUploadResponse(packet.responseCode)
                is EphemerisFileUpload.UploadDone.UploadDoneIncomingRequest ->
                    ephemerisManager.handleFileDoneRequest(packet.uploadResult)
            }
        } catch (e: Exception) {
            Log.e(TAG, "星历包处理异常", e)
            FileLogger.e(TAG, "星历包处理异常 svc=${packet.serviceId} cmd=${packet.commandId}", e)
        }
    }

    private fun handleGpsAndTimePacket(packet: HuaweiPacket) {
        if (packet.commandId == GpsAndTime.GpsStatus.id) {
            val enableGps = (packet as? GpsAndTime.GpsStatus.Response)?.enableGps
            FileLogger.i(TAG, "手表请求 GPS: enableGps=$enableGps")
            Thread({
                try {
                    SendGpsStatusRequest(this).let {
                        it.setupTimeoutUntilNext(5_000)
                        it.doPerform()
                    }
                } catch (e: Exception) {
                    FileLogger.w(TAG, "GPS 状态回复失败: ${e.message}")
                }
            }, "VitaloopGpsStatus").apply { isDaemon = true; start() }
            when (enableGps) {
                true -> startWatchGpsStream()
                false -> stopWatchGpsStream()
                null -> Unit
            }
            return
        }
        // GT5 还会发 cmd=0x06/0x08、tag 0x01 为布尔开关的包。旧版实测按
        // enableGps 语义处理，flag=1 时开始辅助下发；未知语义的包只记日志。
        val flag = try {
            packet.tlv.getByte(0x01).toInt() and 0xFF
        } catch (_: Exception) {
            -1
        }
        FileLogger.i(
            TAG,
            "GpsAndTime 未识别命令: cmd=0x${Integer.toHexString(packet.commandId.toInt() and 0xFF)} flag=$flag",
        )
        if (flag == 1) startWatchGpsStream()
    }
    override fun openWeatherMapConditionCodeToHuaweiIcon(conditionCode: Int): Weather.WeatherIcon {
        return when (conditionCode) {
            500 -> Weather.WeatherIcon.LIGHT_RAIN
            501 -> Weather.WeatherIcon.RAIN
            502 -> Weather.WeatherIcon.HEAVY_RAIN
            503 -> Weather.WeatherIcon.RAIN_STORM
            504 -> Weather.WeatherIcon.SEVERE_RAIN_STORMS
            511 -> Weather.WeatherIcon.FREEZING_RAIN
            520 -> Weather.WeatherIcon.SHOWERS
            600 -> Weather.WeatherIcon.LIGHT_SNOW
            601 -> Weather.WeatherIcon.SNOW
            602 -> Weather.WeatherIcon.HEAVY_SNOW
            611 -> Weather.WeatherIcon.SLEET
            622 -> Weather.WeatherIcon.SNOWSTORMS
            701, 741 -> Weather.WeatherIcon.FOG
            721 -> Weather.WeatherIcon.HAZY
            751 -> Weather.WeatherIcon.SAND
            761 -> Weather.WeatherIcon.DUST
            762 -> Weather.WeatherIcon.DUST_STORM
            800 -> Weather.WeatherIcon.SUNNY
            801, 802 -> Weather.WeatherIcon.CLOUDY
            803, 804 -> Weather.WeatherIcon.OVERCAST
            else -> {
                if (conditionCode in 200..299) Weather.WeatherIcon.THUNDERSTORMS
                else if (conditionCode in 300..399) Weather.WeatherIcon.LIGHT_RAIN
                else if (conditionCode in 500..599) Weather.WeatherIcon.RAIN
                else if (conditionCode in 600..699) Weather.WeatherIcon.SNOW
                else Weather.WeatherIcon.UNKNOWN
            }
        }
    }
    override fun getHuaweiEphemerisManager(): HuaweiEphemerisManager = ephemerisManager
    override fun getUploadManager(): HuaweiUploadManager = huaweiUploadManager
    override fun setGpsParametersResponse(response: GpsAndTime.GpsParameters.Response?) {
        gpsParametersResponse = response
        if (response != null) {
            addLog(
                "GPS 参数已就绪：support=0x${Integer.toHexString(response.supportBitmap)} " +
                    "latLon=${response.supportsLatLon} speed=${response.supportsSpeed} " +
                    "alt=${response.supportsAltitude} acc=${response.supportsPrecision}",
            )
            FileLogger.i(
                TAG,
                "GPS parameters support=0x${Integer.toHexString(response.supportBitmap)} " +
                    "latLon=${response.supportsLatLon} speed=${response.supportsSpeed} " +
                    "alt=${response.supportsAltitude} acc=${response.supportsPrecision}",
            )
        }
    }
    override fun setInstalledAppList(appInfoList: MutableList<App.InstalledAppInfo>?) {
        synchronized(installedApps) {
            installedApps.clear()
            appInfoList?.forEach {
                installedApps.add(
                    InstalledApp(
                        packageName = it.packageName ?: "",
                        name = it.appName ?: it.packageName ?: "",
                        version = it.version ?: "",
                        versionCode = it.versionCode,
                    )
                )
            }
        }
        addLog("已获取手表应用列表：${installedApps.size} 个")
        emitTools()
    }

    override fun setAppDeviceParams(params: App.AppDeviceParams?) {
        appDeviceParams = params
        addLog("已获取手表应用参数：${params?.width ?: 0}x${params?.height ?: 0}")
        emitTools()
    }

    override fun saveMaxContactsCount(maxCount: Int) {
        maxContactsCount = maxCount.coerceAtLeast(0)
        addLog("手表联系人容量：$maxContactsCount")
        emitTools()
    }

    override fun onMusicOperationResponse(
        resultCode: Int,
        operation: Int,
        playlistIndex: Int,
        playlistName: String?,
        musicIds: MutableList<Int>?,
    ) {
        addLog(
            "音乐操作响应：result=$resultCode operation=$operation " +
                "playlist=$playlistIndex ids=${musicIds?.size ?: 0}"
        )
        emitTools()
    }

    override fun onMusicInfoParams(response: MusicControl.MusicInfoParams.Response?) {
        if (response == null) return
        val caps = response.params
        watchMusicCapacity = buildMusicCapacityText(
            caps.availableSpace,
            caps.currentMusicCount,
            caps.maxMusicCount,
            caps.supportedFormats,
        )
        addLog("手表音乐能力：$watchMusicCapacity")
        if (!musicSyncActive) {
            emitTools()
            return
        }
        musicFrameCount = response.frameCount
        musicFrameLimit = if (coordinator.supportsMoreMusic()) {
            minOf(response.frameCount, 250)
        } else {
            response.frameCount
        }
        musicCurrentFrame = 0
        musicEndFrame = 65535
        synchronized(watchMusicTracks) {
            watchMusicTracks.clear()
        }
        synchronized(watchMusicPlaylists) {
            watchMusicPlaylists.clear()
        }
        emitTools()
        requestNextMusicFrame()
    }

    override fun onExtendedMusicInfoParams(response: MusicControl.ExtendedMusicInfoParams.Response?) {
        val caps = response?.params ?: return
        watchMusicCapacity = buildMusicCapacityText(
            caps.availableSpace,
            caps.currentMusicCount,
            caps.maxMusicCount,
            caps.supportedFormats,
        )
        emitTools()
    }

    override fun onMusicListResponse(
        startFrame: Int,
        endFrame: Int,
        musicList: MutableList<GBDeviceMusic>?,
    ) {
        if (!musicSyncActive) return
        val list = musicList.orEmpty()
        synchronized(watchMusicTracks) {
            list.forEach {
                watchMusicTracks[it.id] = MusicTrack(
                    id = it.id,
                    title = it.title ?: "",
                    artist = it.artist ?: "",
                    fileName = it.fileName ?: "",
                )
            }
        }
        if (list.size == 2) musicEndFrame = list[1].id
        musicCurrentFrame = maxOf(musicCurrentFrame + 1, startFrame + 1)
        if (list.isEmpty() || musicCurrentFrame >= musicFrameLimit) {
            requestMusicPlaylists()
        } else {
            requestNextMusicFrame()
        }
    }

    override fun onMusicPlaylistResponse(
        playlists: MutableList<MusicControl.MusicPlaylists.Response.PlaylistData>?,
    ) {
        if (!musicSyncActive) return
        synchronized(watchMusicPlaylists) {
            watchMusicPlaylists.clear()
            musicPlaylistFrameCounts.clear()
            playlists.orEmpty().filter { it.id != 0 }.forEach {
                watchMusicPlaylists.add(
                    MusicPlaylist(id = it.id, name = it.name ?: "", frameCount = it.frameCount)
                )
                musicPlaylistFrameCounts.add(it.frameCount)
            }
        }
        musicPlaylistIndex = 0
        musicPlaylistPage = 0
        musicPlaylistPageIds.clear()
        emitTools()
        requestCurrentMusicPlaylist()
    }

    override fun onMusicPlaylistMusics(playlistId: Int, index: Int, musicIds: MutableList<Int>?) {
        if (!musicSyncActive) return
        val playlist = synchronized(watchMusicPlaylists) {
            watchMusicPlaylists.getOrNull(musicPlaylistIndex)
        }
        if (playlist == null || playlist.id != playlistId) {
            FileLogger.w(TAG, "歌单响应不匹配：expected=${playlist?.id} got=$playlistId")
            return
        }
        musicPlaylistPageIds.addAll(musicIds.orEmpty())
        musicPlaylistPage = maxOf(musicPlaylistPage, index) + 1
        val frameCount = musicPlaylistFrameCounts.getOrElse(musicPlaylistIndex) { 0 }
        if (musicPlaylistPage < frameCount) {
            requestCurrentMusicPlaylistPage()
        } else {
            synchronized(watchMusicPlaylists) {
                val idx = watchMusicPlaylists.indexOfFirst { it.id == playlistId }
                if (idx >= 0) {
                    watchMusicPlaylists[idx] = playlist.copy(musicIds = musicPlaylistPageIds.toList())
                }
            }
            musicPlaylistIndex++
            musicPlaylistPage = 0
            musicPlaylistPageIds.clear()
            emitTools()
            requestCurrentMusicPlaylist()
        }
    }

    override fun setInstalledWatchfaceInfoList(
        watchfaceInfoList: MutableList<Watchface.InstalledWatchfaceInfo>?,
    ) {
        synchronized(installedWatchfaces) {
            installedWatchfaces.clear()
            watchfaceInfoList.orEmpty().forEach {
                installedWatchfaces.add(
                    InstalledWatchface(
                        fileName = it.fileName ?: "",
                        version = it.version ?: "",
                        type = it.type.toInt() and 0xFF,
                        current = it.isCurrent,
                        factory = it.isFactory,
                    )
                )
            }
            currentWatchface = installedWatchfaces.firstOrNull { it.current }?.fileName ?: ""
        }
        addLog("已获取手表表盘列表：${installedWatchfaces.size} 个")
        emitTools()
        val list = synchronized(installedWatchfaces) { installedWatchfaces.toList() }
        if (list.isNotEmpty()) {
            val infoList = watchfaceInfoList.orEmpty()
            val generation = toolGeneration
            requestWatchfaceNamesLocked(infoList, generation)
        }
    }

    override fun setWatchfacesNames(watchFaceNames: MutableMap<String, String>?) {
        synchronized(watchfaceNames) {
            watchfaceNames.clear()
            watchFaceNames?.forEach { (key, value) -> watchfaceNames[key] = value }
        }
        addLog("已获取 ${watchFaceNames?.size ?: 0} 个表盘名称")
        emitTools()
    }

    override fun setWatchfaceDeviceParams(params: Watchface.WatchfaceDeviceParams?) {
        watchfaceDeviceParams = params
        addLog(
            "表盘能力：${params?.width ?: 0}x${params?.height ?: 0} " +
                "version=${params?.maxVersion ?: ""} fileType=${params?.supportFileType?.toInt() ?: 0}"
        )
        emitTools()
    }

    private fun buildMusicCapacityText(
        availableSpace: Int,
        currentCount: Int,
        maxCount: Int,
        supportedFormats: List<String>?,
    ): String {
        val formats = supportedFormats?.takeIf { it.isNotEmpty() }?.joinToString("/") ?: "未知"
        return "空间=$availableSpace，歌曲=$currentCount/$maxCount，格式=$formats"
    }

    private fun registerMediaSessionListener() {
        try {
            if (!getWatchSetting("music")) {
                unregisterMediaSessionListener()
                return
            }
            if (!VitaloopNotificationListenerService.isEnabled(appContext)) return
            val mgr = appContext.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
                ?: return
            val listener = ComponentName(appContext, VitaloopNotificationListenerService::class.java)
            if (mediaSessionListener == null) {
                val callback = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
                    val controller = controllers?.firstOrNull() ?: return@OnActiveSessionsChangedListener
                    val meta = controller.metadata
                    sendMusicNowPlaying(
                        meta?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                        meta?.getString(MediaMetadata.METADATA_KEY_TITLE),
                        controller.playbackState?.state == PlaybackState.STATE_PLAYING,
                    )
                }
                mgr.addOnActiveSessionsChangedListener(callback, listener, Handler(Looper.getMainLooper()))
                mediaSessionListener = callback
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "注册媒体会话监听失败", e)
        }
    }

    private fun unregisterMediaSessionListener() {
        try {
            val mgr = appContext.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
            mediaSessionListener?.let { mgr?.removeOnActiveSessionsChangedListener(it) }
            mediaSessionListener = null
        } catch (e: Exception) {
            FileLogger.e(TAG, "注销媒体会话监听失败", e)
        }
    }

    private fun sendMusicNowPlaying(artist: String?, title: String?, playing: Boolean) {
        currentMusicArtist = artist
        currentMusicTitle = title
        currentMusicPlaying = playing
        if (state != "ready") return
        Thread({
            try {
                val spec = MusicSpec().apply {
                    this.artist = artist ?: ""
                    album = ""
                    track = title ?: ""
                    duration = MusicSpec.MUSIC_UNKNOWN
                    trackCount = MusicSpec.MUSIC_UNKNOWN
                    trackNr = MusicSpec.MUSIC_UNKNOWN
                }
                val stateSpec = MusicStateSpec().apply {
                    state = (if (playing) MusicStateSpec.STATE_PLAYING else MusicStateSpec.STATE_PAUSED).toByte()
                    position = 0
                    playRate = 1
                }
                SetMusicRequest(this, stateSpec, spec).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                addLog("音乐信息已推送到手表：${title ?: "未知"} - ${artist ?: "未知"}")
            } catch (e: Exception) {
                FileLogger.e(TAG, "音乐推送失败", e)
            }
        }, "VitaloopMusicPush").apply { isDaemon = true; start() }
    }

    private fun queryActiveMediaAndPush() {
        try {
            if (!VitaloopNotificationListenerService.isEnabled(appContext)) {
                addLog("音乐控制需要先授权通知使用权")
                return
            }
            val mgr = appContext.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
            val listener = ComponentName(appContext, VitaloopNotificationListenerService::class.java)
            val controller = mgr?.getActiveSessions(listener)?.firstOrNull()
            if (controller == null) {
                addLog("当前没有可控制的媒体")
                return
            }
            val meta = controller.metadata
            sendMusicNowPlaying(
                meta?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                meta?.getString(MediaMetadata.METADATA_KEY_TITLE),
                controller.playbackState?.state == PlaybackState.STATE_PLAYING,
            )
        } catch (e: Exception) {
            FileLogger.e(TAG, "查询媒体信息失败", e)
            addLog("查询媒体信息失败：${e.message}")
        }
    }

    private fun handleMusicButton(button: MusicControl.Control.Response.Button?) {
        if (button == null) return
        try {
            if (!VitaloopNotificationListenerService.isEnabled(appContext)) {
                addLog("音乐控制需要先授权通知使用权")
                return
            }
            val mgr = appContext.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
            val listener = ComponentName(appContext, VitaloopNotificationListenerService::class.java)
            val controller = mgr?.getActiveSessions(listener)?.firstOrNull() ?: return
            when (button) {
                MusicControl.Control.Response.Button.Play -> controller.transportControls.play()
                MusicControl.Control.Response.Button.Pause -> controller.transportControls.pause()
                MusicControl.Control.Response.Button.Previous -> controller.transportControls.skipToPrevious()
                MusicControl.Control.Response.Button.Next -> controller.transportControls.skipToNext()
                MusicControl.Control.Response.Button.Volume_up ->
                    controller.adjustVolume(AudioManager.ADJUST_RAISE, 0)
                MusicControl.Control.Response.Button.Volume_down ->
                    controller.adjustVolume(AudioManager.ADJUST_LOWER, 0)
                else -> Unit
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "音乐按钮控制失败", e)
        }
    }

    private fun handleMusicControlPacket(packet: HuaweiPacket) {
        try {
            when (packet.commandId.toInt() and 0xFF) {
                MusicControl.UploadMusicFileInfo.id -> {
                    if (packet is MusicControl.UploadMusicFileInfo.UploadMusicFileInfoRequest) {
                        val fileName = packet.songFileName ?: ""
                        val pending = musicUploadQueue.firstOrNull { it.name == fileName }
                            ?: musicUploadInFlight?.takeIf { it.name == fileName }
                        SendUploadMusicFileInfoResponse(
                            this,
                            packet.songIndex,
                            pending?.title ?: fileName.substringBeforeLast('.').ifBlank { "未命名歌曲" },
                            pending?.artist ?: "未知艺术家",
                        ).let {
                            it.setupTimeoutUntilNext(5_000)
                            it.doPerform()
                        }
                    }
                }
                MusicControl.MusicStatusResponse.id.toInt() -> {
                    SetMusicStatusRequest(
                        this,
                        MusicControl.MusicStatusResponse.id,
                        MusicControl.successValue,
                    ).let {
                        it.setupTimeoutUntilNext(5_000)
                        it.doPerform()
                    }
                    queryActiveMediaAndPush()
                }
                MusicControl.Control.id.toInt() -> {
                    if (packet is MusicControl.Control.Response) {
                        packet.button?.let { handleMusicButton(it) }
                        if (packet.volumePresent) {
                            val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            audioManager.setStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                packet.volume.toInt() and 0xFF,
                                0,
                            )
                        }
                        SetMusicStatusRequest(
                            this,
                            MusicControl.Control.id,
                            MusicControl.successValue,
                        ).let {
                            it.setupTimeoutUntilNext(5_000)
                            it.doPerform()
                        }
                    }
                }
            }
        } catch (e: Exception) {
            addLog("音乐控制处理失败：${e.message}")
            FileLogger.e(TAG, "音乐控制处理失败", e)
        }
    }

    private fun handleCameraRemoteEvent(event: CameraRemote.CameraRemoteStatus.Response.Event) {
        if (!cameraRemoteEnabled) {
            addLog("收到相机遥控事件，但开关已关闭")
            return
        }
        when (event) {
            CameraRemote.CameraRemoteStatus.Response.Event.OPEN_CAMERA -> {
                addLog("手表请求打开相机")
                if (appContext.checkSelfPermission(android.Manifest.permission.CAMERA) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                ) {
                    addLog("遥控拍照缺少相机权限，请在手表工具页重新开启")
                    setToolMessage("遥控拍照缺少相机权限")
                    return
                }
                try {
                    appContext.startActivity(
                        Intent(appContext, CameraRemoteActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    Thread({
                        try {
                            SendCameraRemoteSetupEvent(
                                this,
                                CameraRemote.CameraRemoteSetup.Request.Event.CAMERA_STARTED,
                            ).let {
                                it.setupTimeoutUntilNext(5_000)
                                it.doPerform()
                            }
                        } catch (e: Exception) {
                            FileLogger.e(TAG, "相机状态同步失败", e)
                        }
                    }, "VitaloopCameraStarted").apply { isDaemon = true; start() }
                } catch (e: Exception) {
                    FileLogger.e(TAG, "打开相机失败", e)
                    addLog("打开相机失败：${e.message}")
                }
            }
            CameraRemote.CameraRemoteStatus.Response.Event.TAKE_PICTURE -> {
                appContext.sendBroadcast(
                    Intent(CameraRemoteActivity.ACTION_TAKE_PICTURE)
                        .setPackage(appContext.packageName)
                )
            }
            CameraRemote.CameraRemoteStatus.Response.Event.CLOSE_CAMERA -> {
                appContext.sendBroadcast(
                    Intent(CameraRemoteActivity.ACTION_CLOSE)
                        .setPackage(appContext.packageName)
                )
            }
        }
    }

    private fun handleWatchfaceConfirm(packet: Watchface.WatchfaceConfirm.Response) {
        val fileName = packet.fileName ?: return
        val reportType = packet.reportType.toInt()
        val now = System.currentTimeMillis()
        recentWatchfaceConfirms.entries.removeAll { now - it.value > 30_000L }
        val key = "$fileName:$reportType"
        if (recentWatchfaceConfirms.putIfAbsent(key, now) != null) return
        Thread({
            try {
                SendWatchfaceConfirm(this, fileName).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                if (reportType == 0x02) {
                    SendWatchfaceOperation(
                        this,
                        fileName,
                        Watchface.WatchfaceOperation.operationActive,
                    ).let {
                        it.setupTimeoutUntilNext(5_000)
                        it.doPerform()
                    }
                    currentWatchface = fileName
                    addLog("手表请求应用表盘：$fileName")
                } else {
                    addLog("已确认手表表盘：$fileName")
                }
                emitTools()
            } catch (e: Exception) {
                FileLogger.e(TAG, "处理手表表盘确认失败", e)
            }
        }, "VitaloopWatchfaceConfirmIncoming").apply { isDaemon = true; start() }
    }
    override fun getSerial(): ByteArray = ByteArray(8)
    override fun getNotificationId(): Short = 0
    override fun saveAlarmsFromWatch(alarms: Array<IntArray>) {
        val address = gbDevice.address
        if (address.isBlank()) return
        // 有本地未同步的修改时以手机为准，避免刚保存的设置被手表旧值覆盖。
        if (GBApplication.getDeviceSpecificSharedPrefs(address)
                .getBoolean(KEY_ALARMS_PENDING, false)
        ) {
            addLog("本机有未下发的闹钟修改，跳过手表回写")
            return
        }
        val supportsSmart = coordinator.supportsSmartAlarm(gbDevice)
        val existing = getSavedAlarms(address).associateBy { it.index }.toMutableMap()
        for (row in alarms) {
            if (row.size < 5) continue
            // 不支持智能闹钟的设备会把普通闹钟从 0 开始编号，本地统一成 1..5。
            val index = if (!supportsSmart && row[0] in 0..4) row[0] + 1 else row[0]
            if (index !in 0..5) continue
            val enabled = row[1] != 0
            val repeat = row[2] and 0x7f
            val hour = row[3].coerceIn(0, 23)
            val minute = row[4].coerceIn(0, 59)
            if (index == 0) {
                if (row.size < 6) {
                    existing.remove(0)
                    continue
                }
                existing[0] = WatchAlarm(
                    index = 0,
                    isEnabled = enabled,
                    hourOfDay = hour,
                    minuteOfHour = minute,
                    repeatMask = repeat,
                    label = "智能唤醒",
                    smartWakeupIntervalMinutes = row[5].takeIf { it in 0..60 } ?: 5,
                )
                continue
            }
            // 空槽位是手表返回的 00:00 禁用占位，不要变成幽灵闹钟。
            if (!enabled && repeat == 0 && hour == 0 && minute == 0) {
                existing.remove(index)
            } else {
                existing[index] = WatchAlarm(
                    index = index,
                    isEnabled = enabled,
                    hourOfDay = hour,
                    minuteOfHour = minute,
                    repeatMask = repeat,
                    label = existing[index]?.label ?: "闹钟",
                )
            }
        }
        saveAlarms(address, existing.values.toList())
        addLog("已从手表读回 ${alarms.size} 条闹钟，本机共 ${existing.size} 条")
        FileLogger.i(TAG, "Saved ${alarms.size} alarms from watch, total=${existing.size}")
    }

    /** 手机侧稳定身份。旧版在首次配对时随机生成后一直复用，不能用蓝牙 MAC 代替。 */
    private fun createRandomMacAddress() {
        val prefs = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
        var mac = prefs.getString("huawei_address", null)
        if (mac.isNullOrEmpty()) {
            val random = java.util.Random()
            mac = (0 until 6).joinToString(":") {
                String.format(java.util.Locale.US, "%02X", random.nextInt(256))
            }
            prefs.edit().putString("huawei_address", mac).apply()
        }
        macAddress = mac
    }

    private fun createAndroidID() {
        val prefs = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
        var id = prefs.getString("fake_android_id", null)
        if (id.isNullOrEmpty()) {
            id = StringUtils.bytesToHex(HuaweiCrypto.generateNonce())
            prefs.edit().putString("fake_android_id", id).apply()
        }
        androidId = id
    }

    private fun createSecretKey() {
        val prefs = GBApplication.getDeviceSpecificSharedPrefs(gbDevice.address)
        val authKey = prefs.getString("authkey", null)
        if (!authKey.isNullOrEmpty()) {
            paramsProvider.setSecretKey(StringUtils.hexToBytes(authKey))
        }
    }
}
