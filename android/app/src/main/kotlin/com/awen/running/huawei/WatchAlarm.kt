package com.awen.running.huawei

import nodomain.freeyourgadget.gadgetbridge.model.Alarm

/**
 * 手表闹钟。
 *
 * index=0 是智能唤醒，index=1..5 是普通事件闹钟；
 * repeatMask 使用 [Alarm] 的周重复位掩码（周一=1 ... 周日=64）。
 */
data class WatchAlarm(
    val index: Int,
    val isEnabled: Boolean,
    val hourOfDay: Int,
    val minuteOfHour: Int,
    val repeatMask: Int = 0,
    val label: String = "闹钟",
    val smartWakeupIntervalMinutes: Int? = null,
) : Alarm {
    override fun getPosition(): Int = index

    override fun getEnabled(): Boolean = isEnabled

    override fun getUnused(): Boolean = false

    override fun getSmartWakeup(): Boolean = index == 0

    override fun getSmartWakeupInterval(): Int? =
        if (index == 0) smartWakeupIntervalMinutes else null

    override fun getSnooze(): Boolean = false

    override fun getRepetition(): Int = repeatMask

    override fun isRepetitive(): Boolean = repeatMask != 0

    override fun getRepetition(dow: Int): Boolean = (repeatMask and dow) != 0

    override fun getHour(): Int = hourOfDay

    override fun getMinute(): Int = minuteOfHour

    override fun getTitle(): String = label

    override fun getDescription(): String = ""
}
