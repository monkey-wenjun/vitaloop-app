package com.awen.running.huawei

import com.awen.running.utils.FileLogger
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.TrainingPlan
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.TrainingPlanProto
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiBaseP2PService.HuaweiP2PCallback
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PCoursePlanService
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 训练计划下发定义。Flutter 负责生成课表，Kotlin 只负责把它转换成
 * 手表协议认识的 PlanInfo / CourseStorageInfo。
 */
data class CourseSegment(
    val actionId: String,
    val durationSec: Int,
    val intensityType: Int = INTENSITY_NONE,
    val intensityZone: Int = 0,
) {
    companion object {
        const val RD_WARMUP = "RD001"
        const val RD_RUN = "RD002"
        const val RD_WALK = "RD003"
        const val RD_REST = "RD004"
        const val RD_COOLDOWN = "RD005"
        const val INTENSITY_NONE = 255
        const val INTENSITY_HR_ZONE = 17
    }
}

data class TrainingPlanCourse(
    val courseId: String,
    val courseName: String,
    val durationSec: Int,
    val measurementType: Int = MEASUREMENT_TYPE_DURATION,
    val courseType: Int = TrainingPlan.COURSE_TYPE_NEW_RUN_COURSE,
    val updateTimeSec: Long = System.currentTimeMillis() / 1000L,
    val difficult: Int = 1,
    val defineType: Int = 0,
    val segments: List<CourseSegment> = emptyList(),
    val actionIds: List<String> = listOf("base_action_1"),
    val exerciseVersion: String = "1",
) {
    companion object {
        const val MEASUREMENT_TYPE_DURATION = 1
    }
}

data class TrainingPlanDay(
    val dayStartEpochSec: Long,
    val isDayPunch: Int = 0,
    val courses: List<TrainingPlanCourse> = emptyList(),
)

data class TrainingPlanDefinition(
    val planId: String,
    val planName: String,
    val planStartTimeSec: Long,
    val planTotalDays: Int,
    val planTotalWeeks: Int,
    val currentWeekNum: Int,
    val currentWeekName: String,
    val currentWeekStartSec: Long,
    val currentWeekEndSec: Long,
    val punchTimeStampSec: Long = 0,
    val days: List<TrainingPlanDay>,
)

object TrainingPlanPayload {
    fun fromJson(raw: String): TrainingPlanDefinition {
        val obj = JSONObject(raw)
        val days = obj.optJSONArray("days") ?: throw IllegalArgumentException("训练计划缺少 days")
        val parsedDays = buildList {
            for (i in 0 until days.length()) {
                val day = days.getJSONObject(i)
                val coursesJson = day.optJSONArray("courses")
                val courses = buildList {
                    if (coursesJson != null) {
                        for (j in 0 until coursesJson.length()) {
                            add(parseCourse(coursesJson.getJSONObject(j)))
                        }
                    }
                }
                add(
                    TrainingPlanDay(
                        dayStartEpochSec = day.getLong("startSec"),
                        isDayPunch = day.optInt("isDayPunch", 0),
                        courses = courses,
                    )
                )
            }
        }
        return TrainingPlanDefinition(
            planId = obj.getString("planId"),
            planName = obj.getString("planName"),
            planStartTimeSec = obj.getLong("planStartSec"),
            planTotalDays = obj.optInt("planTotalDays", parsedDays.size),
            planTotalWeeks = obj.optInt("planTotalWeeks", 1).coerceAtLeast(1),
            currentWeekNum = obj.optInt("currentWeekNum", 1).coerceAtLeast(1),
            currentWeekName = obj.optString("currentWeekName", "第1周"),
            currentWeekStartSec = obj.getLong("currentWeekStartSec"),
            currentWeekEndSec = obj.getLong("currentWeekEndSec"),
            punchTimeStampSec = obj.optLong("punchSec", 0L),
            days = parsedDays,
        )
    }

    private fun parseCourse(obj: JSONObject): TrainingPlanCourse {
        val segmentsJson = obj.optJSONArray("segments")
        val segments = buildList {
            if (segmentsJson != null) {
                for (i in 0 until segmentsJson.length()) {
                    val segment = segmentsJson.getJSONObject(i)
                    add(
                        CourseSegment(
                            actionId = segment.getString("actionId"),
                            durationSec = segment.getInt("durationSec"),
                            intensityType = segment.optInt(
                                "intensityType",
                                CourseSegment.INTENSITY_NONE,
                            ),
                            intensityZone = segment.optInt("intensityZone", 0),
                        )
                    )
                }
            }
        }
        val actionIdsJson = obj.optJSONArray("actionIds")
        val actionIds = buildList {
            if (actionIdsJson != null) {
                for (i in 0 until actionIdsJson.length()) add(actionIdsJson.getString(i))
            }
        }.ifEmpty { listOf("base_action_1") }
        return TrainingPlanCourse(
            courseId = obj.getString("id"),
            courseName = obj.getString("name"),
            durationSec = obj.getInt("durationSec"),
            measurementType = obj.optInt(
                "measurementType",
                TrainingPlanCourse.MEASUREMENT_TYPE_DURATION,
            ),
            courseType = obj.optInt(
                "courseType",
                TrainingPlan.COURSE_TYPE_NEW_RUN_COURSE,
            ),
            updateTimeSec = obj.optLong("updateSec", System.currentTimeMillis() / 1000L),
            difficult = obj.optInt("difficult", 1),
            defineType = obj.optInt("defineType", 0),
            segments = segments,
            actionIds = actionIds,
            exerciseVersion = obj.optString("exerciseVersion", "1"),
        )
    }
}

/**
 * 训练计划下发编排（对齐旧版 PlanSendService）：
 * 握手 → 手表回 0=已同步 / 2=推全量 / 3=推骨架 → 推送计划文件 → 结果非 1 即成功。
 */
class TrainingPlanSender(private val service: HuaweiP2PCoursePlanService) {

    companion object {
        private const val TAG = "TrainingPlanSender"
        private const val RESPONSE_TIMEOUT_MS = 15_000L
        private const val LANGUAGE = "zh-CN"
    }

    fun pushPlan(plan: TrainingPlanDefinition): Result<String> {
        val nowSec = System.currentTimeMillis() / 1000L
        val punchSec = if (plan.punchTimeStampSec > 0) plan.punchTimeStampSec else nowSec
        FileLogger.i(
            TAG,
            "计划握手开始: id=${plan.planId} 周=${plan.currentWeekNum} " +
                "周起始=${plan.currentWeekStartSec} punch=$punchSec",
        )
        val handshake = request { callback ->
            service.sendHandshake(plan.planId, plan.currentWeekStartSec, punchSec, callback)
        } ?: return Result.failure(IllegalStateException("握手无响应（超时）"))

        return when (handshake) {
            TrainingPlan.HANDSHAKE_ALREADY_SYNCED ->
                Result.success("手表已是该计划，无需推送")
            TrainingPlan.HANDSHAKE_PUSH_FULL -> pushPlanFile(plan, withCourses = true)
            TrainingPlan.HANDSHAKE_PUSH_SKELETON -> pushPlanFile(plan, withCourses = false)
            else -> Result.failure(IllegalStateException("握手失败: result=$handshake"))
        }
    }

    fun finishPlan(planId: String, businessType: Int = TrainingPlan.BT_RUN_PLAN_FINISH): Result<String> {
        val result = request { callback ->
            service.sendFinishPlan(planId, businessType, callback)
        } ?: return Result.failure(IllegalStateException("完结指令无响应（超时）"))
        return if (result != 1) {
            Result.success("计划已完结 result=$result")
        } else {
            Result.failure(IllegalStateException("完结失败 result=1"))
        }
    }

    private fun pushPlanFile(
        plan: TrainingPlanDefinition,
        withCourses: Boolean,
    ): Result<String> {
        val planData = buildPlanInfo(plan)
        val courses = plan.days
            .flatMap { it.courses }
            .filter { it.courseType != TrainingPlan.COURSE_TYPE_RACE_DAY }
        val indexedCourses = if (withCourses) {
            courses.map { TrainingPlan.IndexedCourse(buildCourseFile(it), it.courseType) }
        } else {
            emptyList()
        }
        FileLogger.i(
            TAG,
            "推送计划文件: plan=${planData.size}B 课程=${indexedCourses.size} 份 带课程=$withCourses",
        )
        val result = request { callback ->
            service.pushPlanFile(
                TrainingPlan.BT_RUN_PLAN_INFO_FILE,
                planData,
                indexedCourses,
                callback,
            )
        } ?: return Result.failure(IllegalStateException("计划文件推送无响应（超时）"))
        return if (result != 1) {
            Result.success("计划推送成功 result=$result 课程=${indexedCourses.size} 份")
        } else {
            Result.failure(IllegalStateException("计划文件被拒 result=1"))
        }
    }

    private fun buildPlanInfo(plan: TrainingPlanDefinition): ByteArray {
        val zoneOffsetSec = ZoneId.systemDefault()
            .rules
            .getOffset(java.time.Instant.now())
            .totalSeconds
        val dayInfos = plan.days.map { day ->
            val outlines = day.courses
                .filter { it.courseType != TrainingPlan.COURSE_TYPE_RACE_DAY }
                .map { buildCourseOutLine(it) }
            TrainingPlanProto.buildDayPlanBasicInfo(
                day.dayStartEpochSec,
                day.isDayPunch,
                outlines,
            )
        }
        val exerciseTimes = plan.days.sumOf { day ->
            day.courses.count { it.courseType != TrainingPlan.COURSE_TYPE_RACE_DAY }
        }
        val punch = if (plan.punchTimeStampSec > 0) {
            plan.punchTimeStampSec
        } else {
            System.currentTimeMillis() / 1000L
        }
        return TrainingPlanProto.buildPlanInfo(
            plan.planId,
            plan.planName.take(30),
            LANGUAGE,
            punch,
            plan.planTotalDays,
            plan.planTotalWeeks,
            plan.planStartTimeSec,
            zoneOffsetSec,
            plan.currentWeekName,
            exerciseTimes,
            plan.days.size,
            plan.currentWeekNum,
            plan.currentWeekStartSec,
            plan.currentWeekEndSec,
            dayInfos,
        )
    }

    private fun buildCourseOutLine(course: TrainingPlanCourse): ByteArray =
        TrainingPlanProto.buildCourseOutLine(
            course.courseId,
            course.courseName,
            course.updateTimeSec,
            course.courseType,
            0,
        )

    private fun buildCourseFile(course: TrainingPlanCourse): ByteArray {
        val combines = if (course.segments.isNotEmpty()) {
            course.segments.map { segment ->
                TrainingPlanProto.buildCombineInfo(
                    1,
                    listOf(
                        TrainingPlanProto.buildActionInfo(
                            segment.actionId,
                            course.measurementType,
                            segment.durationSec,
                            segment.intensityType,
                            segment.intensityZone,
                            segment.intensityZone,
                        )
                    ),
                )
            }
        } else {
            val actions = course.actionIds.map { actionId ->
                TrainingPlanProto.buildActionInfo(actionId, 255, 0, 0, 0, 0)
            }
            listOf(TrainingPlanProto.buildCombineInfo(1, actions))
        }
        return TrainingPlanProto.buildCourseStorageInfo(
            course.courseId,
            course.courseName,
            course.measurementType,
            course.durationSec,
            course.exerciseVersion,
            course.difficult,
            TrainingPlanProto.USING_TYPE_IN_PLAN,
            course.updateTimeSec,
            course.defineType,
            course.courseType,
            combines.size,
            combines,
        )
    }

    private fun request(send: (HuaweiP2PCallback) -> Unit): Int? {
        val latch = CountDownLatch(1)
        val response = AtomicInteger(Integer.MIN_VALUE)
        return try {
            send(
                HuaweiP2PCallback { code, data ->
                    val result = parseResult(data) ?: code
                    response.set(result)
                    latch.countDown()
                }
            )
            if (latch.await(RESPONSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                val result = response.get()
                FileLogger.i(TAG, "响应: result=$result")
                if (result == Integer.MIN_VALUE) null else result
            } else {
                null
            }
        } catch (e: Exception) {
            FileLogger.e(TAG, "训练计划请求失败", e)
            null
        }
    }

    private fun parseResult(data: ByteArray?): Int? {
        if (data == null || data.size < TrainingPlan.HEADER_SIZE + 4) return null
        return ByteBuffer.wrap(data, TrainingPlan.HEADER_SIZE, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
    }
}
