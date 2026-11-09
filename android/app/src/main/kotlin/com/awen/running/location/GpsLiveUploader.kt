package com.awen.running.location

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 实时轨迹 HTTP 上报；只用标准库，方便自建服务端和离线打包。 */
object GpsLiveUploader {
    private const val TAG = "GpsLiveUploader"

    @Volatile
    var lastUploadError: String? = null
        private set

    fun uploadPoint(context: Context, point: JSONObject): Boolean =
        post(context, GpsLiveConfig.endpoint(context, "update"), point)

    fun uploadHeartRate(
        context: Context,
        heartRate: Int,
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        battery: Int,
        timestamp: Long,
    ): Boolean {
        val body = JSONObject()
            .put("hr", heartRate)
            .put("lat", latitude)
            .put("lng", longitude)
            .put("accuracy", accuracy)
            .put("battery", battery)
            .put("timestamp", timestamp)
        return post(context, GpsLiveConfig.endpoint(context, "hr"), body)
    }

    fun clear(context: Context): Boolean =
        post(context, GpsLiveConfig.endpoint(context, "clear"), JSONObject())

    fun startSession(context: Context): Boolean =
        post(context, GpsLiveConfig.endpoint(context, "start"), JSONObject())

    fun stopSession(context: Context): Boolean =
        post(context, GpsLiveConfig.endpoint(context, "stop"), JSONObject())

    private fun post(context: Context, url: String, body: JSONObject): Boolean {
        if (url.isBlank()) {
            lastUploadError = "尚未配置共享轨迹服务地址"
            return false
        }
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 8_000
            connection.readTimeout = 8_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            val token = GpsLiveConfig.accessToken(context)
            if (token.isNotBlank()) connection.setRequestProperty("X-GPS-Token", token)
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = connection.responseCode
            val success = code in 200..299
            if (success) {
                lastUploadError = null
            } else {
                val detail = try {
                    connection.errorStream?.bufferedReader()?.use { it.readText() }?.take(200).orEmpty()
                } catch (_: Exception) {
                    ""
                }
                lastUploadError = "上报失败 HTTP $code${if (detail.isBlank()) "" else " - $detail"}"
                Log.w(TAG, "上报失败 HTTP $code $detail")
            }
            connection.disconnect()
            success
        } catch (e: Exception) {
            lastUploadError = e.message ?: "网络异常"
            Log.w(TAG, "上报异常: ${e.message}")
            false
        }
    }
}
