package me.awen.vitaloop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.awen.running.huawei.VitaloopWatchManager
import java.io.File

/**
 * adb 诊断入口：发一条华为协议原始命令，把应答 TLV 写到 filesDir/raw_probe.txt。
 *
 * 由 `android.permission.DUMP` 保护，只有 adb shell / root 能触发：
 * `adb shell am broadcast -a me.awen.vitaloop.action.RAW_PROBE --es req "0x01,0x2B,t,t"`
 *
 * 逆向阶段用来判定「手表认不认这个命令号/载荷」，只读不写。
 */
class RawProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val req = intent.getStringExtra("req")?.trim().orEmpty()
        if (req.isEmpty()) return
        val appContext = context.applicationContext
        Thread({
            val manager = VitaloopWatchManager.getInstance(appContext)
            val result = manager.probeRawCommand(req)
            runCatching {
                File(appContext.filesDir, "raw_probe.txt")
                    .appendText("$req\n$result\n\n")
            }
        }, "VitaloopRawProbeReceiver").start()
    }
}
