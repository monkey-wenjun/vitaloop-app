package me.awen.vitaloop

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
import com.awen.running.huawei.VitaloopWatchManager

/**
 * 手表后台保活服务：App 退到后台、被系统回收或开机后，由它周期性地把链路拉回来并补同步。
 * 前台服务而非 WorkManager——RFCOMM 是一条长连接，需要进程一直活着，15 分钟粒度的调度兜不住。
 */
class WatchSyncService : Service() {

    companion object {
        private const val TAG = "WatchSyncService"
        private const val CHANNEL_ID = "vitaloop_watch_sync"
        private const val NOTIFICATION_ID = 2001
        private const val TICK_MS = 120_000L

        fun start(context: Context) {
            val intent = Intent(context, WatchSyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WatchSyncService::class.java))
        }
    }

    @Volatile private var running = false
    private var worker: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        goForeground()
        if (running) return START_STICKY
        running = true
        worker = Thread({ loop() }, "VitaloopWatchKeepAlive").apply { start() }
        return START_STICKY
    }

    private fun loop() {
        val manager = VitaloopWatchManager.getInstance(applicationContext)
        while (running) {
            try {
                manager.keepAlive()
                refreshNotification(manager.state)
            } catch (e: Exception) {
                Log.e(TAG, "后台保活异常", e)
            }
            try {
                Thread.sleep(TICK_MS)
            } catch (_: InterruptedException) {
                return
            }
        }
    }

    private fun goForeground() {
        createChannel()
        val notification = buildNotification(getString(R.string.watch_sync_connecting))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun refreshNotification(state: String) {
        val text = when {
            state == "ready" -> getString(R.string.watch_sync_connected)
            state == "connecting" -> getString(R.string.watch_sync_connecting_device)
            state == "authenticating" -> getString(R.string.watch_sync_authenticating)
            state == "configuring" -> getString(R.string.watch_sync_configuring)
            state.startsWith("failed:") -> getString(R.string.watch_sync_failed)
            else -> getString(R.string.watch_sync_waiting)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(getString(R.string.watch_sync_notification_title))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.watch_sync_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = getString(R.string.watch_sync_channel_description)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        super.onDestroy()
    }
}
