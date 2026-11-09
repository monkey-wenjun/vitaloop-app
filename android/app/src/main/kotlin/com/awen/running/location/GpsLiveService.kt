package com.awen.running.location

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.awen.running.bluetooth.VitaloopBleManager
import com.awen.running.huawei.VitaloopWatchManager
import com.awen.running.service.DjiActionManager
import com.awen.running.service.VoicePushManager
import me.awen.vitaloop.MainActivity
import me.awen.vitaloop.R
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 运动中实时共享 GPS：前台服务采集、队列上报，断网时退避重试。
 * 服务地址与访问令牌完全由用户配置，不内置任何私有端点。
 */
class GpsLiveService : Service() {

    companion object {
        private const val TAG = "GpsLiveService"
        private const val CHANNEL_ID = "vitaloop_gps_live"
        private const val NOTIFICATION_ID = 2002
        private const val ACTION_START = "com.awen.vitaloop.gps_live.START"
        private const val ACTION_PAUSE = "com.awen.vitaloop.gps_live.PAUSE"
        private const val ACTION_RESUME = "com.awen.vitaloop.gps_live.RESUME"
        private const val ACTION_STOP = "com.awen.vitaloop.gps_live.STOP"
        private const val ACTION_RESTORE = "com.awen.vitaloop.gps_live.RESTORE"
        private const val ACTION_ENABLE_MIC = "com.awen.vitaloop.gps_live.ENABLE_MIC"
        private const val ACTION_DISABLE_MIC = "com.awen.vitaloop.gps_live.DISABLE_MIC"
        private const val GPS_CLIENT = "gps_live"
        private const val PENDING_LIMIT = 2_000
        private const val RETRY_INTERVAL_MS = 10_000L
        private const val KEEP_ALIVE_INTERVAL_MS = 90_000L
        private const val WATCH_HR_FRESH_MS = 5 * 60_000L

        @Volatile private var running = false
        @Volatile private var paused = false
        @Volatile private var lastLat = 0.0
        @Volatile private var lastLng = 0.0
        @Volatile private var lastAccuracy = 0.0
        @Volatile private var lastSpeed = 0.0
        @Volatile private var lastHeartRate = 0
        @Volatile private var lastFixTime = 0L
        @Volatile private var startedAt = 0L
        @Volatile private var sentCount = 0
        @Volatile private var pendingCount = 0
        @Volatile private var receivedCount = 0
        @Volatile private var lastError: String? = null

        fun start(context: Context) = sendAction(context, ACTION_START)

        fun pause(context: Context) = sendAction(context, ACTION_PAUSE)

        fun resume(context: Context) = sendAction(context, ACTION_RESUME)

        fun stop(context: Context) = sendAction(context, ACTION_STOP)

        fun enableMicrophone(context: Context) = sendAction(context, ACTION_ENABLE_MIC)

        fun disableMicrophone(context: Context) = sendAction(context, ACTION_DISABLE_MIC)

        fun restoreIfNeeded(context: Context) {
            if (!GpsLiveConfig.isEnabled(context)) return
            sendAction(context, ACTION_RESTORE)
        }

        private fun sendAction(context: Context, action: String) {
            val intent = Intent(context, GpsLiveService::class.java).setAction(action)
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }.onFailure { Log.w(TAG, "启动共享轨迹服务失败", it) }
        }

        fun statusJson(context: Context): String {
            val autoShare = GpsLiveConfig.isAutoShareOnWorkout(context)
            return JSONObject()
                .put("running", running)
                .put("paused", paused)
                .put("configured", GpsLiveConfig.isConfigured(context))
                .put("serverUrl", GpsLiveConfig.serverUrl(context))
                .put("hasToken", GpsLiveConfig.accessToken(context).isNotBlank())
                .put("autoShare", autoShare)
                .put("lastLat", lastLat)
                .put("lastLng", lastLng)
                .put("accuracy", lastAccuracy)
                .put("speed", lastSpeed)
                .put("heartRate", lastHeartRate)
                .put("lastFixTime", lastFixTime)
                .put("startedAt", startedAt)
                .put("sentCount", sentCount)
                .put("pendingCount", pendingCount)
                .put("receivedCount", receivedCount)
                .put("voice", VoicePushManager.isPushing)
                .put("voiceError", VoicePushManager.errorMessage ?: "")
                .put("lastError", lastError ?: "")
                .toString()
        }
    }

    private val gps by lazy { VitaloopGpsManager.getInstance(applicationContext) }
    private val pending = ConcurrentLinkedQueue<JSONObject>()
    private val uploadExecutor = Executors.newSingleThreadExecutor()
    private val active = AtomicBoolean(false)
    private var retryThread: Thread? = null
    private var lastKeepAlive = 0L
    private var lastPointPersist = 0L
    @Volatile private var microphoneForeground = false
    private val pointListener: (JSONObject) -> Unit = { handlePoint(it) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        restorePending()
        goForeground(getString(R.string.gps_live_waiting))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopAll()
            ACTION_START -> startAll()
            ACTION_PAUSE -> if (active.get()) pauseAll() else stopSelf()
            ACTION_RESUME -> if (active.get()) resumeAll() else stopSelf()
            ACTION_RESTORE -> restoreIfNeeded()
            ACTION_ENABLE_MIC -> setMicrophoneForeground(true)
            ACTION_DISABLE_MIC -> setMicrophoneForeground(false)
            else -> {
                if (GpsLiveConfig.isEnabled(this)) {
                    startAll()
                    if (GpsLiveConfig.isPaused(this)) pauseAll()
                } else {
                    stopAll()
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        active.set(false)
        running = false
        gps.removePointListener(pointListener)
        gps.stop(GPS_CLIENT)
        stopVoice()
        if (DjiActionManager.isStreaming) DjiActionManager.stopLiveStream()
        savePending()
        uploadExecutor.shutdown()
        super.onDestroy()
    }

    private fun restoreIfNeeded() {
        if (!GpsLiveConfig.isEnabled(this)) {
            stopAll()
            return
        }
        startAll()
        if (GpsLiveConfig.isPaused(this)) pauseAll()
    }

    private fun startAll() {
        if (!GpsLiveConfig.isConfigured(this)) {
            lastError = getString(R.string.gps_live_fill_service)
            updateNotification(getString(R.string.gps_live_no_service), lastError ?: "")
            stopSelf()
            return
        }
        if (active.get()) return
        active.set(true)
        running = true
        paused = false
        startedAt = System.currentTimeMillis()
        lastError = null
        receivedCount = 0
        GpsLiveConfig.setEnabled(this, true)
        GpsLiveConfig.setPaused(this, false)
        gps.addPointListener(pointListener)
        if (!gps.start(GPS_CLIENT)) {
            lastError = getString(R.string.gps_live_check_location)
            updateNotification(getString(R.string.gps_live_location_failed), lastError ?: "")
        } else {
            updateNotification(
                getString(R.string.gps_live_locating),
                getString(R.string.gps_live_getting_route),
            )
        }
        startRetryLoop()
        uploadExecutor.execute {
            if (!GpsLiveUploader.startSession(this)) {
                Log.w(TAG, "创建共享会话失败: ${GpsLiveUploader.lastUploadError}")
            }
        }
    }

    private fun stopAll() {
        active.set(false)
        running = false
        paused = false
        GpsLiveConfig.setEnabled(this, false)
        GpsLiveConfig.setPaused(this, false)
        gps.removePointListener(pointListener)
        gps.stop(GPS_CLIENT)
        stopVoice()
        if (DjiActionManager.isStreaming) DjiActionManager.stopLiveStream()
        savePending()
        uploadExecutor.execute { GpsLiveUploader.stopSession(this) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun pauseAll() {
        if (!active.get() || paused) return
        paused = true
        GpsLiveConfig.setPaused(this, true)
        gps.stop(GPS_CLIENT)
        updateNotification(
            getString(R.string.gps_live_paused),
            getString(R.string.gps_live_paused_body),
        )
        uploadExecutor.execute { sendKeepAlive() }
    }

    private fun resumeAll() {
        if (!active.get() || !paused) return
        paused = false
        GpsLiveConfig.setPaused(this, false)
        gps.addPointListener(pointListener)
        if (!gps.start(GPS_CLIENT)) {
            lastError = getString(R.string.gps_live_restore_failed)
        }
        updateNotification(
            getString(R.string.gps_live_sharing),
            getString(R.string.gps_live_resumed),
        )
    }

    private fun handlePoint(raw: JSONObject) {
        if (!active.get()) return
        if (raw.optBoolean("cached", false)) return
        lastLat = raw.optDouble("lat", 0.0)
        lastLng = raw.optDouble("lon", 0.0)
        lastAccuracy = raw.optDouble("accuracy", 0.0)
        lastSpeed = raw.optDouble("speed", 0.0)
        lastHeartRate = currentHeartRate()
        lastFixTime = raw.optLong("ts", System.currentTimeMillis())
        receivedCount++
        if (paused) return

        val point = JSONObject()
            .put("lat", lastLat)
            .put("lng", lastLng)
            .put("alt", raw.optDouble("alt", 0.0))
            .put("bearing", raw.optDouble("bearing", 0.0))
            .put("accuracy", lastAccuracy)
            .put("speed", lastSpeed)
            .put("hr", if (lastHeartRate > 0) lastHeartRate else 0)
            .put("battery", batteryLevel())
            .put("timestamp", lastFixTime)
        pending.add(point)
        trimPending()
        pendingCount = pending.size
        val now = System.currentTimeMillis()
        if (now - lastPointPersist > 15_000L) {
            lastPointPersist = now
            savePending()
        }
        updateNotification(getString(R.string.gps_live_sharing), point)
        uploadExecutor.execute { flushPending() }
    }

    /** 优先用心率带；没有心率带时回退到已连接手表最近 5 分钟内的实时心率。 */
    private fun currentHeartRate(): Int {
        val belt = VitaloopBleManager.getInstance(applicationContext).latestHeartRate()
        if (belt > 0) return belt

        val watch = VitaloopWatchManager.latestHeartRate
        val watchTime = VitaloopWatchManager.latestHeartRateTime
        if (watch > 0 && watchTime > 0 &&
            System.currentTimeMillis() - watchTime <= WATCH_HR_FRESH_MS
        ) {
            return watch
        }
        return 0
    }

    private fun flushPending() {
        while (active.get() && pending.isNotEmpty()) {
            val point = pending.peek() ?: break
            if (!GpsLiveUploader.uploadPoint(this, point)) {
                lastError = GpsLiveUploader.lastUploadError
                    ?: getString(R.string.gps_live_upload_failed)
                break
            }
            pending.poll()
            sentCount++
            lastError = null
        }
        pendingCount = pending.size
        savePending()
    }

    private fun sendKeepAlive() {
        if (!GpsLiveConfig.isConfigured(this)) return
        val body = JSONObject()
            .put("lat", lastLat)
            .put("lng", lastLng)
            .put("accuracy", lastAccuracy)
            .put("speed", 0.0)
            .put("hr", if (lastHeartRate > 0) lastHeartRate else 0)
            .put("battery", batteryLevel())
            .put("timestamp", System.currentTimeMillis())
            .put("paused", true)
        GpsLiveUploader.uploadPoint(this, body)
    }

    private fun startRetryLoop() {
        if (retryThread?.isAlive == true) return
        retryThread = Thread({
            while (active.get()) {
                try {
                    Thread.sleep(RETRY_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (!active.get()) return@Thread
                if (paused) {
                    val now = System.currentTimeMillis()
                    if (now - lastKeepAlive >= KEEP_ALIVE_INTERVAL_MS) {
                        lastKeepAlive = now
                        uploadExecutor.execute { sendKeepAlive() }
                    }
                } else {
                    if (lastFixTime == 0L) gps.start(GPS_CLIENT)
                    if (pending.isNotEmpty()) {
                        uploadExecutor.execute { flushPending() }
                    }
                }
            }
        }, "VitaloopGpsLiveRetry").apply {
            isDaemon = true
            start()
        }
    }

    private fun trimPending() {
        while (pending.size > PENDING_LIMIT) pending.poll()
    }

    private fun restorePending() {
        val array = GpsLiveConfig.loadPending(this)
        for (i in 0 until array.length()) {
            try {
                pending.add(array.getJSONObject(i))
            } catch (_: Exception) {
                // 跳过损坏条目
            }
        }
        trimPending()
        pendingCount = pending.size
    }

    private fun savePending() {
        val array = JSONArray()
        pending.forEach { array.put(it) }
        GpsLiveConfig.savePending(this, array)
    }

    private fun batteryLevel(): Int = try {
        val manager = getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
        manager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
    } catch (_: Exception) {
        -1
    }

    private fun setMicrophoneForeground(enabled: Boolean) {
        if (!active.get()) return
        microphoneForeground = enabled
        goForeground(
            getString(
                if (enabled) R.string.gps_live_mic_enabled
                else R.string.gps_live_sharing,
            ),
        )
    }

    private fun stopVoice() {
        Thread({ VoicePushManager.stop() }, "VitaloopVoiceStop").apply {
            isDaemon = true
            start()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.gps_live_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.gps_live_channel_description)
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun goForeground(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val canUseMicrophone =
                microphoneForeground &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            val type = if (canUseMicrophone) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            startForeground(
                NOTIFICATION_ID,
                notification,
                type,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(title: String, point: JSONObject) {
        val text = buildString {
            append(String.format("%.5f, %.5f", point.optDouble("lat"), point.optDouble("lng")))
            append(" · ${point.optDouble("accuracy", 0.0).toInt()}m")
            if (point.optInt("hr", 0) > 0) {
                append(" · ${getString(R.string.gps_live_heart_rate)} ${point.optInt("hr")}")
            }
        }
        updateNotification(title, text)
    }

    private fun updateNotification(title: String, text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text, title))
    }

    private fun buildNotification(text: String, title: String? = null): Notification {
        val resolvedTitle = title ?: getString(R.string.gps_live_title)
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle(getString(R.string.gps_live_notification_title, resolvedTitle))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }
}
