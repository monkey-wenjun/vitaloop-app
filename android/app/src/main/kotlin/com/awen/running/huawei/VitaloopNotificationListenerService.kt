package com.awen.running.huawei

import android.app.Notification
import android.content.ComponentName
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.awen.running.utils.FileLogger
import nodomain.freeyourgadget.gadgetbridge.model.NotificationType

/**
 * 把手机 App 通知转发到华为手表。用户在系统设置里授予“通知使用权”后生效；
 * 手表设置页里的“通知转发”总开关关闭时静默跳过。
 */
class VitaloopNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val TAG = "VitaloopNotify"
        private val BLOCKED_PACKAGES = setOf(
            // 领克车况提醒属于车辆状态，不往手表转发。
            "com.awen.lynkcar",
        )

        fun isEnabled(context: android.content.Context): Boolean {
            val component = ComponentName(context, VitaloopNotificationListenerService::class.java)
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners",
            )
            return enabled?.split(':')?.any {
                it.equals(component.flattenToString(), ignoreCase = true)
            } == true
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)
        if (sbn.isOngoing || sbn.packageName == packageName) return
        if (sbn.packageName in BLOCKED_PACKAGES) return
        val manager = VitaloopWatchManager.shared ?: return
        val prefs = getSharedPreferences("vitaloop_watch", MODE_PRIVATE)
        if (!prefs.getBoolean("notification_forward", true)) return
        val mode = prefs.getString("notification_filter_mode", "all") ?: "all"
        val packages = prefs.getStringSet("notification_filter_packages", emptySet()) ?: emptySet()
        if (mode == "whitelist" && sbn.packageName !in packages) return
        if (mode == "blacklist" && sbn.packageName in packages) return

        try {
            val extras = sbn.notification?.extras ?: return
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
                ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            if (title.isNullOrBlank() && text.isNullOrBlank()) return
            val type = when {
                sbn.packageName.contains("telegram") ||
                    sbn.packageName.contains("whatsapp") ||
                    sbn.packageName.contains("wechat") ||
                    sbn.packageName.contains("qq") ||
                    sbn.packageName.contains("dingtalk") -> NotificationType.TELEGRAM
                sbn.packageName.contains("mail") ||
                    sbn.packageName.contains("gmail") ||
                    sbn.packageName.contains("outlook") -> NotificationType.GENERIC_EMAIL
                sbn.packageName.contains("sms") ||
                    sbn.packageName.contains("mms") ||
                    sbn.packageName.contains("messages") -> NotificationType.GENERIC_SMS
                sbn.packageName.contains("clock") ||
                    sbn.packageName.contains("alarm") -> NotificationType.GENERIC_ALARM_CLOCK
                else -> NotificationType.UNKNOWN
            }
            manager.pushNotification(title, null, text, sbn.packageName, type)
            FileLogger.i(TAG, "通知转发: ${sbn.packageName} $title")
        } catch (e: Exception) {
            Log.e(TAG, "通知解析失败", e)
        }
    }
}
