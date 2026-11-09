package com.awen.running.data

import android.content.Context
import android.content.SharedPreferences

/**
 * 华为手表运动目标（步数、卡路里、燃脂时间、活动时长）
 *
 * 对应华为 FitnessData.MotionGoal 的四个目标位：
 * bit0=steps, bit1=calories, bit2=distance, bit3=duration
 */
data class ActivityGoals(
    val steps: Int = DEFAULT_STEPS,
    val calories: Int = DEFAULT_CALORIES,
    val fatBurnMinutes: Int = DEFAULT_FAT_BURN_MINUTES,
    val activeMinutes: Int = DEFAULT_ACTIVE_MINUTES
) {
    companion object {
        const val DEFAULT_STEPS = 10000
        const val DEFAULT_CALORIES = 0
        const val DEFAULT_FAT_BURN_MINUTES = 0
        const val DEFAULT_ACTIVE_MINUTES = 0

        private const val PREFS_NAME = "activity_goals"
        private const val KEY_STEPS = "steps"
        private const val KEY_CALORIES = "calories"
        private const val KEY_FAT_BURN = "fat_burn_minutes"
        private const val KEY_ACTIVE = "active_minutes"

        fun load(context: Context): ActivityGoals {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return ActivityGoals(
                steps = prefs.getInt(KEY_STEPS, DEFAULT_STEPS).coerceAtLeast(0),
                calories = prefs.getInt(KEY_CALORIES, DEFAULT_CALORIES).coerceAtLeast(0),
                fatBurnMinutes = prefs.getInt(KEY_FAT_BURN, DEFAULT_FAT_BURN_MINUTES).coerceAtLeast(0),
                activeMinutes = prefs.getInt(KEY_ACTIVE, DEFAULT_ACTIVE_MINUTES).coerceAtLeast(0)
            )
        }

        fun save(context: Context, goals: ActivityGoals) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putInt(KEY_STEPS, goals.steps)
                .putInt(KEY_CALORIES, goals.calories)
                .putInt(KEY_FAT_BURN, goals.fatBurnMinutes)
                .putInt(KEY_ACTIVE, goals.activeMinutes)
                .apply()
        }
    }

    /**
     * 计算 Huawei MotionGoal.Request 使用的 goalType bitmap
     */
    fun toGoalTypeBitmap(): Byte {
        var bitmap = 0x00.toByte()
        if (steps > 0) bitmap = (bitmap.toInt() or 0x01).toByte()
        if (calories > 0) bitmap = (bitmap.toInt() or 0x02).toByte()
        // 距离目标用 activeMinutes 映射（华为协议没有独立的 fatBurnMinutes，这里用时长）
        if (activeMinutes > 0) bitmap = (bitmap.toInt() or 0x08).toByte()
        return bitmap
    }
}
