package com.awen.running.huawei

import android.content.Context
import com.awen.running.utils.FileLogger
import com.google.gson.Gson
import com.google.gson.JsonObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import java.time.format.DateTimeFormatter

/**
 * 中国法定节假日日历
 *
 * 数据源：holiday-cn（github.com/NateScarlet/holiday-cn，按国务院公告每年更新）。
 * 优先用 jsDelivr CDN 拉取当年数据并缓存 7 天；拉取失败时回退到 assets/holiday_2026.json；
 * 完全无数据时按普通工作日规则处理（周末不视为节假日跳过）。
 *
 * days 列表同时包含休息日（isOffDay=true）和调休上班日（isOffDay=false），
 * 因此未出现在列表中的日期就是普通工作日/周末。
 */
object HolidayCalendar {
    private const val TAG = "HolidayCalendar"
    private const val CACHE_KEY_PREFIX = "holiday_calendar_"
    private const val CACHE_TIME_SUFFIX = "_fetched_at"
    private const val CACHE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000L
    private const val FETCH_TIMEOUT_MS = 5000

    private val lock = Any()
    private val offDays = HashMap<String, Boolean>() // "yyyy-MM-dd" -> isOffDay
    private val loadedYears = HashSet<Int>()
    private val gson = Gson()
    private val dateFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    /** 指定日期是否为法定节假日（调休上班日不算）。 */
    fun isOffDay(context: Context, date: LocalDate): Boolean {
        ensureData(context, date.year)
        synchronized(lock) {
            return offDays[date.format(dateFormatter)] ?: false
        }
    }

    /**
     * 指定日期是否为工作日：
     * 调休上班日（isOffDay=false）算工作日；休息日（isOffDay=true）不算；
     * 未出现在列表中的日期按周一~周五为工作日、周六日休息。
     */
    fun isWorkday(context: Context, date: LocalDate): Boolean {
        ensureData(context, date.year)
        synchronized(lock) {
            val isOff = offDays[date.format(dateFormatter)]
            if (isOff != null) return !isOff
        }
        return date.dayOfWeek.value <= 5 // 1=周一 ... 7=周日
    }

    private fun ensureData(context: Context, year: Int) {
        synchronized(lock) {
            if (loadedYears.contains(year)) return
        }
        val prefs = context.getSharedPreferences("holiday_calendar", Context.MODE_PRIVATE)
        val key = CACHE_KEY_PREFIX + year
        val cached = prefs.getString(key, null)
        if (!cached.isNullOrEmpty() && parseAndLoad(year, cached)) {
            markLoaded(year)
            val fetchedAt = prefs.getLong(key + CACHE_TIME_SUFFIX, 0L)
            if (System.currentTimeMillis() - fetchedAt > CACHE_MAX_AGE_MS) {
                refreshInBackground(context, year, key)
            }
            return
        }
        loadFromAssets(context, year)
        refreshInBackground(context, year, key)
    }

    private fun loadFromAssets(context: Context, year: Int) {
        if (year != 2026) return
        try {
            val json = context.assets.open("holiday_2026.json")
                .bufferedReader(Charsets.UTF_8)
                .use { it.readText() }
            if (parseAndLoad(year, json)) {
                markLoaded(year)
                FileLogger.i(TAG, "使用内置 2026 节假日数据")
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "读取内置节假日数据失败", e)
        }
    }

    private fun refreshInBackground(context: Context, year: Int, key: String) {
        Thread {
            val json = fetchJson(year)
            if (json == null) {
                FileLogger.w(TAG, "节假日数据拉取失败，使用本地数据")
                return@Thread
            }
            if (parseAndLoad(year, json)) {
                markLoaded(year)
                context.getSharedPreferences("holiday_calendar", Context.MODE_PRIVATE)
                    .edit()
                    .putString(key, json)
                    .putLong(key + CACHE_TIME_SUFFIX, System.currentTimeMillis())
                    .apply()
                FileLogger.i(TAG, "节假日数据已更新（$year 年）")
            }
        }.apply { isDaemon = true }.start()
    }

    private fun fetchJson(year: Int): String? {
        val urls = listOf(
            "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/$year.json",
            "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/$year.json"
        )
        for (url in urls) {
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = FETCH_TIMEOUT_MS
                conn.readTimeout = FETCH_TIMEOUT_MS
                conn.setRequestProperty("User-Agent", "Vitaloop/1.0")
                if (conn.responseCode == 200) {
                    return conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                }
            } catch (e: Exception) {
                FileLogger.e(TAG, "拉取节假日数据失败: $url", e)
            }
        }
        return null
    }

    private fun parseAndLoad(year: Int, json: String): Boolean {
        return try {
            val root = gson.fromJson(json, JsonObject::class.java)
            if (root.get("year")?.asInt != year) return false
            val days = root.getAsJsonArray("days")
            synchronized(lock) {
                days.forEach { el ->
                    val day = el.asJsonObject
                    offDays[day.get("date").asString] = day.get("isOffDay").asBoolean
                }
            }
            true
        } catch (e: Exception) {
            FileLogger.e(TAG, "解析节假日数据失败", e)
            false
        }
    }

    private fun markLoaded(year: Int) {
        synchronized(lock) { loadedYears.add(year) }
    }
}
