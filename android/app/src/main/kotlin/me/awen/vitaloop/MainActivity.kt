package me.awen.vitaloop

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.speech.tts.TextToSpeech
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.awen.running.bluetooth.VitaloopBleManager
import com.awen.running.huawei.VitaloopWatchManager
import com.awen.running.huawei.VitaloopNotificationListenerService
import com.awen.running.huawei.WatchfacePackage
import com.awen.running.huawei.WearStateBridge
import com.awen.running.location.GpsLiveConfig
import com.awen.running.location.GpsLiveService
import com.awen.running.location.VitaloopGpsManager
import com.awen.running.service.DjiActionManager
import com.awen.running.service.LiveStreamConfig
import com.awen.running.service.VoicePushManager
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    private var watchManager: VitaloopWatchManager? = null
    private var eventSink: EventChannel.EventSink? = null
    private var bleManager: VitaloopBleManager? = null
    private var bleSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var gpsManager: VitaloopGpsManager? = null
    private var gpsSink: EventChannel.EventSink? = null
    private var pendingGpsPermissionResult: MethodChannel.Result? = null
    private var pendingGuidePermissionResult: MethodChannel.Result? = null
    private var pendingLegacyResult: MethodChannel.Result? = null
    private var pendingCalendarResult: MethodChannel.Result? = null
    private var pendingToolPickResult: MethodChannel.Result? = null
    private var pendingToolPickKind = ""
    private var pendingContactsResult: MethodChannel.Result? = null
    private var pendingCameraResult: MethodChannel.Result? = null
    private var pendingVoicePermissionResult: MethodChannel.Result? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingTtsText: String? = null
    @Volatile private var updateDownloading = false
    private val updateClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.MINUTES)
        .build()

    @SuppressLint("MissingPermission")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val language = this@MainActivity.tts?.setLanguage(NativeLocale.current(this))
                ttsReady = language != TextToSpeech.LANG_MISSING_DATA &&
                    language != TextToSpeech.LANG_NOT_SUPPORTED
                if (ttsReady) {
                    pendingTtsText?.let { text ->
                        pendingTtsText = null
                        this@MainActivity.tts?.speak(
                            text,
                            TextToSpeech.QUEUE_FLUSH,
                            null,
                            "vitaloop_nav",
                        )
                    }
                }
            } else {
                Log.e("VitaloopTts", "init failed: $status")
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/tts").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(ttsReady)
                "speak" -> {
                    val text = call.argument<String>("text")?.trim().orEmpty()
                    if (text.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val flush = call.argument<Boolean>("flush") ?: true
                    if (!ttsReady) {
                        pendingTtsText = text
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val mode = if (flush) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
                    result.success(tts?.speak(text, mode, null, "vitaloop_nav") == TextToSpeech.SUCCESS)
                }
                "stop" -> {
                    pendingTtsText = null
                    tts?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/locale").setMethodCallHandler { call, result ->
            if (call.method != "set_app_locale") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val code = call.argument<String>("code") ?: "system"
            NativeLocale.set(this, code)
            val locale = NativeLocale.current(this)
            tts?.setLanguage(locale)
            result.success(null)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/export").setMethodCallHandler { call, result ->
            if (call.method != "share_file" &&
                call.method != "share_bytes" &&
                call.method != "save_image"
            ) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name") ?: "export.txt"
            val mime = call.argument<String>("mime") ?: "application/octet-stream"
            try {
                val safeName = name
                    .replace(Regex("[^A-Za-z0-9._-]"), "_")
                    .take(100)
                    .ifBlank { "export.txt" }
                val dir = File(cacheDir, "exports").apply { mkdirs() }
                val file = File(dir, safeName)
                if (call.method == "share_bytes") {
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    file.writeBytes(bytes)
                } else {
                    val content = call.argument<String>("content") ?: ""
                    file.writeText(content, Charsets.UTF_8)
                }
                if (call.method == "save_image") {
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                    result.success(saveImageToGallery(safeName, mime, bytes))
                    return@setMethodCallHandler
                }
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri(null, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                startActivity(Intent.createChooser(intent, "分享文件"))
                result.success(true)
            } catch (e: Exception) {
                Log.e("VitaloopExport", "share failed", e)
                result.success(false)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(
                    mapOf(
                        "versionCode" to currentVersionCode(),
                        "versionName" to currentVersionName(),
                    )
                )
                "can_install" -> result.success(canInstallPackages())
                "open_install_permission" -> {
                    if (Build.VERSION.SDK_INT >= 26) {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                )
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "download_and_install" -> {
                    val url = call.argument<String>("url") ?: ""
                    if (url.isBlank()) {
                        result.success(mapOf("ok" to false, "message" to "更新地址为空"))
                    } else if (updateDownloading) {
                        result.success(mapOf("ok" to false, "message" to "更新包正在下载"))
                    } else {
                        updateDownloading = true
                        downloadAndInstall(url, result)
                    }
                }
                else -> result.notImplemented()
            }
        }

        val manager = VitaloopWatchManager.getInstance(applicationContext)
        watchManager = manager

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/watch_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        manager.onState = { state ->
            runOnUiThread { eventSink?.success(wrap("state", JSONObject().put("v", state))) }
        }
        manager.onEvent = { obj ->
            runOnUiThread { eventSink?.success(wrap("data", obj)) }
        }
        for (pending in manager.drainPendingEvents()) {
            eventSink?.success(wrap("data", pending))
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/watch").setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    val mac = call.argument<String>("mac") ?: ""
                    val name = call.argument<String>("name") ?: "HUAWEI WATCH"
                    pendingConnect = ConnectRequest(
                        mac,
                        name,
                        call.argument<String>("auth_key") ?: "",
                        call.argument<String>("fake_android_id") ?: "",
                        call.argument<String>("account") ?: "",
                        call.argument<String>("huawei_address") ?: "",
                    )
                    if (android.os.Build.VERSION.SDK_INT >= 31 &&
                        checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) != android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(android.Manifest.permission.BLUETOOTH_CONNECT), 4001)
                    } else {
                        startConnect()
                    }
                    result.success(null)
                }
                "disconnect" -> {
                    manager.disconnect()
                    result.success(null)
                }
                "state" -> result.success(manager.state)
                "sync" -> {
                    manager.syncOnce(manual = true)
                    result.success(null)
                }
                "resync" -> {
                    manager.resyncRecent(call.argument<Int>("days") ?: 7)
                    result.success(null)
                }
                "auto_sync" -> result.success(manager.isAutoSyncEnabled())
                "set_auto_sync" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    manager.setAutoSyncEnabled(enabled)
                    if (enabled) WatchSyncService.start(applicationContext) else WatchSyncService.stop(applicationContext)
                    result.success(enabled)
                }
                "weather_sync" -> result.success(manager.isWeatherSyncEnabled())
                "set_weather_sync" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    manager.setWeatherSyncEnabled(enabled)
                    result.success(enabled)
                }
                "set_ephemeris_url" -> {
                    manager.setEphemerisUrl(call.argument<String>("url") ?: "")
                    result.success(null)
                }
                "ephemeris_status" -> result.success(manager.ephemerisStatus().toString())
                "ensure_ephemeris" -> {
                    manager.ensureEphemerisDownloaded()
                    result.success(null)
                }
                "download_ephemeris" -> {
                    manager.downloadEphemerisNow { msg -> runOnUiThread { result.success(msg) } }
                }
                "bonded_devices" -> {
                    val devices = org.json.JSONArray()
                    if (android.os.Build.VERSION.SDK_INT < 31 ||
                        hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT)
                    ) {
                        runCatching {
                            android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                                ?.bondedDevices
                                ?.filter { it.name?.contains("HUAWEI", ignoreCase = true) == true }
                                ?.sortedBy { it.name }
                                ?.forEach { device ->
                                    devices.put(
                                        JSONObject()
                                            .put("name", device.name ?: "HUAWEI WATCH")
                                            .put("address", device.address),
                                    )
                                }
                        }
                    }
                    result.success(devices.toString())
                }
                "notification_access" -> {
                    result.success(VitaloopNotificationListenerService.isEnabled(this))
                }
                "notification_forward" -> {
                    result.success(
                        getSharedPreferences("vitaloop_watch", MODE_PRIVATE)
                            .getBoolean("notification_forward", true),
                    )
                }
                "open_notification_access" -> {
                    startActivity(
                        android.content.Intent(
                            android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS,
                        ),
                    )
                    result.success(null)
                }
                "set_notification_forward" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    getSharedPreferences("vitaloop_watch", MODE_PRIVATE)
                        .edit().putBoolean("notification_forward", enabled).apply()
                    result.success(enabled)
                }
                "notification_filter" -> {
                    val prefs = getSharedPreferences("vitaloop_watch", MODE_PRIVATE)
                    val packages = prefs.getStringSet("notification_filter_packages", emptySet())
                        ?: emptySet()
                    result.success(
                        JSONObject()
                            .put("mode", prefs.getString("notification_filter_mode", "all"))
                            .put("packages", org.json.JSONArray(packages.sorted())),
                    )
                }
                "set_notification_filter" -> {
                    val mode = call.argument<String>("mode") ?: "all"
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    getSharedPreferences("vitaloop_watch", MODE_PRIVATE)
                        .edit()
                        .putString("notification_filter_mode", mode)
                        .putStringSet("notification_filter_packages", packages.toSet())
                        .apply()
                    result.success(true)
                }
                "notification_apps" -> {
                    val apps = org.json.JSONArray()
                    runCatching {
                        val pm = packageManager
                        val own = packageName
                        pm.getInstalledApplications(PackageManager.GET_META_DATA)
                            .asSequence()
                            .filter { it.packageName != own }
                            .map {
                                JSONObject()
                                    .put("name", pm.getApplicationLabel(it).toString())
                                    .put("package", it.packageName)
                            }
                            .sortedBy { it.optString("name").lowercase(Locale.getDefault()) }
                            .forEach { apps.put(it) }
                    }
                    result.success(apps.toString())
                }
                "workout_realtime" -> result.success(manager.isWorkoutRealtimeEnabled())
                "set_workout_realtime" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    result.success(manager.setWorkoutRealtimeEnabled(enabled))
                }
                "workout_realtime_status" ->
                    result.success(manager.workoutRealtimeStatusJson())
                "workout_live_snapshot" ->
                    result.success(manager.workoutLiveSnapshotJson())
                "alarms_list" -> result.success(manager.alarmsJson())
                "alarms_save" -> result.success(
                    manager.saveAlarmsJson(call.argument<String>("alarms") ?: "[]"),
                )
                "alarms_sync" -> {
                    manager.syncAlarmsNow()
                    result.success(null)
                }
                "holiday_skip_get" -> result.success(manager.isHolidaySkipEnabled())
                "holiday_skip_set" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    result.success(manager.setHolidaySkipEnabled(enabled))
                }
                "today_workday" -> result.success(manager.isTodayWorkday())
                "calendar_status" -> result.success(manager.calendarStatusJson())
                "calendar_set_enabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled &&
                        android.os.Build.VERSION.SDK_INT >= 23 &&
                        checkSelfPermission(android.Manifest.permission.READ_CALENDAR) !=
                        android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingCalendarResult = result
                        requestPermissions(
                            arrayOf(android.Manifest.permission.READ_CALENDAR),
                            4006,
                        )
                    } else {
                        result.success(manager.setCalendarSyncEnabled(enabled))
                    }
                }
                "calendar_sync_now" -> result.success(manager.syncCalendarNow())
                "training_plan_push" -> {
                    val plan = call.argument<String>("plan") ?: ""
                    manager.pushTrainingPlanJson(plan) { json ->
                        runOnUiThread { result.success(json) }
                    }
                }
                "training_plan_finish" -> {
                    val planId = call.argument<String>("plan_id") ?: ""
                    manager.finishTrainingPlan(planId) { json ->
                        runOnUiThread { result.success(json) }
                    }
                }
                "route_push" -> {
                    val route = call.argument<String>("route") ?: ""
                    manager.pushRouteJson(route) { json ->
                        runOnUiThread { result.success(json) }
                    }
                }
                "offline_map_probe" -> {
                    manager.probeOfflineMap { json ->
                        runOnUiThread { result.success(json) }
                    }
                }
                "pick_offline_map" -> pickWatchToolFile("map", result)
                "offline_map_push" -> {
                    val uri = call.argument<String>("uri") ?: ""
                    if (uri.isEmpty()) {
                        result.error("bad_args", "没有选择地图文件", null)
                    } else {
                        manager.pushOfflineMapUri(uri) { json ->
                            runOnUiThread { result.success(json) }
                        }
                    }
                }
                "watch_tools_status" -> result.success(manager.watchToolsStatusJson())
                "wear_query" -> {
                    manager.refreshWearStatus("手动")
                    result.success(null)
                }
                "wrist_unlock_set" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val ok = WearStateBridge.setEnabled(this, enabled)
                    if (enabled) manager.refreshWearStatus("开关")
                    result.success(ok)
                }
                "camera_remote_enabled" -> result.success(manager.isCameraRemoteEnabled())
                "camera_remote_set" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled && !hasPermission(android.Manifest.permission.CAMERA)) {
                        pendingCameraResult = result
                        requestPermissions(arrayOf(android.Manifest.permission.CAMERA), 4007)
                    } else {
                        manager.setCameraRemoteEnabled(enabled)
                        result.success(enabled)
                    }
                }
                "find_phone_set" -> {
                    manager.setFindPhoneEnabled(call.argument<Boolean>("enabled") ?: true)
                    result.success(null)
                }
                "find_phone_test" -> {
                    manager.testFindPhone()
                    result.success(null)
                }
                "find_phone_stop" -> {
                    manager.stopFindPhone()
                    result.success(null)
                }
                "dnd_get" -> result.success(manager.isDndEnabled())
                "dnd_set" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(manager.setDndEnabled(enabled))
                }
                "watch_settings" -> result.success(manager.watchSettingsJson())
                "watch_setting_set" -> {
                    val key = call.argument<String>("key") ?: ""
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(manager.setWatchSetting(key, enabled))
                }
                "dnd_plan" -> result.success(manager.dndPlanJson())
                "dnd_plan_set" -> {
                    val mode = call.argument<String>("mode") ?: "off"
                    val start = call.argument<String>("start") ?: "23:00"
                    val end = call.argument<String>("end") ?: "07:00"
                    val repeatMask = call.argument<Int>("repeatMask") ?: 0x7f
                    val liftWrist = call.argument<Boolean>("liftWrist") ?: false
                    result.success(
                        manager.setDndPlan(mode, start, end, repeatMask, liftWrist)
                    )
                }
                "sync_all_settings" -> {
                    manager.syncAllSettings { message ->
                        runOnUiThread { result.success(message) }
                    }
                }
                "factory_reset" -> {
                    if (!manager.isConnected) {
                        result.success(false)
                    } else {
                        manager.factoryReset()
                        result.success(true)
                    }
                }
                "sync_contacts" -> {
                    if (!hasPermission(android.Manifest.permission.READ_CONTACTS)) {
                        pendingContactsResult = result
                        requestPermissions(arrayOf(android.Manifest.permission.READ_CONTACTS), 4008)
                    } else {
                        manager.syncContactsToWatch()
                        result.success(true)
                    }
                }
                "apps_list" -> {
                    manager.requestAppList()
                    result.success(null)
                }
                "app_delete" -> {
                    manager.deleteWatchApp(call.argument<String>("package") ?: "")
                    result.success(null)
                }
                "pick_watch_app" -> pickWatchToolFile("app", result)
                "app_install" -> {
                    manager.installWatchApp(
                        call.argument<String>("path") ?: "",
                        call.argument<String>("package") ?: "",
                    )
                    result.success(null)
                }
                "watchfaces_list" -> {
                    manager.requestWatchfaces()
                    result.success(null)
                }
                "watchface_activate" -> {
                    manager.activateWatchface(
                        call.argument<String>("file") ?: "",
                        call.argument<String>("version") ?: "",
                    )
                    result.success(null)
                }
                "watchface_delete" -> {
                    manager.deleteWatchface(
                        call.argument<String>("file") ?: "",
                        call.argument<String>("version") ?: "",
                    )
                    result.success(null)
                }
                "pick_watchface" -> pickWatchToolFile("watchface", result)
                "watchface_install" -> {
                    manager.installWatchface(
                        call.argument<String>("path") ?: "",
                        call.argument<String>("name") ?: "",
                        call.argument<String>("version") ?: "",
                        call.argument<String>("mode") ?: "BIN",
                    )
                    result.success(null)
                }
                "music_library" -> {
                    manager.requestMusicLibrary()
                    result.success(null)
                }
                "pick_music" -> pickWatchToolFile("music", result)
                "music_upload" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    manager.uploadMusic(paths)
                    result.success(null)
                }
                "music_cancel" -> {
                    manager.cancelMusicUpload()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/legacy").setMethodCallHandler { call, result ->
            when (call.method) {
                "pick_files" -> pickLegacyFiles(result)
                else -> result.notImplemented()
            }
        }

        val ble = VitaloopBleManager.getInstance(applicationContext)
        bleManager = ble
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/ble_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bleSink = events
                }

                override fun onCancel(arguments: Any?) {
                    bleSink = null
                }
            })
        ble.onEvent = { obj ->
            runOnUiThread { bleSink?.success(obj.toString()) }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/ble").setMethodCallHandler { call, result ->
            when (call.method) {
                "request_permissions" -> {
                    if (ble.hasPermissions()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        val permissions = if (android.os.Build.VERSION.SDK_INT >= 31) {
                            arrayOf(
                                android.Manifest.permission.BLUETOOTH_SCAN,
                                android.Manifest.permission.BLUETOOTH_CONNECT,
                            )
                        } else {
                            arrayOf(
                                android.Manifest.permission.BLUETOOTH,
                                android.Manifest.permission.BLUETOOTH_ADMIN,
                                android.Manifest.permission.ACCESS_FINE_LOCATION,
                            )
                        }
                        requestPermissions(permissions, 4002)
                    }
                }
                "has_permissions" -> result.success(ble.hasPermissions())
                "scan_start" -> result.success(ble.startScan())
                "scan_stop" -> {
                    ble.stopScan()
                    result.success(null)
                }
                "connect" -> result.success(
                    ble.connect(
                        call.argument<String>("address") ?: "",
                        call.argument<String>("name") ?: "心率带",
                    )
                )
                "disconnect" -> {
                    ble.disconnect(call.argument<String>("address") ?: "")
                    result.success(null)
                }
                "forget" -> {
                    ble.forget(call.argument<String>("address") ?: "")
                    result.success(null)
                }
                "connect_last" -> result.success(ble.connectLast())
                "configure_scale" -> {
                    ble.configureProfile(
                        call.argument<Double>("heightCm") ?: 170.0,
                        call.argument<Int>("age") ?: 30,
                        call.argument<String>("sex") ?: "male",
                    )
                    result.success(null)
                }
                "devices" -> result.success(ble.devices())
                "history" -> {
                    val obj = JSONObject()
                    ble.history().forEach { (k, v) -> obj.put(k, v) }
                    result.success(obj.toString())
                }
                else -> result.notImplemented()
            }
        }

        val gps = VitaloopGpsManager.getInstance(applicationContext)
        gpsManager = gps
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/gps_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    gpsSink = events
                }

                override fun onCancel(arguments: Any?) {
                    gpsSink = null
                }
            })
        gps.onPoint = { obj -> runOnUiThread { gpsSink?.success(obj.toString()) } }
        gps.onState = { state ->
            runOnUiThread { gpsSink?.success(JSONObject().put("type", "state").put("state", state).toString()) }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/gps").setMethodCallHandler { call, result ->
            when (call.method) {
                "request_permissions" -> {
                    if (gps.hasPermissions()) {
                        result.success(true)
                    } else {
                        pendingGpsPermissionResult = result
                        requestPermissions(
                            arrayOf(
                                android.Manifest.permission.ACCESS_FINE_LOCATION,
                                android.Manifest.permission.ACCESS_COARSE_LOCATION,
                            ),
                            4003,
                        )
                    }
                }
                "has_permissions" -> result.success(gps.hasPermissions())
                "start" -> result.success(gps.start())
                "stop" -> {
                    gps.stop()
                    result.success(null)
                }
                "last" -> result.success(gps.lastKnown())
                "keep_screen_on" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (enabled) {
                            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/gps_live").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(GpsLiveService.statusJson(this))
                "config" -> {
                    val config = JSONObject()
                        .put("serverUrl", GpsLiveConfig.serverUrl(this))
                        .put("hasToken", GpsLiveConfig.accessToken(this).isNotBlank())
                        .put("hasVoiceUrl", LiveStreamConfig.hasVoiceUrl(this))
                        .put("hasVideoUrl", LiveStreamConfig.hasVideoUrl(this))
                        .put("hasDjiWifi", LiveStreamConfig.hasDjiWifi(this))
                        .put("autoShare", GpsLiveConfig.isAutoShareOnWorkout(this))
                    result.success(config.toString())
                }
                "set_config" -> {
                    call.argument<String>("serverUrl")?.let { GpsLiveConfig.setServerUrl(this, it) }
                    if (call.hasArgument("token")) {
                        GpsLiveConfig.setAccessToken(this, call.argument<String>("token") ?: "")
                    }
                    if (call.hasArgument("voiceUrl")) {
                        LiveStreamConfig.setVoiceUrl(this, call.argument<String>("voiceUrl") ?: "")
                    }
                    if (call.hasArgument("videoUrl")) {
                        LiveStreamConfig.setVideoUrl(this, call.argument<String>("videoUrl") ?: "")
                    }
                    if (call.hasArgument("djiSsid")) {
                        LiveStreamConfig.setDjiWifi(
                            this,
                            call.argument<String>("djiSsid") ?: "",
                            call.argument<String>("djiWifiPassword") ?: "",
                        )
                    }
                    call.argument<Boolean>("autoShare")?.let {
                        GpsLiveConfig.setAutoShareOnWorkout(this, it)
                    }
                    result.success(true)
                }
                "has_permissions" -> result.success(gps.hasPermissions())
                "request_permissions" -> {
                    if (gps.hasPermissions()) {
                        result.success(true)
                    } else {
                        pendingGpsPermissionResult = result
                        requestPermissions(
                            arrayOf(
                                android.Manifest.permission.ACCESS_FINE_LOCATION,
                                android.Manifest.permission.ACCESS_COARSE_LOCATION,
                            ),
                            4003,
                        )
                    }
                }
                "start" -> {
                    if (!GpsLiveConfig.isConfigured(this)) {
                        result.success(false)
                    } else if (!gps.hasPermissions()) {
                        result.success(false)
                    } else {
                        GpsLiveService.start(this)
                        result.success(true)
                    }
                }
                "pause" -> {
                    GpsLiveService.pause(this)
                    result.success(null)
                }
                "resume" -> {
                    GpsLiveService.resume(this)
                    result.success(null)
                }
                "stop" -> {
                    GpsLiveService.stop(this)
                    result.success(null)
                }
                "has_microphone" -> result.success(
                    hasPermission(android.Manifest.permission.RECORD_AUDIO),
                )
                "request_microphone" -> {
                    if (hasPermission(android.Manifest.permission.RECORD_AUDIO)) {
                        result.success(true)
                    } else {
                        pendingVoicePermissionResult = result
                        requestPermissions(
                            arrayOf(android.Manifest.permission.RECORD_AUDIO),
                            4009,
                        )
                    }
                }
                "start_voice" -> {
                    if (!hasPermission(android.Manifest.permission.RECORD_AUDIO)) {
                        result.success(false)
                    } else if (!LiveStreamConfig.hasVoiceUrl(this)) {
                        result.success(false)
                    } else {
                        GpsLiveService.enableMicrophone(this)
                        result.success(
                            VoicePushManager.start(
                                this,
                                LiveStreamConfig.voiceUrl(this),
                            ),
                        )
                    }
                }
                "stop_voice" -> {
                    VoicePushManager.stop()
                    GpsLiveService.disableMicrophone(this)
                    result.success(null)
                }
                "dji_status" -> result.success(djiStatusJson())
                "dji_scan_start" -> {
                    DjiActionManager.startScan(this)
                    result.success(DjiActionManager.errorMessage.value.isNullOrEmpty())
                }
                "dji_scan_stop" -> {
                    DjiActionManager.stopScan()
                    result.success(null)
                }
                "dji_connect" -> {
                    val address = call.argument<String>("address") ?: ""
                    val name = call.argument<String>("name") ?: "DJI 相机"
                    val device = runCatching {
                        android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                            ?.getRemoteDevice(address)
                    }.getOrNull()
                    if (device == null) {
                        result.success(false)
                    } else {
                        DjiActionManager.connect(this, device, name)
                        result.success(true)
                    }
                }
                "dji_disconnect" -> {
                    DjiActionManager.disconnect()
                    result.success(null)
                }
                "dji_start_video" -> {
                    if (!LiveStreamConfig.hasVideoUrl(this) ||
                        !LiveStreamConfig.hasDjiWifi(this)
                    ) {
                        result.success(false)
                    } else {
                        DjiActionManager.startLiveStream(
                            this,
                            LiveStreamConfig.djiSsid(this),
                            LiveStreamConfig.djiPassword(this),
                            LiveStreamConfig.videoUrl(this),
                        )
                        result.success(true)
                    }
                }
                "dji_stop_video" -> {
                    DjiActionManager.stopLiveStream()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vitaloop/permissions").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(permissionSnapshot())
                "request" -> {
                    val wanted = mutableListOf<String>()
                    if (!hasPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)) {
                        wanted.add(android.Manifest.permission.ACCESS_FINE_LOCATION)
                        wanted.add(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= 31) {
                        if (!hasPermission(android.Manifest.permission.BLUETOOTH_SCAN)) {
                            wanted.add(android.Manifest.permission.BLUETOOTH_SCAN)
                        }
                        if (!hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT)) {
                            wanted.add(android.Manifest.permission.BLUETOOTH_CONNECT)
                        }
                    } else {
                        if (!hasPermission(android.Manifest.permission.BLUETOOTH)) {
                            wanted.add(android.Manifest.permission.BLUETOOTH)
                        }
                    }
                    if (android.os.Build.VERSION.SDK_INT >= 33 &&
                        !hasPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                    ) {
                        wanted.add(android.Manifest.permission.POST_NOTIFICATIONS)
                    }
                    if (!hasPermission(android.Manifest.permission.READ_PHONE_STATE)) {
                        wanted.add(android.Manifest.permission.READ_PHONE_STATE)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= 26 &&
                        !hasPermission(android.Manifest.permission.ANSWER_PHONE_CALLS)
                    ) {
                        wanted.add(android.Manifest.permission.ANSWER_PHONE_CALLS)
                    }
                    if (wanted.isEmpty()) {
                        result.success(permissionSnapshot())
                    } else {
                        pendingGuidePermissionResult = result
                        requestPermissions(wanted.distinct().toTypedArray(), 4004)
                    }
                }
                "request_background_location" -> {
                    if (android.os.Build.VERSION.SDK_INT >= 29 &&
                        !hasPermission(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                    ) {
                        if (android.os.Build.VERSION.SDK_INT >= 30) {
                            // Android 11+ 不再弹「始终允许」，只能由用户到应用设置里改。
                            startActivity(
                                android.content.Intent(
                                    android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.fromParts("package", packageName, null),
                                ),
                            )
                            result.success(permissionSnapshot())
                        } else {
                            pendingGuidePermissionResult = result
                            requestPermissions(
                                arrayOf(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                                4005,
                            )
                        }
                    } else {
                        result.success(permissionSnapshot())
                    }
                }
                "request_battery_optimization" -> {
                    try {
                        startActivity(
                            android.content.Intent(
                                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                android.net.Uri.parse("package:$packageName"),
                            ),
                        )
                    } catch (e: Exception) {
                        Log.e("VitaloopPermissions", "request battery optimization failed", e)
                    }
                    result.success(permissionSnapshot())
                }
                "open_settings" -> {
                    startActivity(
                        android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.fromParts("package", packageName, null),
                        ),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(permission: String): Boolean =
        checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun djiStatusJson(): String {
        val cameras = org.json.JSONArray()
        DjiActionManager.cameras.value.forEach { camera ->
            cameras.put(
                JSONObject()
                    .put("address", camera.device.address)
                    .put("name", camera.device.name ?: camera.modelName)
                    .put("model", camera.modelName),
            )
        }
        val connected = DjiActionManager.connectedCamera.value
        return JSONObject()
            .put("state", DjiActionManager.state.value.name)
            .put("cameras", cameras)
            .put("connectedAddress", connected?.device?.address ?: "")
            .put(
                "connectedName",
                connected?.device?.name ?: connected?.modelName ?: "",
            )
            .put("battery", DjiActionManager.battery.value)
            .put("streaming", DjiActionManager.isStreaming)
            .put("error", DjiActionManager.errorMessage.value ?: "")
            .toString()
    }

    private fun permissionSnapshot(): String {
        val obj = JSONObject()
        obj.put("location", hasPermission(android.Manifest.permission.ACCESS_FINE_LOCATION))
        obj.put(
            "background_location",
            android.os.Build.VERSION.SDK_INT < 29 ||
                hasPermission(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION),
        )
        obj.put(
            "bluetooth",
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                hasPermission(android.Manifest.permission.BLUETOOTH_SCAN) &&
                    hasPermission(android.Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                hasPermission(android.Manifest.permission.BLUETOOTH)
            },
        )
        obj.put(
            "notifications",
            android.os.Build.VERSION.SDK_INT < 33 ||
                hasPermission(android.Manifest.permission.POST_NOTIFICATIONS),
        )
        obj.put(
            "phone",
            hasPermission(android.Manifest.permission.READ_PHONE_STATE),
        )
        obj.put(
            "answer_calls",
            android.os.Build.VERSION.SDK_INT < 26 ||
                hasPermission(android.Manifest.permission.ANSWER_PHONE_CALLS),
        )
        obj.put(
            "battery_optimization",
            runCatching {
                (getSystemService(android.content.Context.POWER_SERVICE)
                    as android.os.PowerManager)
                    .isIgnoringBatteryOptimizations(packageName)
            }.getOrDefault(false),
        )
        return obj.toString()
    }

    private data class ConnectRequest(
        val mac: String,
        val name: String,
        val authKey: String,
        val fakeAndroidId: String,
        val account: String,
        val huaweiAddress: String,
    )

    private var pendingConnect: ConnectRequest? = null

    private fun startConnect() {
        val target = pendingConnect ?: return
        pendingConnect = null
        watchManager?.connect(
            target.mac,
            target.name,
            target.authKey,
            target.fakeAndroidId,
            target.account,
            target.huaweiAddress,
        )
        // 用户点过一次「连接」就应当一直连着，退出 App 也不例外
        WatchSyncService.start(applicationContext)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4001) {
            if (grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                startConnect()
            } else {
                runOnUiThread { eventSink?.success(org.json.JSONObject().put("kind", "state").put("payload", org.json.JSONObject().put("v", "failed:未授予蓝牙连接权限"))) }
            }
        }
        if (requestCode == 4002) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
        if (requestCode == 4003) {
            val granted = grantResults.isNotEmpty() &&
                grantResults.any { it == android.content.pm.PackageManager.PERMISSION_GRANTED }
            pendingGpsPermissionResult?.success(granted)
            pendingGpsPermissionResult = null
        }
        if (requestCode == 4004 || requestCode == 4005) {
            pendingGuidePermissionResult?.success(permissionSnapshot())
            pendingGuidePermissionResult = null
        }
        if (requestCode == 4006) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (granted) {
                pendingCalendarResult?.success(
                    watchManager?.setCalendarSyncEnabled(true) ?: false,
                )
            } else {
                pendingCalendarResult?.success(false)
            }
            pendingCalendarResult = null
        }
        if (requestCode == 4007) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            watchManager?.setCameraRemoteEnabled(granted)
            pendingCameraResult?.success(granted)
            pendingCameraResult = null
        }
        if (requestCode == 4008) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (granted) {
                watchManager?.syncContactsToWatch()
            }
            pendingContactsResult?.success(granted)
            pendingContactsResult = null
        }
        if (requestCode == 4009) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            pendingVoicePermissionResult?.success(granted)
            pendingVoicePermissionResult = null
        }
    }

    private fun pickLegacyFiles(result: MethodChannel.Result) {
        if (pendingLegacyResult != null) {
            result.error("busy", "文件选择器已经打开", null)
            return
        }
        pendingLegacyResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/octet-stream",
                    "application/x-sqlite3",
                    "application/vnd.sqlite3",
                    "text/xml",
                    "application/xml",
                    "text/plain",
                ),
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, 4100)
    }

    private fun pickWatchToolFile(kind: String, result: MethodChannel.Result) {
        if (pendingToolPickResult != null) {
            result.error("busy", "文件选择器已经打开", null)
            return
        }
        pendingToolPickResult = result
        pendingToolPickKind = kind
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            when (kind) {
                "app" -> {
                    type = "application/vnd.android.package-archive"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "application/vnd.android.package-archive",
                            "application/octet-stream",
                        ),
                    )
                }
                "music" -> {
                    type = "audio/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                "map" -> {
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "application/zip",
                            "application/octet-stream",
                            "application/x-zip-compressed",
                            "*/*",
                        ),
                    )
                }
                else -> {
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "application/zip",
                            "application/octet-stream",
                            "application/x-zip-compressed",
                        ),
                    )
                }
            }
        }
        val code = when (kind) {
            "app" -> 4102
            "music" -> 4103
            "map" -> 4104
            else -> 4101
        }
        startActivityForResult(intent, code)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 4101 || requestCode == 4102 || requestCode == 4103 || requestCode == 4104) {
            handleWatchToolPick(resultCode, data)
            return
        }
        if (requestCode != 4100) return
        val result = pendingLegacyResult ?: return
        pendingLegacyResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<String>())
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        if (uris.isEmpty()) {
            result.success(emptyList<String>())
            return
        }
        Thread {
            val dir = File(filesDir, "legacy").apply { mkdirs() }
            val copied = mutableListOf<String>()
            val errors = mutableListOf<String>()
            for (uri in uris) {
                try {
                    val raw = legacyDisplayName(uri) ?: "imported_${System.currentTimeMillis()}"
                    val name = raw.substringAfterLast('/').substringAfterLast('\\').trim()
                    if (name.isEmpty()) continue
                    val input = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法读取所选文件")
                    input.use { source ->
                        File(dir, name).outputStream().use { sink -> source.copyTo(sink) }
                    }
                    copied.add(name)
                } catch (e: Exception) {
                    errors.add(e.message ?: e.javaClass.simpleName)
                }
            }
            runOnUiThread {
                if (copied.isEmpty() && errors.isNotEmpty()) {
                    result.error("copy_failed", errors.joinToString("; "), null)
                } else {
                    result.success(copied)
                }
            }
        }.start()
    }

    private fun handleWatchToolPick(resultCode: Int, data: Intent?) {
        val result = pendingToolPickResult ?: return
        val kind = pendingToolPickKind
        pendingToolPickResult = null
        pendingToolPickKind = ""
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(if (kind == "music") emptyList<String>() else null)
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        if (uris.isEmpty()) {
            result.success(if (kind == "music") emptyList<String>() else null)
            return
        }
        if (kind == "map") {
            // 地图包可能上百 MB，不复制一份到私有目录，直接把 content Uri 交给下发线程。
            val uri = uris.first()
            val name = legacyDisplayName(uri)
                ?: uri.lastPathSegment
                ?: "map.bin"
            val size = runCatching {
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.SIZE),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else 0L
                } ?: 0L
            }.getOrDefault(0L)
            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "name" to name.substringAfterLast('/').substringAfterLast('\\'),
                    "size" to size,
                )
            )
            return
        }
        Thread {
            val dir = File(filesDir, "watch_tools").apply { mkdirs() }
            val copied = mutableListOf<File>()
            try {
                for (uri in uris) {
                    val raw = legacyDisplayName(uri) ?: "picked_${System.currentTimeMillis()}"
                    val name = raw.substringAfterLast('/').substringAfterLast('\\').trim()
                        .ifBlank { "picked_${System.currentTimeMillis()}" }
                    val target = uniqueFile(dir, name)
                    contentResolver.openInputStream(uri)?.use { source ->
                        target.outputStream().use { sink -> source.copyTo(sink) }
                    } ?: throw IllegalStateException("无法读取所选文件")
                    copied.add(target)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    if (kind == "music") {
                        result.success(copied.map { it.absolutePath })
                    } else {
                        result.error("copy_failed", e.message ?: "复制文件失败", null)
                    }
                }
                return@Thread
            }
            runOnUiThread {
                when (kind) {
                    "music" -> result.success(copied.map { it.absolutePath })
                    "app" -> {
                        val file = copied.firstOrNull()
                        if (file == null) {
                            result.success(null)
                            return@runOnUiThread
                        }
                        val info = packageManager.getPackageArchiveInfo(file.absolutePath, 0)
                        result.success(
                            mapOf(
                                "path" to file.absolutePath,
                                "package" to (info?.packageName ?: ""),
                                "name" to (info?.applicationInfo?.loadLabel(packageManager)?.toString() ?: file.name),
                            ),
                        )
                    }
                    else -> {
                        val file = copied.firstOrNull()
                        if (file == null) {
                            result.success(null)
                            return@runOnUiThread
                        }
                        val version = runCatching {
                            WatchfacePackage.prepare(
                                file.readBytes(),
                                WatchfacePackage.PayloadMode.BIN,
                            ).declaredVersion
                        }.getOrDefault("")
                        result.success(
                            mapOf(
                                "path" to file.absolutePath,
                                "name" to file.nameWithoutExtension,
                                "version" to version,
                                "mode" to "BIN",
                            ),
                        )
                    }
                }
            }
        }.start()
    }

    private fun uniqueFile(dir: File, name: String): File {
        var target = File(dir, name)
        if (!target.exists()) return target
        val base = name.substringBeforeLast('.', name)
        val ext = name.substringAfterLast('.', "")
        var index = 1
        while (target.exists()) {
            val candidate = if (ext.isEmpty()) "${base}_$index" else "${base}_$index.$ext"
            target = File(dir, candidate)
            index++
        }
        return target
    }

    private fun legacyDisplayName(uri: Uri): String? {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        }
        return uri.lastPathSegment
    }

    private fun currentVersionCode(): Long = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        versionCodeOf(info)
    } catch (_: Exception) {
        0L
    }

    private fun currentVersionName(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (_: Exception) {
        "?"
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= 26) packageManager.canRequestPackageInstalls() else true

    private fun archiveInfo(file: File): PackageInfo? = try {
        val flags = if (Build.VERSION.SDK_INT >= 28) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        packageManager.getPackageArchiveInfo(file.absolutePath, flags)
    } catch (_: Exception) {
        null
    }

    private fun signaturesOf(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) {
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        }
        return signatures.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    private fun sameSigningKey(archive: PackageInfo): Boolean = try {
        val installed = packageManager.getPackageInfo(
            packageName,
            if (Build.VERSION.SDK_INT >= 28) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            },
        )
        val current = signaturesOf(installed)
        current.isNotEmpty() && current == signaturesOf(archive)
    } catch (_: Exception) {
        false
    }

    private fun downloadAndInstall(url: String, result: MethodChannel.Result) {
        Thread {
            fun finish(ok: Boolean, message: String, versionName: String? = null) {
                updateDownloading = false
                runOnUiThread {
                    result.success(
                        mapOf(
                            "ok" to ok,
                            "message" to message,
                            "versionName" to versionName,
                        )
                    )
                }
            }

            var target: File? = null
            try {
                val dir = File(getExternalFilesDir(null), "update").apply { mkdirs() }
                val apkFile = File(dir, "Vitaloop_update.apk")
                target = apkFile
                if (apkFile.exists()) apkFile.delete()

                val request = Request.Builder()
                    .url(url)
                    .header("User-Agent", "Vitaloop/${currentVersionName()}")
                    .build()
                updateClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) throw IOException("下载失败：HTTP ${response.code}")
                    val body = response.body ?: throw IOException("下载响应为空")
                    if (body.contentLength() == 0L) throw IOException("下载文件为空")
                    body.byteStream().use { input ->
                        apkFile.outputStream().use { output -> input.copyTo(output) }
                    }
                }
                if (!apkFile.exists() || apkFile.length() == 0L) throw IOException("下载文件为空")

                val archive = archiveInfo(apkFile) ?: throw IOException("无法读取下载包信息")
                if (archive.packageName != packageName) {
                    throw IOException("下载包不是元环（${archive.packageName}）")
                }
                if (versionCodeOf(archive) <= currentVersionCode()) {
                    throw IOException("下载包版本不高于当前版本")
                }
                if (!sameSigningKey(archive)) {
                    throw IOException("下载包签名与当前安装包不一致")
                }

                runOnUiThread {
                    try {
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apkFile,
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                    } catch (e: Exception) {
                        Log.e("VitaloopUpdate", "install failed", e)
                    }
                }
                finish(true, "已拉起系统安装器", archive.versionName)
            } catch (e: Exception) {
                target?.delete()
                Log.e("VitaloopUpdate", "download failed", e)
                finish(false, e.message ?: "下载或安装失败")
            }
        }.start()
    }

    private fun saveImageToGallery(name: String, mime: String, bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        "${Environment.DIRECTORY_PICTURES}/Vitaloop",
                    )
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val collection = MediaStore.Images.Media.getContentUri(
                    MediaStore.VOLUME_EXTERNAL_PRIMARY,
                )
                val uri = contentResolver.insert(collection, values) ?: return false
                contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes) } ?: return false
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } else {
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                    "Vitaloop",
                ).apply { mkdirs() }
                val file = File(dir, name)
                file.writeBytes(bytes)
                MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf(mime), null)
            }
            true
        } catch (e: Exception) {
            Log.e("VitaloopExport", "save image failed", e)
            false
        }
    }

    private fun wrap(kind: String, payload: JSONObject): String =
        JSONObject().put("kind", kind).put("payload", payload).toString()

    override fun onDestroy() {
        // 只解绑回调，不断链路：Activity 销毁后由 WatchSyncService 继续持有连接
        eventSink = null
        watchManager?.onState = null
        watchManager?.onEvent = null
        watchManager = null
        bleSink = null
        bleManager?.onEvent = null
        bleManager = null
        gpsSink = null
        gpsManager?.onPoint = null
        gpsManager?.onState = null
        gpsManager = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        ttsReady = false
        super.onDestroy()
    }
}
