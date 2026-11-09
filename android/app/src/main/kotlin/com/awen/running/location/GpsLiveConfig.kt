package com.awen.running.location

import android.content.Context
import org.json.JSONArray

/**
 * 实时轨迹共享配置。服务地址和访问令牌都由用户填写，仓库里不内置任何私有服务
 * 地址或凭据；自建服务只需实现 /update、/hr、/clear、/start、/stop 五个 POST
 * 接口即可。
 */
object GpsLiveConfig {
    private const val PREFS = "vitaloop_gps_live"
    private const val KEY_SERVER_URL = "server_url"
    private const val KEY_ACCESS_TOKEN = "access_token"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PAUSED = "paused"
    private const val KEY_AUTO_SHARE = "auto_share"
    private const val KEY_PENDING = "pending"

    private val actions = setOf("update", "hr", "clear", "start", "stop")

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun serverUrl(context: Context): String =
        prefs(context).getString(KEY_SERVER_URL, "").orEmpty().trim()

    fun setServerUrl(context: Context, url: String) {
        prefs(context).edit().putString(KEY_SERVER_URL, url.trim()).apply()
    }

    fun accessToken(context: Context): String =
        prefs(context).getString(KEY_ACCESS_TOKEN, "").orEmpty()

    fun setAccessToken(context: Context, value: String) {
        prefs(context).edit().putString(KEY_ACCESS_TOKEN, value.trim()).apply()
    }

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun isPaused(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PAUSED, false)

    fun setPaused(context: Context, paused: Boolean) {
        prefs(context).edit().putBoolean(KEY_PAUSED, paused).apply()
    }

    fun isAutoShareOnWorkout(context: Context): Boolean =
        prefs(context).getBoolean(KEY_AUTO_SHARE, true)

    fun setAutoShareOnWorkout(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_AUTO_SHARE, enabled).apply()
    }

    fun isConfigured(context: Context): Boolean {
        return serverUrl(context).startsWith("http://") ||
            serverUrl(context).startsWith("https://")
    }

    /**
     * 支持两种填法：
     * - https://example.com/gps        → https://example.com/gps/update
     * - https://example.com/gps/update → https://example.com/gps/update
     */
    fun endpoint(context: Context, action: String): String {
        val base = serverUrl(context).trimEnd('/')
        if (base.isEmpty()) return ""
        val normalizedAction = action.trim('/')
        val last = base.substringAfterLast('/')
        if (last in actions) {
            return base.substringBeforeLast('/') + "/" + normalizedAction
        }
        return "$base/$normalizedAction"
    }

    fun loadPending(context: Context): JSONArray {
        val raw = prefs(context).getString(KEY_PENDING, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    fun savePending(context: Context, array: JSONArray) {
        prefs(context).edit().putString(KEY_PENDING, array.toString()).apply()
    }
}
