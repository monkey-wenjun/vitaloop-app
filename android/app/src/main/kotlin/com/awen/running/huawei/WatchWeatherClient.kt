package com.awen.running.huawei

import android.content.Context
import android.location.Geocoder
import android.location.Location
import android.util.Log
import com.awen.running.data.WeatherSpec
import com.awen.running.utils.FileLogger
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * 手表天气数据源。旧版走高德 Web 天气，新版不绑定高德 key，
 * 统一用 Open-Meteo（免费、无需 key），按当前坐标取实时天气和 7 天预报。
 */
object WatchWeatherClient {
    private const val TAG = "WatchWeather"
    private const val FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

    fun fetch(context: Context, location: Location, locationName: String?): WeatherSpec? {
        return try {
            val url = "$FORECAST_URL" +
                "?latitude=${location.latitude}&longitude=${location.longitude}" +
                "&current=temperature_2m,relative_humidity_2m,weather_code," +
                "wind_speed_10m,wind_direction_10m" +
                "&daily=weather_code,temperature_2m_max,temperature_2m_min" +
                "&forecast_days=7&timezone=Asia%2FShanghai"
            val body = get(url)
            val json = JSONObject(body)
            val current = json.getJSONObject("current")
            val daily = json.getJSONObject("daily")

            val spec = WeatherSpec()
            spec.timestamp = (System.currentTimeMillis() / 1000).toInt()
            spec.location = locationName?.takeIf { it.isNotBlank() }
                ?: reverseGeocode(context, location)
            spec.currentTemp = kelvin(current.getDouble("temperature_2m"))
            spec.currentHumidity = current.getInt("relative_humidity_2m")
            spec.currentConditionCode = wmoToOwm(current.getInt("weather_code"))
            spec.windSpeed = current.getDouble("wind_speed_10m").toFloat()
            spec.windDirection = current.getInt("wind_direction_10m")

            val times = daily.getJSONArray("time")
            val codes = daily.getJSONArray("weather_code")
            val maxTemps = daily.getJSONArray("temperature_2m_max")
            val minTemps = daily.getJSONArray("temperature_2m_min")
            for (i in 0 until times.length()) {
                val item = WeatherSpec.Daily()
                item.timestamp = parseDate(times.getString(i))
                item.maxTemp = kelvin(maxTemps.getDouble(i))
                item.minTemp = kelvin(minTemps.getDouble(i))
                item.conditionCode = wmoToOwm(codes.getInt(i))
                if (i == 0) {
                    spec.todayMaxTemp = item.maxTemp
                    spec.todayMinTemp = item.minTemp
                } else {
                    spec.forecasts.add(item)
                }
            }
            if (spec.todayMaxTemp == 0) {
                spec.todayMaxTemp = spec.currentTemp
                spec.todayMinTemp = spec.currentTemp
            }
            FileLogger.i(
                TAG,
                "Open-Meteo 天气: ${spec.location} ${spec.currentTemp - 273}°C " +
                    "humidity=${spec.currentHumidity}% forecast=${spec.forecasts.size}天",
            )
            spec
        } catch (e: Exception) {
            Log.w(TAG, "获取天气失败", e)
            FileLogger.e(TAG, "Open-Meteo 天气获取失败", e)
            null
        }
    }

    private fun get(url: String): String {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 8000
        conn.requestMethod = "GET"
        try {
            val code = conn.responseCode
            if (code !in 200..299) error("HTTP $code")
            return conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private fun kelvin(celsius: Double): Int = (celsius + 273.15).toInt()

    private fun parseDate(date: String): Int {
        return try {
            Instant.parse("${date}T06:00:00Z")
                .atZone(ZoneId.systemDefault())
                .toEpochSecond()
                .toInt()
        } catch (_: Exception) {
            (System.currentTimeMillis() / 1000).toInt()
        }
    }

    private fun reverseGeocode(context: Context, location: Location): String {
        return try {
            if (!Geocoder.isPresent()) return "当前位置"
            val list = Geocoder(context, Locale.getDefault())
                .getFromLocation(location.latitude, location.longitude, 1)
            list?.firstOrNull()?.let { address ->
                address.subLocality
                    ?.takeIf { it.isNotBlank() }
                    ?: address.locality?.takeIf { it.isNotBlank() }
                    ?: address.adminArea
            } ?: "当前位置"
        } catch (_: Exception) {
            "当前位置"
        }
    }

    /** WMO 天气代码 → OpenWeatherMap 代码（华为天气图标映射用） */
    private fun wmoToOwm(wmo: Int): Int = when (wmo) {
        0 -> 800
        1 -> 801
        2 -> 802
        3 -> 804
        45, 48 -> 741
        51, 53, 55 -> 500
        56, 57 -> 511
        61 -> 501
        63 -> 502
        65 -> 503
        66, 67 -> 511
        71, 73, 75 -> 600
        77 -> 600
        80, 81, 82 -> 520
        85, 86 -> 600
        95 -> 200
        96, 99 -> 202
        else -> 3200
    }
}
