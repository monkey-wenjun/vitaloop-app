package me.awen.vitaloop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.awen.running.huawei.VitaloopWatchManager

/** 开机后重新拉起保活服务，否则重启手机就得手动打开 App 才能连表 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val manager = VitaloopWatchManager.getInstance(context)
        if (manager.isAutoSyncEnabled() && manager.savedWatch() != null) {
            WatchSyncService.start(context)
        }
    }
}
