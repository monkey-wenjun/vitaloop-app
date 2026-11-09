package com.awen.running.huawei

import android.content.Context
import com.awen.running.utils.FileLogger
import nodomain.freeyourgadget.gadgetbridge.util.CheckSums
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.Callable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/**
 * GPS 星历在线下载（移植自旧版 HuaweiEphemerisUpdater）
 *
 * 从用户配置的远程 URL 下载华为手表专用的 ephemeris.zip，存放到
 * [HuaweiEphemerisManager] 读取的位置（getExternalFilesDir/ephemeris.zip），
 * 下载后校验 zip 内必须包含 time 与 ephemeris_config.json。
 *
 * 与旧版的唯一区别：这里没有 kotlinx-coroutines，在途下载去重用
 * CompletableFuture + 单线程池实现，语义与原来的 Deferred 一致。
 *
 * 刷新策略：
 * - 源每整点 :30 重新生成一份，故本地文件超过 1 小时即视为需要刷新；
 * - 手表来要星历时不再长时间阻塞：本地有文件就先应答、后台补下载，
 *   只有本地没有文件时才阻塞等下载（短超时）；
 * - 手表已连接时每 10 分钟检查一次，尽量在手表开口前就把新文件备好。
 */
object HuaweiEphemerisUpdater {
    private const val TAG = "HuaweiEphemerisUpdater"
    private const val PREFS = "ephemeris_prefs"
    private const val KEY_URL = "ephemeris_url"

    /** 公开构建不内置星历源；需要在设置页配置。 */
    private const val DEFAULT_URL = ""
    private const val KEY_LAST_FETCH_AT = "ephemeris_last_fetch_at"

    /** AGNSS（RTCM）内容的 CRC16 与其未变起始时间，见 recordAgnssCrc */
    private const val KEY_AGNSS_CRC = "agnss_crc_last"
    private const val KEY_AGNSS_CRC_AT = "agnss_crc_since_at"

    /** GPS 纪元（1980-01-06 UTC）与一周毫秒数，用于还原 10bit 周 */
    private const val GPS_EPOCH_MILLIS = 315964800000L
    private const val GPS_WEEK_MILLIS = 604800000L
    private const val KEY_LAST_FETCH_TIME = "ephemeris_last_fetch_time"
    private const val KEY_LAST_GOOD_IP = "dns_last_good_ip"
    private const val KEY_LAST_GOOD_IP_AT = "dns_last_good_ip_at"
    private const val EPHEMERIS_FILE_NAME = "ephemeris.zip"

    /**
     * 星历文件超过该时长视为需要刷新。
     * 源每小时 :30 更新一次，取 1 小时可以让本地文件基本贴近最新，
     * 也避免 2 小时阈值经常正好卡在「刚过期、手表来要」的点上。
     */
    private const val MAX_AGE_MS = 60 * 60 * 1000L

    /**
     * AGNSS（RTCM 1019）数据本身超过该时长就强制重下。
     * zip 里的 time 只是服务器重打包时间：服务器内容卡住时它每小时都会变新，
     * 只看 time 会让手机一直拿旧星历、手表继续报「星历过期」。
     */
    private const val AGNSS_MAX_AGE_MS = 3 * 60 * 60 * 1000L

    /** 刚拉过但源还没更新（zip 内 time 未变）时的最短重试间隔，避免反复拉同一份文件 */
    private const val MIN_RETRY_INTERVAL_MS = 5 * 60 * 1000L

    /** 本地完全没有星历文件时，手表请求最多阻塞多久等下载 */
    private const val BLOCK_ON_MISSING_TIMEOUT_MS = 6_000L

    /**
     * 单个 PGNSS 条目的最小可信大小：生成端在「seed 覆盖不到的窗口」会产出 1008 B 空壳，
     * 这种条目不能当有效数据用（实测 QZS 正常也有 ~1.7KB）。
     */
    private const val MIN_PGNSS_ENTRY_BYTES = 1024L

    /** 系统解析与 DoH 竞速的最长等待 */
    private const val DNS_RACE_TIMEOUT_MS = 3_500L

    /** 内存解析结果有效期 */
    private const val DNS_CACHE_TTL_MS = 30 * 60 * 1000L

    /** 持久化的「最近一次成功 IP」有效期（仅解析全挂时兜底） */
    private const val DNS_LAST_GOOD_TTL_MS = 6 * 60 * 60 * 1000L

    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            // 自托管星历服务器为公网直连地址，不随系统全局 HTTP 代理
            // （如 VPN 本地代理）走 CONNECT 隧道，避免代理连不通导致下载卡住
            .proxy(Proxy.NO_PROXY)
            .dns(ephemerisDns)
            .build()
    }

    /** DoH 专用客户端（bootstrap 走 223.5.5.5/223.6.6.6，TLS 证书与域名匹配） */
    private val dohClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(4, TimeUnit.SECONDS)
            .readTimeout(4, TimeUnit.SECONDS)
            .proxy(Proxy.NO_PROXY)
            .dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    listOf(InetAddress.getByName("223.5.5.5"), InetAddress.getByName("223.6.6.6"))
            })
            .build()
    }

    /** 并行解析线程池（系统解析可能卡满 10 秒，必须放到后台线程） */
    private val dnsPool: ExecutorService = Executors.newFixedThreadPool(4) { runnable ->
        Thread(runnable, "ephemeris-dns").apply { isDaemon = true }
    }

    /** 下载串行执行，同一时刻只有一份 zip 在写盘 */
    private val downloadPool: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ephemeris-download").apply { isDaemon = true }
    }

    /**
     * 「要不要刷新」的检查线程：读 zip 不便宜，不能占用手表协议线程；
     * 也必须和 [downloadPool] 分开，否则在 downloadPool 里等自己排队的任务会死锁。
     */
    private val checkPool: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ephemeris-check").apply { isDaemon = true }
    }

    private val dnsCache = ConcurrentHashMap<String, Pair<List<InetAddress>, Long>>()

    @Volatile
    private var appContext: Context? = null

    private fun rememberContext(context: Context) {
        if (appContext == null) appContext = context.applicationContext
    }

    /**
     * 星历域名解析：先吃内存缓存，再让系统解析与 DoH 并行竞速取先成功者，
     * 两者都失败时退回最近一次成功解析的 IP。
     *
     * 旧版实测：移动网络下系统解析远程服务域名可能要 ~10 秒才超时，DoH 只要 ~0.4 秒。
     * 串行的「系统失败后再 DoH」会让手表白等 10 秒，甚至超过阻塞预算导致星历没送出去。
     *
     * 连接仍用 URL 里的域名做 SNI 与证书校验，缓存 IP 不降低安全性。
     */
    private val ephemerisDns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            cachedAddresses(hostname)?.let { return it }
            val raced = raceLookup(hostname)
            if (raced != null) {
                rememberAddresses(hostname, raced)
                return raced
            }
            lastKnownAddresses(hostname)?.let {
                FileLogger.w(TAG, "系统与 DoH 解析 $hostname 都失败，暂用最近成功 IP ${it.map { a -> a.hostAddress }}")
                return it
            }
            throw UnknownHostException("解析 $hostname 失败（系统解析与 DoH 兜底均不可用）")
        }
    }

    /** 系统解析与 DoH 并行竞速，返回先成功的结果 */
    private fun raceLookup(hostname: String): List<InetAddress>? {
        val tasks = listOf(
            dnsPool.submit(Callable { Dns.SYSTEM.lookup(hostname) }),
            dnsPool.submit(Callable { dohLookup(hostname) })
        )
        val deadline = System.nanoTime() + DNS_RACE_TIMEOUT_MS * 1_000_000
        var failure: Exception? = null
        while (true) {
            for (task in tasks) {
                if (!task.isDone) continue
                val addresses = try {
                    task.get()
                } catch (e: Exception) {
                    failure = e
                    null
                }
                if (!addresses.isNullOrEmpty()) {
                    FileLogger.i(TAG, "解析 $hostname → ${addresses.map { a -> a.hostAddress }}")
                    return addresses
                }
            }
            if (tasks.all { it.isDone } || System.nanoTime() > deadline) {
                FileLogger.w(TAG, "解析 $hostname 超时或失败：${failure?.message ?: "无可用结果"}")
                tasks.forEach { it.cancel(true) }
                return null
            }
            Thread.sleep(40)
        }
    }

    private fun cachedAddresses(hostname: String): List<InetAddress>? {
        val entry = dnsCache[hostname] ?: return null
        if (System.currentTimeMillis() - entry.second > DNS_CACHE_TTL_MS) {
            dnsCache.remove(hostname)
            return null
        }
        return entry.first
    }

    private fun rememberAddresses(hostname: String, addresses: List<InetAddress>) {
        dnsCache[hostname] = addresses to System.currentTimeMillis()
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.edit()
            ?.putString(KEY_LAST_GOOD_IP, addresses.joinToString(",") { it.hostAddress })
            ?.putLong(KEY_LAST_GOOD_IP_AT, System.currentTimeMillis())
            ?.apply()
    }

    /** 最近一次成功解析的 IP（进程重启后仍可用，仅在系统解析与 DoH 都失败时兜底） */
    private fun lastKnownAddresses(hostname: String): List<InetAddress>? {
        val prefs = appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE) ?: return null
        val savedAt = prefs.getLong(KEY_LAST_GOOD_IP_AT, 0L)
        if (savedAt == 0L || System.currentTimeMillis() - savedAt > DNS_LAST_GOOD_TTL_MS) return null
        return prefs.getString(KEY_LAST_GOOD_IP, "").orEmpty()
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .mapNotNull { runCatching { InetAddress.getByName(it) }.getOrNull() }
            .takeIf { it.isNotEmpty() }
    }

    /** 连接失败时清掉解析缓存，让下一次下载重新解析（服务器 IP 变更场景） */
    private fun clearDnsCache() {
        dnsCache.clear()
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.edit()
            ?.remove(KEY_LAST_GOOD_IP)
            ?.remove(KEY_LAST_GOOD_IP_AT)
            ?.apply()
    }

    /** 阿里公共 DNS JSON API（bootstrap 走 223.5.5.5/223.6.6.6，TLS 证书与域名匹配） */
    private fun dohLookup(hostname: String): List<InetAddress>? {
        return try {
            val request = Request.Builder()
                .url("https://dns.alidns.com/resolve?name=$hostname&type=A")
                .header("Accept", "application/dns-json")
                .build()
            dohClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val body = response.body?.string() ?: return null
                val answers = JSONObject(body).optJSONArray("Answer") ?: return null
                val ips = mutableListOf<InetAddress>()
                for (i in 0 until answers.length()) {
                    val data = answers.getJSONObject(i).optString("data")
                    // 过滤附加记录（如根域名 NS），只取 A 记录 IPv4
                    data.takeIf { it.matches(Regex("""\d{1,3}(\.\d{1,3}){3}""")) }
                        ?.let { ips.add(InetAddress.getByName(it)) }
                }
                FileLogger.i(TAG, "DoH 解析 $hostname → ${ips.map { it.hostAddress }}")
                ips
            }
        } catch (e: Exception) {
            FileLogger.w(TAG, "DoH 解析 $hostname 失败：${e.message}")
            null
        }
    }

    @Volatile
    private var downloadRunning = false

    @Volatile
    private var lastErrorMessage: String? = null

    /** 进行中的下载（复用：手表请求/连接就绪/手动按钮并发触发时只下载一次） */
    @Volatile
    private var inFlightDownload: CompletableFuture<Result<Long>>? = null

    /** 用户配置的星历下载地址 */
    fun getUrl(context: Context): String {
        rememberContext(context)
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_URL, "") ?: ""
        return stored.ifBlank { DEFAULT_URL }
    }

    /** 保存星历下载地址 */
    fun setUrl(context: Context, url: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_URL, url.trim())
            .apply()
    }

    /** 星历文件（HuaweiEphemerisManager 读取的位置） */
    fun ephemerisFile(context: Context): File =
        File(context.getExternalFilesDir(null), EPHEMERIS_FILE_NAME)

    /** 是否正在下载（用于 UI 与调用点去重） */
    fun isDownloading(): Boolean = downloadRunning

    /** 最近一次下载失败原因（成功后清空） */
    fun lastError(): String? = lastErrorMessage

    data class FileInfo(
        val exists: Boolean,
        val sizeBytes: Long,
        /** zip 内 time 文件记录的文件生成时间（毫秒），解析失败为 null */
        val fileTimeMillis: Long?,
        /**
         * AGNSS（RTCM 1019）里星历自身的时间（毫秒），解析失败为 null。
         * 这个才是「数据新旧」：time 只是服务器重打 zip 的时间，服务器完全可以
         * 每小时重打一份内容没变的 zip。
         */
        val agnssEpochMillis: Long? = null,
        /** AGNSS 文件的 CRC16，用来判断服务器内容有没有真的换过 */
        val agnssCrc16: Int? = null,
        /** 当前 CRC 已经持续多久没变（毫秒），null 表示还没记录 */
        val agnssUnchangedMs: Long? = null
    )

    /** 读取本地星历文件状态 */
    fun getFileInfo(context: Context): FileInfo {
        rememberContext(context)
        val file = ephemerisFile(context)
        if (!file.exists()) return FileInfo(false, 0, null)
        var agnssEpoch: Long? = null
        var agnssCrc: Int? = null
        val fileTime = try {
            ZipFile(file).use { zip ->
                val agnssEntry = zip.entries().asSequence()
                    .firstOrNull { it.name.endsWith("HW_AGNSS_RTCM_33") }
                if (agnssEntry != null) {
                    val bytes = zip.getInputStream(agnssEntry).use { it.readBytes() }
                    agnssCrc = CheckSums.getCRC16(bytes, 0)
                    agnssEpoch = parseAgnssDataTimeMillis(bytes)
                }
                val entry = zip.getEntry("time") ?: return@use null
                zip.getInputStream(entry).bufferedReader().readText().trim().toLongOrNull()
            }
        } catch (e: Exception) {
            null
        }
        return FileInfo(true, file.length(), fileTime, agnssEpoch, agnssCrc,
            recordAgnssCrc(context, agnssCrc))
    }

    /** 记录 AGNSS 内容（CRC）已经多久没变，用于提示「服务器一直没更新数据」。 */
    private fun recordAgnssCrc(context: Context, crc: Int?): Long? {
        if (crc == null) return null
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lastCrc = prefs.getInt(KEY_AGNSS_CRC, Int.MIN_VALUE)
        val now = System.currentTimeMillis()
        if (lastCrc != crc) {
            if (lastCrc != Int.MIN_VALUE) {
                FileLogger.i(TAG, "AGNSS 内容已更新: crc 0x${"%04x".format(lastCrc)} -> 0x${"%04x".format(crc)}")
            }
            prefs.edit().putInt(KEY_AGNSS_CRC, crc).putLong(KEY_AGNSS_CRC_AT, now).apply()
            return 0L
        }
        return now - prefs.getLong(KEY_AGNSS_CRC_AT, now)
    }

    /**
     * 从 RTCM 流里找出第一条 1019（GPS 星历），解出 toc 并换算成毫秒时间戳。
     * 位域与生成端 tools/gen_agnss_rtcm.py 一致（RTCM 3.3 1019）。
     */
    private fun parseAgnssDataTimeMillis(rtcm: ByteArray): Long? {
        var i = 0
        while (i + 6 <= rtcm.size) {
            if (rtcm[i] != 0xD3.toByte()) {
                i++
                continue
            }
            val len = ((rtcm[i + 1].toInt() and 0x03) shl 8) or (rtcm[i + 2].toInt() and 0xFF)
            if (i + 3 + len + 3 > rtcm.size) break
            val payload = rtcm.copyOfRange(i + 3, i + 3 + len)
            if (payload.size >= 9 && readBits(payload, 0, 12) == 1019) {
                val week = readBits(payload, 18, 10)
                val tocSeconds = readBits(payload, 56, 16) * 16
                return gpsToEpochMillis(week, tocSeconds)
            }
            i += 3 + len + 3
        }
        return null
    }

    /** MSB-first 读位域。 */
    private fun readBits(data: ByteArray, start: Int, count: Int): Int {
        var value = 0
        for (k in start until start + count) {
            val byte = data[k / 8].toInt()
            value = (value shl 1) or ((byte shr (7 - (k % 8))) and 1)
        }
        return value
    }

    /** 10bit GPS 周 + 周内秒 -> epoch 毫秒（10bit 周会回绕，按最近的周还原）。 */
    private fun gpsToEpochMillis(week10: Int, towSeconds: Int): Long {
        val nowWeek = ((System.currentTimeMillis() - GPS_EPOCH_MILLIS) / GPS_WEEK_MILLIS).toInt()
        var week = (nowWeek and 0x3FF.inv()) or week10
        if (week - nowWeek > 512) week -= 1024
        if (nowWeek - week > 512) week += 1024
        return GPS_EPOCH_MILLIS + week * GPS_WEEK_MILLIS + towSeconds * 1000L
    }

    /**
     * 本地是否已经有可用星历文件（只看能不能解析，不判新旧）。
     * 用于「先用手上的文件应答、后台再补新文件」的策略。
     */
    fun hasUsableFile(context: Context): Boolean = getFileInfo(context).fileTimeMillis != null

    /**
     * 是否需要刷新：已配置 URL 且本地文件缺失、格式无效或生成时间超过 [MAX_AGE_MS]。
     * 若刚拉过一次、源还没更新（zip 内 time 未变），在 [MIN_RETRY_INTERVAL_MS] 内不重复拉。
     */
    fun needsRefresh(context: Context): Boolean {
        if (getUrl(context).isBlank()) return false
        val info = getFileInfo(context)
        if (!info.exists) return true
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val fetchedAt = prefs.getLong(KEY_LAST_FETCH_AT, 0L)
        val fetchedTime = prefs.getLong(KEY_LAST_FETCH_TIME, 0L)
        fun justFetched(fileTime: Long) = fetchedTime == fileTime &&
            System.currentTimeMillis() - fetchedAt < MIN_RETRY_INTERVAL_MS
        // 本地 zip 被「空壳 PGNSS」污染（生成端在无数据窗口留下的 1008B 占位）→ 必须重新下载
        if (hasShellPgnss(ephemerisFile(context))) {
            // 但服务端那份没变就别再拉了，否则会 25 秒一轮白白重下同一份 64KB 文件
            val shellTime = info.fileTimeMillis
            if (shellTime != null && justFetched(shellTime)) {
                FileLogger.d(TAG, "本地 ephemeris.zip 含空壳 PGNSS，但刚拉过同一份（time=$shellTime），跳过重复下载")
                return false
            }
            FileLogger.w(TAG, "本地 ephemeris.zip 含空壳 PGNSS，强制重新下载")
            return true
        }
        val agnssAge = info.agnssEpochMillis?.let {
            System.currentTimeMillis() - it
        }
        if (agnssAge != null && agnssAge > AGNSS_MAX_AGE_MS) {
            if (justFetched(info.fileTimeMillis ?: 0L)) {
                FileLogger.d(
                    TAG,
                    "AGNSS 数据已 ${agnssAge / 3_600_000}h 未更新，但刚拉过同一份，稍后重试"
                )
                return false
            }
            FileLogger.w(TAG, "AGNSS 数据已 ${agnssAge / 3_600_000}h 未更新，强制重新下载")
            return true
        }
        val fileTime = info.fileTimeMillis ?: return true
        if (System.currentTimeMillis() - fileTime <= MAX_AGE_MS) return false
        return !justFetched(fileTime)
    }

    /**
     * 下载星历 zip 并校验内容，成功后原子替换到外部存储目录
     *
     * @return 成功时返回 zip 内 time 记录的文件生成时间（毫秒）
     */
    fun download(context: Context): Result<Long> {
        rememberContext(context)
        val first = downloadOnce(context)
        val error = first.exceptionOrNull()
        if (first.isSuccess) return first
        // 连接类失败可能是解析缓存里的 IP 已失效（服务器换 IP），清掉缓存再试一次
        if (error is IOException && !error.message.orEmpty().startsWith("下载失败 HTTP")) {
            FileLogger.w(TAG, "星历下载失败，清空 DNS 缓存后重试：${error.message}")
            clearDnsCache()
            val retry = downloadOnce(context)
            if (retry.isSuccess) return retry
            // 只下载、不在手机侧自己造星历：解码全部在服务端做。
            // 拿不到就用本地已有的那份，手表按旧窗口继续跑。
            FileLogger.w(TAG, "星历下载仍失败，沿用本地已有文件：${retry.exceptionOrNull()?.message}")
            return retry
        }
        FileLogger.w(TAG, "星历下载失败（HTTP 层），沿用本地已有文件：${error?.message}")
        return first
    }

    private fun downloadOnce(context: Context): Result<Long> {
        val url = getUrl(context)
        if (url.isBlank()) {
            return Result.failure(IllegalStateException("未配置星历下载地址"))
        }
        val target = ephemerisFile(context)
        target.parentFile?.mkdirs()
        // 临时文件必须和目标同目录（同一文件系统），否则 renameTo 会跨设备失败退化成
        // 复制，复制期间手表来要星历会读到半个文件或「文件不存在」
        val tmp = File(target.parentFile, "ephemeris_download.zip")
        try {
            val request = Request.Builder()
                .url(url)
                .header("User-Agent", "Vitaloop/1.0")
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    return Result.failure(IOException("下载失败 HTTP ${response.code}"))
                }
                val body = response.body ?: return Result.failure(IOException("下载内容为空"))
                body.byteStream().use { input ->
                    FileOutputStream(tmp).use { output -> input.copyTo(output) }
                }
            }

            // 校验 zip 内容（必须包含 time 与 ephemeris_config.json）
            val fileTime = validateEphemerisZip(tmp)
                ?: return Result.failure(IOException("星历文件格式不正确，缺少 time 或 ephemeris_config.json"))

            // 同目录 rename = 原子替换：读端要么看到旧文件，要么看到新文件，不会有空窗
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            FileLogger.i(TAG, "星历下载成功 time=$fileTime size=${target.length()}")
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putLong(KEY_LAST_FETCH_AT, System.currentTimeMillis())
                .putLong(KEY_LAST_FETCH_TIME, fileTime)
                .apply()
            return Result.success(fileTime)
        } catch (e: Exception) {
            tmp.delete()
            FileLogger.e(TAG, "星历下载失败", e)
            lastErrorMessage = e.message ?: e.javaClass.simpleName
            return Result.failure(e)
        }
    }

    /**
     * 按需下载（阻塞调用线程）：文件有效且未过期时直接返回当前 time，
     * 否则（或 force=true）重新下载。全局只允许一个下载任务。
     */
    fun downloadIfNeeded(context: Context, force: Boolean = false): Result<Long> {
        if (!force && !needsRefresh(context)) {
            return Result.success(getFileInfo(context).fileTimeMillis ?: -1L)
        }
        return await(startOrJoinDownload(context), 0)
    }

    /**
     * 后台刷新（不阻塞调用方）：本地文件偏旧、手表又来要时，
     * 先用现有文件应答，同时后台把新文件补下来。
     */
    fun refreshInBackground(context: Context) {
        rememberContext(context)
        val appCtx = context.applicationContext
        checkPool.execute {
            runCatching {
                if (needsRefresh(appCtx)) startOrJoinDownload(appCtx).get()
            }
        }
    }

    /**
     * 阻塞当前线程等待（或发起）一次星历下载，供手表请求星历的同步链路使用：
     * 只在本地完全没有可用文件时使用（有文件时应先应答再后台补），
     * 否则本次请求会被静默忽略，手表只能等下轮重试，AGNSS 补星历失效。
     *
     * @param timeoutMs 最长等待时间，超时返回 null（调用方按无新鲜文件处理）
     */
    fun downloadBlocking(context: Context, timeoutMs: Long = BLOCK_ON_MISSING_TIMEOUT_MS): Result<Long>? {
        rememberContext(context)
        if (getUrl(context).isBlank()) return null
        if (!needsRefresh(context)) {
            return Result.success(getFileInfo(context).fileTimeMillis ?: -1L)
        }
        val future = startOrJoinDownload(context)
        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            FileLogger.e(TAG, "等待星历下载超时或异常", e)
            null
        }
    }

    private fun await(future: CompletableFuture<Result<Long>>, timeoutMs: Long): Result<Long> =
        try {
            if (timeoutMs > 0) future.get(timeoutMs, TimeUnit.MILLISECONDS) else future.get()
        } catch (e: Exception) {
            FileLogger.e(TAG, "星历下载等待异常", e)
            Result.failure(e)
        }

    /** 发起新下载或复用在途下载（线程安全） */
    private fun startOrJoinDownload(context: Context): CompletableFuture<Result<Long>> {
        synchronized(this) {
            inFlightDownload?.takeIf { !it.isDone }?.let { return it }
            val appContext = context.applicationContext
            val future = CompletableFuture<Result<Long>>()
            inFlightDownload = future
            downloadRunning = true
            lastErrorMessage = null
            future.thenRun { downloadRunning = false }
            downloadPool.execute {
                val result = try {
                    download(appContext)
                } catch (e: Exception) {
                    Result.failure(e)
                }
                if (result.isFailure) lastErrorMessage = result.exceptionOrNull()?.message
                future.complete(result)
            }
            return future
        }
    }

    /** zip 里是否存在「空壳」PGNSS 条目（生成端在无数据窗口产出的 1008B 占位） */
    private fun hasShellPgnss(file: File): Boolean = try {
        ZipFile(file).use { zip ->
            zip.entries().asSequence().any { entry ->
                entry.name.substringAfterLast('/').startsWith("HW_PGNSS_") &&
                    entry.size < MIN_PGNSS_ENTRY_BYTES
            }
        }
    } catch (e: Exception) {
        false
    }

    /** 校验 zip 是否包含 time 与 ephemeris_config.json，返回文件生成时间（毫秒） */
    private fun validateEphemerisZip(file: File): Long? {
        return try {
            ZipFile(file).use { zip ->
                val timeEntry = zip.getEntry("time") ?: return null
                val configEntry = zip.getEntry("ephemeris_config.json") ?: return null
                val fileTime = zip.getInputStream(timeEntry)
                    .bufferedReader().readText().trim().toLongOrNull() ?: return null
                zip.getInputStream(configEntry).bufferedReader().readText()
                fileTime
            }
        } catch (e: Exception) {
            null
        }
    }
}
