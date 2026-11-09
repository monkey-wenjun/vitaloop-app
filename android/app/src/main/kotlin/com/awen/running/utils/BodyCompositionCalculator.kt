package com.awen.running.utils

import kotlin.math.max
import kotlin.math.min

/**
 * 基于 BIA（生物电阻抗）的人体成分估算
 *
 * 蚂蚁阿福 × 沃莱体脂秤通过 BLE 返回体重 + 阻抗/ADC，
 * 体脂率、肌肉率、水分等需要本地用经验公式估算。
 *
 * 参考实现：https://github.com/Mzdyl/ant-afu-welland-scale/blob/main/afu_welland_scale/bodycomp.py
 */
object BodyCompositionCalculator {

    data class BodyCompositionResult(
        val model: String,
        val baseModel: String,
        val resistanceOhm: Double?,
        val bodyFatPercent: Double,
        val fatMassKg: Double,
        val fatFreeMassKg: Double,
        val musclePercent: Double,
        val muscleMassKg: Double,
        val waterPercent: Double,
        val waterMassKg: Double,
        val proteinPercent: Double,
        val proteinMassKg: Double,
        val bonePercent: Double,
        val boneMassKg: Double,
        val skeletalMusclePercent: Double,
        val skeletalMuscleMassKg: Double,
        val subcutaneousFatPercent: Double,
        val subcutaneousFatMassKg: Double
    )

    fun estimate(
        weightKg: Double,
        heightCm: Double,
        age: Int,
        sex: String,
        impedances: List<Double>? = null
    ): BodyCompositionResult? {
        if (weightKg <= 0.0 || heightCm <= 0.0 || age <= 0) return null

        val resistance = firstResistance(impedances)
        val (baseBodyFat, model, ffm) = baseBodyFatPercent(
            weightKg = weightKg,
            heightCm = heightCm,
            age = age,
            sex = sex,
            resistanceOhm = resistance
        )

        val minFat = if (isMale(sex)) 3.0 else 8.0
        val bodyFatPercent = clamp(baseBodyFat, minFat, 60.0)
        val fatMass = pctMass(weightKg, bodyFatPercent)
        val fatFreeMass = weightKg - fatMass

        val bonePercent = if (isMale(sex)) 4.5 else 4.0
        val musclePercent = clamp(100.0 - bodyFatPercent - bonePercent, 20.0, 95.0)

        val leanPercent = 100.0 - bodyFatPercent
        val waterPercent = clamp(leanPercent * 0.70, 25.0, 80.0)
        val proteinPercent = clamp(leanPercent * 0.238, 5.0, 35.0)
        val skeletalMusclePercent = clamp(musclePercent * 0.527, 10.0, 70.0)
        val subcutaneousFatPercent = clamp(bodyFatPercent * 0.72, 1.0, bodyFatPercent)

        return BodyCompositionResult(
            model = model,
            baseModel = model,
            resistanceOhm = resistance?.let { round(it, 2) },
            bodyFatPercent = round(bodyFatPercent, 1),
            fatMassKg = round(fatMass, 1),
            fatFreeMassKg = round(fatFreeMass, 1),
            musclePercent = round(musclePercent, 1),
            muscleMassKg = round(pctMass(weightKg, musclePercent), 1),
            waterPercent = round(waterPercent, 1),
            waterMassKg = round(pctMass(weightKg, waterPercent), 1),
            proteinPercent = round(proteinPercent, 1),
            proteinMassKg = round(pctMass(weightKg, proteinPercent), 1),
            bonePercent = round(bonePercent, 1),
            boneMassKg = round(pctMass(weightKg, bonePercent), 1),
            skeletalMusclePercent = round(skeletalMusclePercent, 1),
            skeletalMuscleMassKg = round(pctMass(weightKg, skeletalMusclePercent), 1),
            subcutaneousFatPercent = round(subcutaneousFatPercent, 1),
            subcutaneousFatMassKg = round(pctMass(weightKg, subcutaneousFatPercent), 1)
        )
    }

    private fun firstResistance(impedances: List<Double>?): Double? {
        impedances?.forEach { value ->
            if (value in 100.0..1500.0) return value
        }
        return null
    }

    private fun baseBodyFatPercent(
        weightKg: Double,
        heightCm: Double,
        age: Int,
        sex: String,
        resistanceOhm: Double?
    ): Triple<Double, String, Double?> {
        if (resistanceOhm != null) {
            val (ffm, model) = segalFfm(weightKg, heightCm, age, sex, resistanceOhm)
            val clampedFfm = clamp(ffm, weightKg * 0.35, weightKg * 0.97)
            return Triple(100.0 * (weightKg - clampedFfm) / weightKg, model, clampedFfm)
        }

        val bodyFatPercent = deurenbergBodyFatPercent(weightKg, heightCm, age, sex)
        val ffm = weightKg * (1.0 - (bodyFatPercent / 100.0))
        return Triple(bodyFatPercent, "deurenberg_bmi_fallback", ffm)
    }

    private fun segalFfm(
        weightKg: Double,
        heightCm: Double,
        age: Int,
        sex: String,
        resistanceOhm: Double
    ): Pair<Double, String> {
        val heightSq = heightCm * heightCm
        if (isMale(sex)) {
            var ffm = 9.33285 + (0.00066360 * heightSq) - (0.02117 * resistanceOhm) +
                (0.62854 * weightKg) - (0.12380 * age)
            val bodyFatPercent = 100.0 * (weightKg - ffm) / weightKg
            if (bodyFatPercent < 20.0) {
                return ffm to "segal_3a_male_lt20"
            }
            ffm = 14.52435 + (0.00088580 * heightSq) - (0.02999 * resistanceOhm) +
                (0.42688 * weightKg) - (0.07002 * age)
            return ffm to "segal_3b_male_ge20"
        }

        var ffm = 10.43485 + (0.00064602 * heightSq) - (0.01397 * resistanceOhm) +
            (0.42087 * weightKg)
        val bodyFatPercent = 100.0 * (weightKg - ffm) / weightKg
        if (bodyFatPercent < 30.0) {
            return ffm to "segal_3c_female_lt30"
        }
        ffm = 9.37938 + (0.00091186 * heightSq) - (0.01466 * resistanceOhm) +
            (0.29990 * weightKg) - (0.07012 * age)
        return ffm to "segal_3d_female_ge30"
    }

    private fun deurenbergBodyFatPercent(weightKg: Double, heightCm: Double, age: Int, sex: String): Double {
        val bmi = weightKg / ((heightCm / 100.0) * (heightCm / 100.0))
        val sexValue = if (isMale(sex)) 1 else 0
        return (1.20 * bmi) + (0.23 * age) - (10.8 * sexValue) - 5.4
    }

    private fun isMale(sex: String): Boolean {
        return sex.trim().lowercase() in setOf("male", "m", "man", "男", "1")
    }

    private fun clamp(value: Double, low: Double, high: Double): Double {
        return max(low, min(high, value))
    }

    private fun pctMass(weightKg: Double, percent: Double): Double {
        return weightKg * percent / 100.0
    }

    private fun round(value: Double, precision: Int): Double {
        val factor = Math.pow(10.0, precision.toDouble())
        return kotlin.math.round(value * factor) / factor
    }
}
