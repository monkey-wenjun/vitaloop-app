package com.awen.running.huawei

import android.content.Context
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Linkage
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWorkoutOperatorStatusRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.GetWorkoutRealTimeInfoRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.LinkageEventReplyRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.WorkoutLiveCountRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.WorkoutLiveTotalsRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.WorkoutNotificationStatusAckRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.WorkoutReportSwitchRequest
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.WorkoutSetOperatorRequest
import com.awen.running.utils.CoordinateConverter
import com.awen.running.utils.FileLogger
import org.json.JSONObject

/**
 * 手表运动实时码表：只处理协议和事件，页面由 Flutter 负责。
 *
 * 旧版已经摸清两条路径：
 * - GT5 等新设备走 0x37 Linkage，Event 回执后 SamplePoint 每秒推一帧；
 * - 部分设备走 0x17 的 OperatorStatus + RealTimeInfo。
 * 两条都接，0x17 订阅被拒时再退回 0x07/0x08 的十秒拉取。
 */
class WorkoutLiveTracker(
    private val context: Context,
    private val support: IHuaweiSupport,
    private val emit: (JSONObject) -> Unit,
) {
    companion object {
        private const val TAG = "VitaloopWorkoutLive"
        private const val PREFS = "workout_realtime_prefs"
        private const val KEY_ENABLED = "realtime_report_enabled"
        private const val KEY_PUSH_UNSUPPORTED = "realtime_push_unsupported"
        private const val STATUS_POLL_INTERVAL_MS = 30_000L
        private const val PULL_INTERVAL_MS = 10_000L
        private const val SUBSCRIBE_RETRY_MS = 10_000L

        private val SPORT_TYPE_CANDIDATES = intArrayOf(-1, 3, 2, 5, 7, 134, 1, 4)
    }

    private data class Frame(
        val sportType: Int?,
        val speedKmh: Double?,
        val heartRate: Int?,
        val calorieKcal: Int?,
        val distanceM: Int?,
        val climb: Int?,
        val altitude: Int?,
        val startedAt: Long,
        val lastFrameAt: Long,
        val operatorType: Int?,
        val pulled: Boolean = false,
        val cadence: Int? = null,
        val power: Int? = null,
        val averageHeartRate: Int? = null,
        val maxHeartRate: Int? = null,
        val latitude: Double? = null,
        val longitude: Double? = null,
    )

    private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Volatile
    private var running = false

    @Volatile
    private var enabled = prefs().getBoolean(KEY_ENABLED, true)

    @Volatile
    private var status = ""

    @Volatile
    private var lastFrame: Frame? = null

    @Volatile
    private var sessionStartedAt = 0L

    @Volatile
    private var autoOpenSentAt = 0L

    @Volatile
    private var pendingAutoOpen = false

    @Volatile
    private var lastEndReason = ""

    private var statusThread: Thread? = null
    private var pullThread: Thread? = null

    @Volatile
    private var lastOperatorType: Int? = null

    @Volatile
    private var lastSportType = -1

    @Volatile
    private var realtimeStartedAt = 0L

    @Volatile
    private var lastLinkageAt = 0L

    private var linkageDuration = -1
    private var linkageHrSum = 0L
    private var linkageHrCount = 0
    private var linkageHrMax = 0

    @Volatile
    private var subscribeOk = false

    @Volatile
    private var pushUnsupported = prefs().getBoolean(KEY_PUSH_UNSUPPORTED, false)

    private var probeIndex = -1
    private var probeSportType = -1
    private var lastSubscribeSentAt = 0L
    private var lastHandshakeAt = 0L
    private var lastPollAt = 0L
    private var pulledNumber: Short = -1
    private var pulledDistanceM = -1
    private var pulledAt = 0L
    private var pulledLastFrameAt = 0L
    private var pulledCountValidUntil = 0L

    @Volatile
    private var pullInFlight = false

    fun isEnabled(): Boolean = enabled

    fun statusJson(): JSONObject = JSONObject()
        .put("enabled", enabled)
        .put("status", status)
        .put("pushUnsupported", pushUnsupported)
        .put("subscribed", subscribeOk)
        .put("active", lastFrame != null)

    fun snapshotJson(): String = lastFrame?.let { frameToJson(it, false).toString() } ?: ""

    fun setEnabled(value: Boolean): Boolean {
        enabled = value
        prefs().edit().putBoolean(KEY_ENABLED, value).apply()
        if (!value) {
            status = "已关闭手表推送"
            lastEndReason = "已关闭运动数据推送"
            emitEnd(lastEndReason)
            return value
        }
        status = "正在打开手表推送"
        sendReportSwitch(1, "开关打开")
        startPollThread()
        return value
    }

    fun onReady() {
        running = true
        if (!enabled) {
            status = "已关闭手表推送"
            return
        }
        sendReportSwitch(1, "连接就绪")
        startPollThread()
    }

    fun onDisconnected() {
        running = false
        statusThread?.interrupt()
        statusThread = null
        pullThread?.interrupt()
        pullThread = null
        status = "手表未连接"
    }

    fun onAsyncPacket(packet: HuaweiPacket) {
        if (!enabled) return
        val service = packet.serviceId.toInt() and 0xFF
        val command = packet.commandId.toInt() and 0xFF
        try {
            when (service) {
                Linkage.id.toInt() and 0xFF -> {
                    if (command in 1..3) handleLinkagePacket(packet, command)
                }
                Workout.id.toInt() and 0xFF -> {
                    if (command in intArrayOf(0x01, 0x02, 0x03, 0x04, 0x05, 0x12)) {
                        handleWorkoutRealtimePacket(packet, command)
                    }
                }
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "实时码表包处理失败 svc=$service cmd=$command", e)
        }
    }

    private fun startPollThread() {
        if (statusThread?.isAlive == true) return
        statusThread = Thread({
            while (running && enabled) {
                pollOperatorStatus("轮询")
                try {
                    Thread.sleep(STATUS_POLL_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "VitaloopWorkoutStatus").apply {
            isDaemon = true
            start()
        }
    }

    private fun startPullThread() {
        if (pullThread?.isAlive == true) return
        pullThread = Thread({
            while (running && enabled) {
                val operator = lastOperatorType
                if (operator == null || operator == 0) break
                pullLiveTotals()
                try {
                    Thread.sleep(PULL_INTERVAL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "VitaloopWorkoutPull").apply {
            isDaemon = true
            start()
        }
    }

    private fun sendReportSwitch(operatorType: Int, reason: String) {
        Thread({
            try {
                WorkoutReportSwitchRequest(support, operatorType.toByte()).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
                FileLogger.i(TAG, "运动数据推送使能 operator=$operatorType（$reason）")
            } catch (e: Exception) {
                status = "使能命令发送失败: ${e.message}"
                FileLogger.e(TAG, "运动数据推送使能失败", e)
            }
        }, "VitaloopWorkoutEnable").apply {
            isDaemon = true
            start()
        }
    }

    private fun pollOperatorStatus(reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastPollAt < 10_000L) return
        lastPollAt = now
        if (!running || !enabled) return
        try {
            GetWorkoutOperatorStatusRequest(support).let {
                it.setupTimeoutUntilNext(5_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "查询手表运动状态失败（$reason）", e)
        }
    }

    private fun handleLinkagePacket(packet: HuaweiPacket, command: Int) {
        val root = packet.tlv
        val src = stringTag(root, 0x01)
        val dst = stringTag(root, 0x02)
        when (command) {
            0x01 -> FileLogger.i(TAG, "联动配置 src=$src dst=$dst")
            0x02 -> {
                if (src != Linkage.SPORT_DEVICE_PACKAGE || dst != Linkage.SPORT_APP_PACKAGE) return
                val eventId = intTag(root, 0x03) ?: return
                val level: Byte = byteTag(root, 0x04) ?: 0
                val data = try {
                    root.getObject(0x05)
                } catch (_: Exception) {
                    null
                }
                var workoutType = -1
                var operation = -1
                when (eventId) {
                    Linkage.Event.LINKAGE_CONTROL -> {
                        workoutType = data?.let { intTag(it, 0x01) } ?: -1
                        operation = data?.let { intTag(it, 0x02) } ?: -1
                    }
                    Linkage.Event.SPORT_START -> {
                        workoutType = data?.let { beInt(it.getBytes(0x02)) } ?: -1
                        operation = 0
                    }
                    Linkage.Event.SPORT_PAUSE ->
                        workoutType = data?.let { beInt(it.getBytes(0x02)) } ?: -1
                }
                if (workoutType > 0) lastSportType = workoutType
                status = "联动通道已握手（workoutType=$workoutType operation=$operation）"
                when {
                    eventId == Linkage.Event.SPORT_START ->
                        notifyStarted("运动开始事件 workoutType=$workoutType")
                    eventId == Linkage.Event.SPORT_PAUSE ->
                        status = "手表已暂停"
                    operation == 1 -> notifyEnded("联动 stopLinkage", authoritative = true)
                    operation == 0 || operation == 2 ->
                        notifyStarted("联动请求 operation=$operation workoutType=$workoutType")
                }
                try {
                    LinkageEventReplyRequest(
                        support,
                        eventId,
                        level,
                        if (operation in 0..127) operation.toByte() else 0.toByte(),
                        0.toByte(),
                    ).doPerform()
                } catch (e: Exception) {
                    status = "联动回执发送失败: ${e.message}"
                    FileLogger.e(TAG, "联动回执发送失败", e)
                }
            }
            0x03 -> applyLinkageSamplePoints(packet)
        }
    }

    private fun collectLinkagePoints(
        tlv: HuaweiTLV,
        depth: Int,
        out: ArrayList<Pair<Int, ByteArray>>,
    ) {
        if (depth > 6) return
        var pendingId: Int? = null
        for (item in tlv.get()) {
            val tag = item.tag.toInt() and 0xFF
            when {
                tag == 0x08 -> pendingId = beInt(item.value)
                tag == 0x09 -> {
                    val id = pendingId
                    if (id != null) {
                        out.add(id to item.value)
                        pendingId = null
                    }
                }
                (tag and 0x80) != 0 -> {
                    try {
                        collectLinkagePoints(HuaweiTLV().parse(item.value), depth + 1, out)
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun applyLinkageSamplePoints(packet: HuaweiPacket) {
        val points = ArrayList<Pair<Int, ByteArray>>()
        collectLinkagePoints(packet.tlv, 0, points)
        if (points.isEmpty()) return

        var speed: Double? = null
        var distance: Int? = null
        var calories: Int? = null
        var heartRate: Int? = null
        var duration: Int? = null
        var cadence: Int? = null
        var power: Int? = null
        var operatorType: Int? = null
        var climb: Int? = null
        var altitude: Int? = null
        var latitude: Double? = null
        var longitude: Double? = null
        for ((id, raw) in points) {
            if (raw.size == 1 && raw[0].toInt() == 0xFF) continue
            when (id) {
                50004799 -> speed = beInt(raw)?.let { it / 100.0 }
                50004765 -> distance = beInt(raw)?.let { Math.round(it / 10.0).toInt() }
                50004829 -> calories = beInt(raw)?.let { Math.round(it / 1000.0).toInt() }
                50004838 -> heartRate = beInt(raw)
                50004396 -> duration = beInt(raw)
                50004254 -> cadence = beInt(raw)
                50004757 -> power = beInt(raw)
                50004770 -> operatorType = beInt(raw)
                50004395 -> climb = beInt(raw)?.let { Math.round(it / 10.0).toInt() }
                50004286 -> altitude = beInt(raw)?.let { Math.round(it / 10.0).toInt() }
                50004388 -> latitude = beDouble8(raw)
                50004935 -> longitude = beDouble8(raw)
            }
        }
        val now = System.currentTimeMillis()
        lastLinkageAt = now
        if (duration != null && duration < linkageDuration) {
            linkageHrSum = 0
            linkageHrCount = 0
            linkageHrMax = 0
            pendingAutoOpen = true
            lastEndReason = ""
        }
        if (duration != null) linkageDuration = duration
        if (heartRate != null && heartRate > 0) {
            linkageHrSum += heartRate
            linkageHrCount++
            if (heartRate > linkageHrMax) linkageHrMax = heartRate
        }
        val shifted = if (latitude != null && longitude != null &&
            CoordinateConverter.isPlottable(latitude, longitude)
        ) {
            CoordinateConverter.wgs84ToGcj02(latitude!!, longitude!!)
        } else {
            null
        }
        val previous = lastFrame
        val startedAt = when {
            duration != null && duration > 0 -> now - duration.toLong() * 1000L
            previous != null && previous.startedAt > 0 -> previous.startedAt
            else -> now
        }
        val averageHr = if (linkageHrCount > 0) (linkageHrSum / linkageHrCount).toInt() else null
        val maxHr = linkageHrMax.takeIf { it > 0 } ?: previous?.maxHeartRate
        val frame = Frame(
            sportType = lastSportType.takeIf { it > 0 } ?: previous?.sportType,
            speedKmh = speed ?: previous?.speedKmh,
            heartRate = heartRate ?: VitaloopWatchManager.latestHeartRate.takeIf { it > 0 },
            calorieKcal = calories ?: previous?.calorieKcal,
            distanceM = distance ?: previous?.distanceM,
            climb = climb ?: previous?.climb,
            altitude = altitude ?: previous?.altitude,
            startedAt = startedAt,
            lastFrameAt = now,
            operatorType = operatorType ?: previous?.operatorType,
            cadence = cadence ?: previous?.cadence,
            power = power ?: previous?.power,
            averageHeartRate = averageHr ?: previous?.averageHeartRate,
            maxHeartRate = maxHr,
            latitude = shifted?.first ?: previous?.latitude,
            longitude = shifted?.second ?: previous?.longitude,
        )
        lastFrame = frame
        if (sessionStartedAt == 0L) {
            notifyStarted("收到实时样本")
        } else {
            emitFrame()
        }

        if (operatorType == 4 || operatorType == 0) {
            notifyEnded("样本 operator_type=$operatorType")
        }
    }

    private fun handleWorkoutRealtimePacket(packet: HuaweiPacket, command: Int) {
        val tlvs = flattenWorkoutTlvs(packet.tlv, 0)
        fun intTag(tag: Int): Int? {
            for (tlv in tlvs) {
                try {
                    if (tlv.contains(tag)) return tlv.getAsInteger(tag)
                } catch (_: Exception) {
                }
            }
            return null
        }
        when (command) {
            0x01 -> status = "接管操控应答 code=${intTag(0x7F) ?: intTag(0x01)}"
            0x02 -> {
                val operator = intTag(0x02)
                val sport = intTag(0x03)
                onOperatorStatus(needAck = true, operatorType = operator, sportType = sport)
            }
            0x03 -> {
                val operator = intTag(0x03)
                val sport = intTag(0x04)
                onOperatorStatus(needAck = false, operatorType = operator, sportType = sport)
            }
            0x04 -> {
                val code = intTag(0x7F) ?: intTag(0x01)
                subscribeOk = code == 100000 || code == 0
                status = if (subscribeOk) {
                    "实时订阅已接受 sport=$probeSportType"
                } else {
                    "实时订阅被拒 sport=$probeSportType code=$code"
                }
            }
            0x12 -> {
                val code = intTag(0x7F) ?: intTag(0x01)
                status = if (code == 100000 || code == 0) {
                    "手表已确认开启运动数据推送"
                } else {
                    "推送使能应答 code=$code"
                }
            }
            0x05 -> {
                val now = System.currentTimeMillis()
                subscribeOk = true
                val previous = lastFrame
                if (previous == null || now - previous.lastFrameAt > 15_000L) {
                    realtimeStartedAt = now
                }
                val sport = intTag(0x02) ?: lastSportType.takeIf { it > 0 }
                if (sport != null) lastSportType = sport
                val frame = Frame(
                    sportType = sport,
                    speedKmh = intTag(0x03)?.let { it / 10.0 },
                    heartRate = intTag(0x04) ?: VitaloopWatchManager.latestHeartRate.takeIf { it > 0 },
                    calorieKcal = intTag(0x06),
                    distanceM = intTag(0x07),
                    climb = intTag(0x05),
                    altitude = intTag(0x08),
                    startedAt = realtimeStartedAt,
                    lastFrameAt = now,
                    operatorType = lastOperatorType,
                )
                lastFrame = frame
                if (sessionStartedAt == 0L) {
                    notifyStarted("收到 0x17 实时帧")
                } else {
                    emitFrame()
                }
            }
        }
    }

    private fun onOperatorStatus(needAck: Boolean, operatorType: Int?, sportType: Int?) {
        lastOperatorType = operatorType
        if (sportType != null && sportType > 0) {
            lastSportType = sportType
            if (!subscribeOk) probeIndex = -1
        }
        status = "运动状态 operator=$operatorType sport=$sportType"
        if (operatorType == null || operatorType == 0) {
            probeIndex = -1
            subscribeOk = false
            pulledNumber = -1
            pulledCountValidUntil = 0L
            pulledLastFrameAt = 0L
            return
        }
        try {
            if (needAck) {
                WorkoutNotificationStatusAckRequest(support, 0x01.toByte()).let {
                    it.setupTimeoutUntilNext(5_000)
                    it.doPerform()
                }
            }
            if ((sportType ?: 0) > 0) {
                notifyStarted("操作状态 sport=$sportType")
                handshake(sportType)
            }
            probeRealtimeSubscribe()
            pullLiveTotals()
            if (pushUnsupported) startPullThread()
        } catch (e: Exception) {
            status = "码表订阅失败: ${e.message}"
            FileLogger.e(TAG, "码表订阅失败", e)
        }
    }

    private fun handshake(sportType: Int?) {
        val now = System.currentTimeMillis()
        if (now - lastHandshakeAt < 300_000L) return
        lastHandshakeAt = now
        val sport = sportType ?: lastSportType.takeIf { it > 0 } ?: 0
        WorkoutSetOperatorRequest(
            support,
            1.toByte(),
            sport.toByte(),
            1.toByte(),
            (now / 1000).toInt(),
        ).let {
            it.setupTimeoutUntilNext(5_000)
            it.doPerform()
        }
        status = "已请求接管运动操控 sport=$sport"
    }

    private fun probeRealtimeSubscribe() {
        if (subscribeOk || pushUnsupported) return
        val now = System.currentTimeMillis()
        if (now - lastSubscribeSentAt < SUBSCRIBE_RETRY_MS) return
        probeIndex++
        if (probeIndex >= SPORT_TYPE_CANDIDATES.size) {
            markPushUnsupported("订阅候选全部被拒")
            return
        }
        val candidate = SPORT_TYPE_CANDIDATES[probeIndex]
        val sport = if (candidate < 0) lastSportType.takeIf { it > 0 } ?: 0 else candidate
        subscribeRealtime(sport)
    }

    private fun subscribeRealtime(sportType: Int) {
        val now = System.currentTimeMillis()
        if (now - lastSubscribeSentAt < SUBSCRIBE_RETRY_MS) return
        lastSubscribeSentAt = now
        probeSportType = sportType
        try {
            GetWorkoutRealTimeInfoRequest(support, sportType.toByte()).let {
                it.setupTimeoutUntilNext(5_000)
                it.doPerform()
            }
            status = "已订阅实时数据 sport=$sportType"
        } catch (e: Exception) {
            status = "实时订阅失败: ${e.message}"
            FileLogger.e(TAG, "实时订阅失败", e)
        }
    }

    private fun markPushUnsupported(reason: String) {
        if (pushUnsupported) return
        pushUnsupported = true
        prefs().edit().putBoolean(KEY_PUSH_UNSUPPORTED, true).apply()
        status = "不支持实时推送，已改为定时拉取"
        FileLogger.w(TAG, "码表改用拉取模式（$reason）")
        startPullThread()
    }

    private fun pullLiveTotals() {
        if (!pushUnsupported) return
        val now = System.currentTimeMillis()
        if (now - lastLinkageAt < 120_000L) return
        if (pullInFlight && now - pulledAt < 20_000L) return
        pullInFlight = true
        pulledAt = now
        if (pulledNumber >= 0 && now < pulledCountValidUntil) {
            requestPulledTotals(pulledNumber)
            return
        }
        val nowSec = (now / 1000).toInt()
        try {
            WorkoutLiveCountRequest(
                support,
                nowSec - 6 * 3600,
                nowSec + 3600,
                object : WorkoutLiveCountRequest.Listener {
                    override fun onWorkoutNumber(workoutNumber: Short) {
                        pulledCountValidUntil = System.currentTimeMillis() + 60_000L
                        requestPulledTotals(workoutNumber)
                    }

                    override fun onNoWorkoutRecord() {
                        pullInFlight = false
                    }
                },
            ).let {
                it.setupTimeoutUntilNext(5_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            pullInFlight = false
            FileLogger.e(TAG, "码表拉取失败（count）", e)
        }
    }

    private fun requestPulledTotals(workoutNumber: Short) {
        try {
            WorkoutLiveTotalsRequest(
                support,
                workoutNumber,
                object : WorkoutLiveTotalsRequest.Listener {
                    override fun onTotals(packet: Workout.WorkoutTotals.Response) {
                        applyPulledTotals(packet)
                    }
                },
            ).let {
                it.setupTimeoutUntilNext(5_000)
                it.doPerform()
            }
        } catch (e: Exception) {
            pullInFlight = false
            FileLogger.e(TAG, "码表拉取失败（totals）", e)
        }
    }

    private fun applyPulledTotals(packet: Workout.WorkoutTotals.Response) {
        pullInFlight = false
        val now = System.currentTimeMillis()
        val ended = packet.endTime > 0 && packet.endTime.toLong() * 1000L < now - 90_000L
        if (ended) {
            notifyEnded("拉取到运动已结束")
            return
        }
        val distance = packet.distance.takeIf { it >= 0 }
        val previousDistance = if (pulledNumber == packet.number) pulledDistanceM else -1
        val previousAt = pulledLastFrameAt
        pulledNumber = packet.number
        val speedKmh = if (distance != null && previousDistance >= 0 && previousAt > 0 &&
            distance >= previousDistance && now > previousAt
        ) {
            (distance - previousDistance) / 1000.0 / ((now - previousAt) / 3_600_000.0)
        } else {
            null
        }
        if (distance != null) pulledDistanceM = distance
        val previous = lastFrame
        val pulledMaxHr = packet.maxHeartRatePeak.toInt() and 0xFF
        lastFrame = Frame(
            sportType = packet.type.toInt() and 0xFF,
            speedKmh = speedKmh ?: previous?.speedKmh,
            heartRate = VitaloopWatchManager.latestHeartRate.takeIf { it > 0 } ?: previous?.heartRate,
            calorieKcal = packet.calories.takeIf { it >= 0 },
            distanceM = distance,
            climb = packet.elevationGain,
            altitude = packet.maxAltitude,
            startedAt = packet.startTime.toLong() * 1000L,
            lastFrameAt = now,
            operatorType = lastOperatorType,
            pulled = true,
            averageHeartRate = previous?.averageHeartRate,
            maxHeartRate = if (pulledMaxHr in 1..254) pulledMaxHr else previous?.maxHeartRate,
        )
        pulledLastFrameAt = now
        if (sessionStartedAt == 0L) {
            notifyStarted("收到拉取汇总")
        } else {
            emitFrame()
        }
    }

    private fun notifyStarted(reason: String) {
        val now = System.currentTimeMillis()
        sessionStartedAt = now
        lastEndReason = ""
        if (now - autoOpenSentAt >= 60_000L) {
            autoOpenSentAt = now
            pendingAutoOpen = true
        }
        FileLogger.i(TAG, "码表开始: $reason")
        emitFrame()
    }

    private fun notifyEnded(reason: String, authoritative: Boolean = false) {
        if (sessionStartedAt == 0L) return
        val now = System.currentTimeMillis()
        if (!authoritative && now - sessionStartedAt < 10_000L) return
        if (lastEndReason == reason) return
        lastEndReason = reason
        sessionStartedAt = 0L
        status = "运动已结束：$reason"
        emit(JSONObject()
            .put("t", "watch_live_end")
            .put("at", now)
            .put("reason", reason))
    }

    private fun emitEnd(reason: String) {
        emit(JSONObject()
            .put("t", "watch_live_end")
            .put("at", System.currentTimeMillis())
            .put("reason", reason))
    }

    private fun emitFrame() {
        val frame = lastFrame
        val autoOpen = pendingAutoOpen
        if (autoOpen) pendingAutoOpen = false
        val json = if (frame == null) {
            JSONObject()
                .put("t", "watch_live")
                .put("sport", lastSportType)
                .put("startedAt", sessionStartedAt)
                .put("lastFrameAt", System.currentTimeMillis())
        } else {
            frameToJson(frame, autoOpen)
        }
        if (autoOpen) json.put("autoOpen", true)
        emit(json)
    }

    private fun frameToJson(frame: Frame, autoOpen: Boolean): JSONObject {
        val json = JSONObject()
            .put("t", "watch_live")
            .put("startedAt", frame.startedAt)
            .put("lastFrameAt", frame.lastFrameAt)
            .put("pulled", frame.pulled)
            .put("autoOpen", autoOpen)
        frame.sportType?.let { json.put("sport", it) }
        frame.speedKmh?.let { json.put("speedKmh", it) }
        frame.heartRate?.let { json.put("heartRate", it) }
        frame.calorieKcal?.let { json.put("calories", it) }
        frame.distanceM?.let { json.put("distanceM", it) }
        frame.climb?.let { json.put("climb", it) }
        frame.altitude?.let { json.put("altitude", it) }
        frame.operatorType?.let { json.put("operator", it) }
        frame.cadence?.let { json.put("cadence", it) }
        frame.power?.let { json.put("power", it) }
        frame.averageHeartRate?.let { json.put("averageHeartRate", it) }
        frame.maxHeartRate?.let { json.put("maxHeartRate", it) }
        frame.latitude?.let {
            json.put("lat", it)
            json.put("lon", frame.longitude)
        }
        return json
    }

    private fun flattenWorkoutTlvs(tlv: HuaweiTLV, depth: Int): List<HuaweiTLV> {
        val out = ArrayList<HuaweiTLV>()
        out.add(tlv)
        if (depth < 3) {
            try {
                for (container in tlv.allContainerObjects) {
                    out.addAll(flattenWorkoutTlvs(container, depth + 1))
                }
            } catch (_: Exception) {
            }
        }
        return out
    }

    private fun stringTag(tlv: HuaweiTLV, tag: Int): String? = try {
        if (tlv.contains(tag)) String(tlv.getBytes(tag), Charsets.UTF_8) else null
    } catch (_: Exception) {
        null
    }

    private fun intTag(tlv: HuaweiTLV, tag: Int): Int? = try {
        if (tlv.contains(tag)) tlv.getAsInteger(tag) else null
    } catch (_: Exception) {
        null
    }

    private fun byteTag(tlv: HuaweiTLV, tag: Int): Byte? = try {
        if (tlv.contains(tag)) tlv.getByte(tag) else null
    } catch (_: Exception) {
        null
    }

    private fun beInt(bytes: ByteArray?): Int? {
        if (bytes == null || bytes.isEmpty()) return null
        var value = 0
        for (byte in bytes) value = (value shl 8) or (byte.toInt() and 0xFF)
        return value
    }

    private fun beDouble8(bytes: ByteArray?): Double? {
        if (bytes == null || bytes.size != 8) return null
        var bits = 0L
        for (byte in bytes) bits = (bits shl 8) or (byte.toLong() and 0xFF)
        val value = java.lang.Double.longBitsToDouble(bits)
        if (kotlin.math.abs(value) == 255.0 || value.isNaN() || value.isInfinite()) return null
        return value
    }
}
