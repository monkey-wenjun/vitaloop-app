package com.awen.running.huawei

import android.content.Context
import android.provider.Settings
import com.awen.running.utils.FileLogger

/**
 * 把「手表佩戴状态」发布到 Settings.Secure，交给 com.awen.auto 的信任代理判定。
 *
 * 沿用旧版的键名，解锁侧不用改；心跳时间戳保证 fail-closed：本进程被冻结或
 * 手表查不到时，解锁侧超过 45 秒会自己收回放行。
 */
object WearStateBridge {

    private const val TAG = "WearStateBridge"

    const val K_ENABLE = "awen_watch_unlock_enabled"
    const val K_STATE = "awen_watch_wear_state"
    const val K_AT = "awen_watch_wear_at"

    private const val REFRESH_MS = 10_000L

    @Volatile
    private var lastPublishedState = -1

    @Volatile
    private var lastWriteAt = 0L

    @Volatile
    private var lastGrantMissing = false

    fun readEnabled(ctx: Context): Boolean = readString(ctx, K_ENABLE) == "1"

    fun setEnabled(ctx: Context, on: Boolean): Boolean {
        val ok = writeAndVerify(ctx, K_ENABLE, if (on) "1" else "0")
        FileLogger.i(TAG, "在腕免密解锁开关 -> ${if (on) "开" else "关"}：${if (ok) "已落盘" else "写入失败"}")
        return ok
    }

    fun publish(ctx: Context, state: Int, reason: String) {
        if (!readEnabled(ctx)) return
        val now = System.currentTimeMillis()
        if (state == lastPublishedState && now - lastWriteAt < REFRESH_MS) return

        val stateOk = writeAndVerify(ctx, K_STATE, state.toString())
        writeAndVerify(ctx, K_AT, now.toString())
        if (stateOk && state != lastPublishedState) {
            FileLogger.i(TAG, "佩戴状态已发布($reason): $K_STATE=$state")
        }
        if (stateOk) {
            lastPublishedState = state
            lastWriteAt = now
        }
    }

    fun heartbeatAgeMs(ctx: Context): Long {
        val at = readString(ctx, K_AT)?.toLongOrNull() ?: return -1L
        return System.currentTimeMillis() - at
    }

    fun grantMissing(): Boolean = lastGrantMissing

    private fun writeAndVerify(ctx: Context, key: String, value: String): Boolean {
        val written = runCatching {
            Settings.Secure.putString(ctx.contentResolver, key, value)
        }.getOrElse {
            FileLogger.e(TAG, "写 $key 异常: ${it.javaClass.simpleName} ${it.message}")
            false
        }
        val back = readString(ctx, key)
        val ok = written && back == value
        if (!ok && !lastGrantMissing) {
            FileLogger.e(
                TAG,
                "! $key 写不进去 —— 需要一次授权：adb shell pm grant me.awen.vitaloop " +
                    "android.permission.WRITE_SECURE_SETTINGS",
            )
        }
        lastGrantMissing = !ok
        return ok
    }

    private fun readString(ctx: Context, key: String): String? =
        runCatching { Settings.Secure.getString(ctx.contentResolver, key) }.getOrNull()
}
