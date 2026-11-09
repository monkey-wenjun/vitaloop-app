package com.awen.running.bluetooth

import android.util.Log

/**
 * 蚂蚁阿福 × 沃莱体脂秤 Scale27 协议解析器
 *
 * 参考 Python 实现：https://github.com/Mzdyl/ant-afu-welland-scale
 * BLE 通知为 20 字节原始包，需要先组装成 frame，再按 packet_type 解码。
 */
class AfuScaleProtocol {

    companion object {
        private const val TAG = "AfuScaleProtocol"

        const val PACKET_WEIGHT = 213   // 0xD5
        const val PACKET_ADC = 214      // 0xD6
        const val PACKET_HISTORY = 216  // 0xD8
        const val PACKET_SETTING = 223  // 0xDF
    }

    private val packets = mutableListOf<ByteArray>()

    data class FeedResult(
        val status: String,
        val frame: ByteArray? = null,
        val events: List<Map<String, Any?>> = emptyList()
    )

    fun feed(data: ByteArray): FeedResult {
        packets.add(data.copyOf())
        val (status, frame) = assemble(packets)
        if (status in listOf("perfect", "error", "verify_error")) {
            packets.clear()
        }
        if (status != "perfect" || frame == null) {
            return FeedResult(status = status, frame = frame)
        }
        return FeedResult(status = status, frame = frame, events = decode(frame))
    }

    private fun assemble(packets: List<ByteArray>): Pair<String, ByteArray?> {
        if (packets.isEmpty()) return "imperfect" to null
        val first = packets[0]
        if (first.size < 20) return "imperfect" to null

        val seqOrFlags = first[1].toInt() and 0xFF
        if (seqOrFlags and 0x80 != 0) return "error" to null

        val body18 = first.copyOfRange(2, 20)
        val checksum = body18.take(17).sumOf { it.toInt() and 0xFF } and 0x1F
        val checksumByte = body18[17].toInt() and 0xFF
        val status = if (checksum == (checksumByte and 0x1F)) "perfect" else "verify_error"
        val packetType = body18[16].toInt() and 0xFF
        val groupIndex = (checksumByte and 0xE0) ushr 5

        if (packetType == PACKET_SETTING && body18[0].toInt() and 0xFF == 6) {
            if (packets.size != 5) return "imperfect" to null
            val combined = ByteArray(128) { 0 }
            var lastGroup = groupIndex
            for ((index, packet) in packets.withIndex()) {
                if (packet.size < 18) return "imperfect" to null
                val marker = packet[3].toInt() and 0xFF
                lastGroup = (marker and 0xF0) ushr 4
                if ((marker and 0x0F) != index) return "error" to null
                packet.copyInto(combined, index * 14, 4, 18)
            }
            val frame = ByteArray(72)
            frame[0] = packetType.toByte()
            frame[1] = seqOrFlags.toByte()
            frame[2] = 0
            frame[3] = 67
            frame[4] = 6
            frame[5] = lastGroup.toByte()
            combined.copyInto(frame, 6, 0, 64)
            frame[70] = groupIndex.toByte()
            return status to frame
        }

        val frame = ByteArray(20)
        frame[0] = packetType.toByte()
        frame[1] = seqOrFlags.toByte()
        frame[2] = 0
        frame[3] = 17
        body18.copyInto(frame, 4, 0, 16)
        frame[19] = groupIndex.toByte()
        return status to frame
    }

    private fun decode(frame: ByteArray): List<Map<String, Any?>> {
        if (frame.size < 4) return emptyList()
        val packetType = frame[0].toInt() and 0xFF
        val deviceType = frame[1].toInt() and 0xFF
        val length = u16(frame, 2)
        val payload = byteArrayOf(deviceType.toByte()) + frame.copyOfRange(4, 4 + length.coerceAtMost(frame.size - 4))

        val events = when (packetType) {
            PACKET_WEIGHT -> decodeWeight(payload)
            PACKET_ADC -> decodeAdc(payload)
            PACKET_HISTORY -> decodeHistory(payload)
            PACKET_SETTING -> decodeSetting(payload)
            else -> listOf(mapOf("kind" to "unknown", "payload" to payload.joinToString("") { "%02X".format(it.toInt() and 0xFF) }))
        }
        return events.map { event ->
            event + ("package_type" to packetType) + ("device_type" to deviceType)
        }
    }

    private fun decodeWeight(payload: ByteArray): List<Map<String, Any?>> {
        if (payload.size < 8) return emptyList()
        val encoded = u32(payload, 1)
        val mode = payload[5].toInt() and 0xFF
        val event = mutableMapOf<String, Any?>("kind" to "weight", "mode" to mode)

        if (mode == 1 && payload.size >= 9) {
            event["calibrationMode"] = payload[6].toInt() and 0xFF
            event["charging"] = getBit(payload[7].toInt(), 7) == 1
            event["battery"] = payload[7].toInt() and 0x7F
            event["over_weight"] = payload[8].toInt() and 0xFF
        } else if (mode == 2 && payload.size >= 11) {
            val bits = u32(payload, 6)
            event["support_funs"] = (0 until 32).filter { getBit(bits, it) == 1 }
            event["charging"] = getBit(payload[10].toInt(), 7) == 1
            event["battery"] = payload[10].toInt() and 0x7F
        }

        event.putAll(weightFields(encoded))
        event["alg_type"] = if (payload.size >= 2) payload[payload.size - 2].toInt() and 0xFF else 0
        event["unit"] = if (payload.isNotEmpty()) payload[payload.size - 1].toInt() and 0xFF else 0
        event["stable"] = event["state"] == 1
        return listOf(event)
    }

    private fun decodeAdc(payload: ByteArray): List<Map<String, Any?>> {
        if (payload.size < 5 || getBit(payload[0].toInt(), 7) == 1) return emptyList()
        val count = payload[1].toInt() and 0xFF
        var offset = 3
        val adcs = mutableListOf<Double>()
        repeat(count) {
            if (offset + 2 > payload.size) return emptyList()
            adcs.add(u16(payload, offset).toDouble())
            offset += 2
        }
        if (offset >= payload.size) return emptyList()
        val mode = payload[offset].toInt() and 0xFF
        offset += 1

        val event = mutableMapOf<String, Any?>("kind" to "adc", "mode" to mode, "adcs" to adcs)
        if (mode == 1 && offset + 4 <= payload.size) {
            event.putAll(weightFields(u32(payload, offset)))
        }
        if (event.containsKey("weight_kg")) {
            event["impendences"] = normalizeImpendences(adcs, event["weight_kg"] as? Double)
        }
        event["alg_type"] = if (payload.size >= 2) payload[payload.size - 2].toInt() and 0xFF else 0
        event["unit"] = if (payload.isNotEmpty()) payload[payload.size - 1].toInt() and 0xFF else 0
        return listOf(event)
    }

    private fun decodeHistory(payload: ByteArray): List<Map<String, Any?>> {
        // 历史记录解析与体重/ADC类似，当前仅做占位，需要时再扩展
        return listOf(mapOf("kind" to "history", "raw" to payload.joinToString("") { "%02X".format(it.toInt() and 0xFF) }))
    }

    private fun decodeSetting(payload: ByteArray): List<Map<String, Any?>> {
        if (payload.size < 2) return emptyList()
        val event = mutableMapOf<String, Any?>("kind" to "setting", "operate_type" to (payload[1].toInt() and 0xFF))
        if ((payload[1].toInt() and 0xFF) == 6 && payload.size >= 67) {
            event["signIndex"] = payload[2].toInt() and 0xFF
            event["sign"] = payload.copyOfRange(3, 67).joinToString("") { "%02X".format(it.toInt() and 0xFF) }
        }
        return listOf(event)
    }

    private fun weightFields(encoded: Int, overrides: Map<String, Int> = emptyMap()): Map<String, Any?> {
        val grams = encoded and 0x3FFFF
        val kgDivision = overrides["kg_division"] ?: ((encoded and 0x1C0000) ushr 18)
        val lbDivision = overrides["lb_division"] ?: ((encoded and 0xE00000) ushr 21)
        val precisionKg = if (kgDivision in 0..2) 2 else 1
        val precisionLb = if (lbDivision in 0..2) 2 else 1
        val weightLb = g2lbGeneral(grams, lbDivision, precisionLb)
        return mapOf(
            "has_temperature" to (getBit(encoded, 28) == 1),
            "precision_kg" to precisionKg,
            "precision_lb" to precisionLb,
            "weight_g" to grams,
            "kg_scale_division" to kgDivision,
            "lb_scale_division" to lbDivision,
            "weight_kg" to g2kgGeneral(grams, kgDivision, precisionKg),
            "weight_lb" to weightLb,
            "weight_st" to (weightLb / 14.0).toInt(),
            "weight_st_lb" to (weightLb - (weightLb / 14.0).toInt() * 14),
            "state" to getBit(encoded, 31),
            "dianji" to getBit(encoded, 24),
            "supportHr" to getBit(encoded, 25),
            "supportPh" to getBit(encoded, 26),
            "supportZx" to getBit(encoded, 27)
        )
    }

    private fun normalizeImpendences(adcs: List<Double>, weightKg: Double?): List<Double> {
        if (adcs.size == 5) {
            return listOf(adcs[4], adcs[0], adcs[1], adcs[2], adcs[3]).map { round(it, 2) }
        }
        val weight = weightKg ?: 0.0
        return adcs.map { value ->
            var adjusted = value
            if (adjusted >= 1500.0 && weight > 0.0) {
                adjusted = (((adjusted - 1000.0) + ((weight * 10.0) * -0.4)) / 0.6) / 10.0
            }
            round(adjusted, 2)
        }
    }

    private fun u16(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
    }

    private fun u32(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)
    }

    private fun getBit(value: Int, bit: Int): Int {
        return if (value and (1 shl bit) != 0) 1 else 0
    }

    private fun g2kgGeneral(grams: Int, division: Int, precision: Int): Double {
        return gunitGeneral(grams / 1000.0, division, precision)
    }

    private fun g2lbGeneral(grams: Int, division: Int, precision: Int): Double {
        return gunitGeneral(grams * 0.0022046, division, precision)
    }

    private fun gunitGeneral(value: Double, division: Int, precision: Int): Double {
        return when (division) {
            0 -> {
                val scaled = ((getInt(value * 1000.0) + 5) / 10.0).toInt()
                scaled / 100.0
            }
            1 -> {
                var raw = getInt(value * 1000.0)
                if (raw % 10 == 9) raw += 10
                var scaled = (raw / 10.0).toInt()
                if (scaled % 2 != 0) scaled += 1
                scaled / 100.0
            }
            2 -> {
                var raw = ((getInt(value * 1000.0) + 20) / 10.0).toInt()
                val scaled = if (raw % 10 >= 5) ((raw / 10) * 10) + 5 else (raw / 10) * 10
                scaled / 100.0
            }
            3 -> {
                val scaled = ((getInt(value * 100.0) + 5) / 10.0).toInt()
                scaled / 10.0
            }
            4 -> {
                var raw = getInt(value * 100.0)
                if (raw % 10 == 9) raw += 10
                var scaled = (raw / 10.0).toInt()
                if (scaled % 2 != 0) scaled += 1
                scaled / 10.0
            }
            else -> round(value, precision)
        }
    }

    private fun getInt(value: Double): Int {
        return if ((value.toInt() * 10) % 10 >= 9) value.toInt() + 1 else value.toInt()
    }

    private fun round(value: Double, precision: Int): Double {
        val factor = Math.pow(10.0, precision.toDouble())
        return kotlin.math.round(value * factor) / factor
    }
}
