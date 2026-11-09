package com.awen.running.service

import android.content.Context

/** 用户自填的直播推流配置。地址可能包含鉴权参数，只在原生侧保存，不回传到页面。 */
object LiveStreamConfig {
    private const val PREFS = "live_stream_config"
    private const val KEY_VOICE_URL = "voice_push_url"
    private const val KEY_VIDEO_URL = "video_push_url"
    private const val KEY_DJI_SSID = "dji_wifi_ssid"
    private const val KEY_DJI_PASSWORD = "dji_wifi_password"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun voiceUrl(context: Context): String =
        prefs(context).getString(KEY_VOICE_URL, "")?.trim().orEmpty()

    fun hasVoiceUrl(context: Context): Boolean = voiceUrl(context).isNotBlank()

    fun setVoiceUrl(context: Context, url: String) {
        prefs(context).edit().putString(KEY_VOICE_URL, url.trim()).apply()
    }

    fun videoUrl(context: Context): String =
        prefs(context).getString(KEY_VIDEO_URL, "")?.trim().orEmpty()

    fun hasVideoUrl(context: Context): Boolean = videoUrl(context).isNotBlank()

    fun setVideoUrl(context: Context, url: String) {
        prefs(context).edit().putString(KEY_VIDEO_URL, url.trim()).apply()
    }

    fun djiSsid(context: Context): String =
        prefs(context).getString(KEY_DJI_SSID, "")?.trim().orEmpty()

    fun djiPassword(context: Context): String =
        prefs(context).getString(KEY_DJI_PASSWORD, "").orEmpty()

    fun hasDjiWifi(context: Context): Boolean =
        djiSsid(context).isNotBlank() && djiPassword(context).isNotBlank()

    fun setDjiWifi(context: Context, ssid: String, password: String) {
        prefs(context).edit()
            .putString(KEY_DJI_SSID, ssid.trim())
            .putString(KEY_DJI_PASSWORD, password)
            .apply()
    }
}
