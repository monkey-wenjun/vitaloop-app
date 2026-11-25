package com.awen.running.huawei

/**
 * 元环的真实用户资料，供协议层向手表上报 UserInfo（service 0x07 command 0x02）使用。
 *
 * 注意：手表「比赛指导/训练」里显示的年龄就来自这条命令；早先 Gadgetbridge 的
 * ActivityUser 是写死的（30 岁 / 175cm / 70kg），所以手表一直被刷成 30 岁。
 */
object VitaloopUserProfile {
    @Volatile var ready: Boolean = false

    @Volatile var age: Int = 0
    @Volatile var heightCm: Int = 0
    @Volatile var weightKg: Int = 0

    /** 1=男，2=女，3=未知（与 FitnessData.UserInfo 的枚举一致）。 */
    @Volatile var gender: Int = 3

    /** 生日编码：year << 16 | month << 8 | day；0 表示未知。 */
    @Volatile var birthday: Int = 0

    fun update(
        age: Int,
        heightCm: Int,
        weightKg: Int,
        gender: Int,
        birthday: Int,
    ) {
        this.age = age.coerceIn(0, 120)
        this.heightCm = heightCm.coerceIn(0, 250)
        this.weightKg = weightKg.coerceIn(0, 250)
        this.gender = if (gender in 1..3) gender else 3
        this.birthday = birthday
        this.ready = this.age > 0
    }
}
