package com.awen.running.bluetooth

import java.util.UUID

/**
 * DJI Osmo Action 3/4/5 / Pocket 3 BLE 控制协议（移植自 MIT 开源项目 datagutt/node-osmo）。
 *
 * 帧格式：
 *   [0x55] [总长-1] [0x04] [CRC8(头)] [target LE16] [id LE16] [type LE24] [payload] [CRC16(体) LE16]
 *
 * CRC8  : poly=0x31 init=0xEE xorout=0 inputReflected=true resultReflected=true（crc-full 同参数）
 * CRC16 : poly=0x1021 init=0x496C xorout=0 inputReflected=true resultReflected=true
 *
 * 直播流程（Action 5 Pro）：
 *   连接并订阅 fff3/fff4/fff5 → fff4 通知触发配对(PIN "love")
 *   → 停止推流清场 → 准备直播 → 下发 Wi-Fi 名/密码
 *   → 配置防抖(仅 OA4/OA5) → 下发 RTMP 地址+参数开播 → OA5 额外发确认帧真正开播
 */
object DjiOsmoProtocol {

    // ==================== BLE GATT 特征 ====================
    val UUID_FFF0: UUID = UUID.fromString("0000fff0-0000-1000-8000-00805f9b34fb")
    val UUID_FFF3: UUID = UUID.fromString("0000fff3-0000-1000-8000-00805f9b34fb")
    val UUID_FFF4: UUID = UUID.fromString("0000fff4-0000-1000-8000-00805f9b34fb")
    val UUID_FFF5: UUID = UUID.fromString("0000fff5-0000-1000-8000-00805f9b34fb")

    /** DJI Technology Co. Ltd 厂商 ID（广播 manufacturerData 前两字节 AA 08 的小端值） */
    const val DJI_MANUFACTURER_ID = 0x08AA

    // ==================== 命令常量（node-osmo 逆向结果） ====================
    const val TARGET_PAIR = 0x0702
    const val TARGET_WIFI = 0x0702
    const val TARGET_STREAM = 0x0802
    const val TARGET_CONFIGURE = 0x0102

    const val ID_PAIR = 0x8092
    const val ID_STOP_STREAM = 0xEAC8
    const val ID_PREPARE_LIVE = 0x8C12
    const val ID_SETUP_WIFI = 0x8C19
    const val ID_START_STREAM = 0x8C2C
    const val ID_CONFIGURE = 0x8C2D

    const val TYPE_PAIR = 0x450740
    const val TYPE_STOP_STREAM = 0x8E0240
    const val TYPE_PREPARE_LIVE = 0xE10240
    const val TYPE_SETUP_WIFI = 0x470740
    const val TYPE_START_STREAM = 0x780840
    const val TYPE_CONFIGURE = 0x8E0240

    /** 直播中电池上报的 message type（payload[20] = 电量百分比） */
    const val TYPE_BATTERY = 0x020D00

    /** 默认配对 PIN（node-osmo 固定值） */
    const val DEFAULT_PAIR_PIN = "love"

    // 分辨率字节
    const val RES_480P = 0x47
    const val RES_720P = 0x04
    const val RES_1080P = 0x0A

    // 帧率字节
    const val FPS_25 = 2
    const val FPS_30 = 3

    // 防抖模式字节
    const val STAB_OFF = 0
    const val STAB_ROCK_STEADY = 1
    const val STAB_HORIZON_STEADY = 2
    const val STAB_ROCK_STEADY_PLUS = 3
    const val STAB_HORIZON_BALANCING = 4

    data class DjiMessage(val target: Int, val id: Int, val type: Int, val payload: ByteArray)

    // ==================== CRC（crc-full 1.1.0 逐位等价移植，已用真实库对照验证） ====================

    private fun reflect(value: Int, width: Int): Int {
        var result = 0
        for (i in 0 until width) {
            if ((value and (1 shl i)) != 0) {
                result = result or (1 shl (width - 1 - i))
            }
        }
        return result
    }

    private fun makeTable(width: Int, poly: Int, mask: Int): IntArray {
        val table = IntArray(256)
        val msbMask = 1 shl (width - 1)
        for (dividend in 0 until 256) {
            var curr = (dividend shl (width - 8)) and mask
            repeat(8) {
                curr = if ((curr and msbMask) != 0) {
                    (curr shl 1) xor poly
                } else {
                    curr shl 1
                }
            }
            table[dividend] = curr and mask
        }
        return table
    }

    private fun crcCompute(
        width: Int,
        poly: Int,
        init: Int,
        xorout: Int,
        inputReflected: Boolean,
        resultReflected: Boolean,
        data: ByteArray
    ): Int {
        val mask = if (width == 8) 0xFF else 0xFFFF
        val table = makeTable(width, poly, mask)
        var crc = init
        for (b in data) {
            var curByte = b.toInt() and 0xFF
            if (inputReflected) curByte = reflect(curByte, 8)
            crc = (crc xor (curByte shl (width - 8))) and mask
            val pos = (crc shr (width - 8)) and 0xFF
            crc = (crc shl 8) and mask
            crc = (crc xor table[pos]) and mask
        }
        if (resultReflected) crc = reflect(crc, width)
        return (crc xor xorout) and mask
    }

    fun crc8(data: ByteArray): Int =
        crcCompute(8, 0x31, 0xEE, 0x00, inputReflected = true, resultReflected = true, data)

    fun crc16(data: ByteArray): Int =
        crcCompute(16, 0x1021, 0x496C, 0x0000, inputReflected = true, resultReflected = true, data)

    // ==================== 报文编解码 ====================

    fun encodeMessage(target: Int, id: Int, type: Int, payload: ByteArray): ByteArray {
        val header = byteArrayOf(0x55, (13 + payload.size).toByte(), 0x04)
        val out = ByteArray(header.size + 1 + 2 + 2 + 3 + payload.size + 2)
        var pos = 0
        header.forEach { out[pos++] = it }
        out[pos++] = crc8(header).toByte()
        out[pos++] = (target and 0xFF).toByte()
        out[pos++] = ((target shr 8) and 0xFF).toByte()
        out[pos++] = (id and 0xFF).toByte()
        out[pos++] = ((id shr 8) and 0xFF).toByte()
        out[pos++] = (type and 0xFF).toByte()
        out[pos++] = ((type shr 8) and 0xFF).toByte()
        out[pos++] = ((type shr 16) and 0xFF).toByte()
        payload.forEach { out[pos++] = it }
        val body = out.copyOfRange(0, pos)
        val crc = crc16(body)
        out[pos++] = (crc and 0xFF).toByte()
        out[pos++] = ((crc shr 8) and 0xFF).toByte()
        return out
    }

    /** 解析相机回包；校验失败返回 null。 */
    fun parseMessage(data: ByteArray): DjiMessage? {
        if (data.size < 13) return null
        if ((data[0].toInt() and 0xFF) != 0x55) return null
        val length = data[1].toInt() and 0xFF
        if (data.size != length) return null
        if ((data[2].toInt() and 0xFF) != 0x04) return null
        val headerCrc = data[3].toInt() and 0xFF
        if (headerCrc != crc8(data.copyOfRange(0, 3))) return null

        val target = (data[4].toInt() and 0xFF) or ((data[5].toInt() and 0xFF) shl 8)
        val id = (data[6].toInt() and 0xFF) or ((data[7].toInt() and 0xFF) shl 8)
        val type = (data[8].toInt() and 0xFF) or
            ((data[9].toInt() and 0xFF) shl 8) or
            ((data[10].toInt() and 0xFF) shl 16)
        val payload = data.copyOfRange(11, data.size - 2)
        val crc = (data[data.size - 2].toInt() and 0xFF) or
            ((data[data.size - 1].toInt() and 0xFF) shl 8)
        if (crc != crc16(data.copyOfRange(0, data.size - 2))) return null
        return DjiMessage(target, id, type, payload)
    }

    // ==================== Payload 构造 ====================

    /** 配对请求 payload：固定 33 字节 + [len(pin)] + pin。 */
    fun pairPayload(pin: String = DEFAULT_PAIR_PIN): ByteArray {
        val staticPart = byteArrayOf(
            0x20, 0x32, 0x38, 0x34, 0x61, 0x65, 0x35, 0x62, 0x38, 0x64, 0x37, 0x36,
            0x62, 0x33, 0x33, 0x37, 0x35, 0x61, 0x30, 0x34, 0x61, 0x36, 0x34, 0x31,
            0x37, 0x61, 0x64, 0x37, 0x31, 0x62, 0x65, 0x61, 0x33
        )
        val pinBytes = pin.toByteArray(Charsets.UTF_8)
        return staticPart + byteArrayOf(pinBytes.size.toByte()) + pinBytes
    }

    fun stopStreamingPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x1A, 0x00, 0x01, 0x02)

    fun preparingToLivestreamPayload(): ByteArray = byteArrayOf(0x1A)

    /** Wi-Fi 下发 payload：[len(ssid)] + ssid + [len(password)] + password。 */
    fun setupWifiPayload(ssid: String, password: String): ByteArray {
        val ssidBytes = ssid.toByteArray(Charsets.UTF_8)
        val passwordBytes = password.toByteArray(Charsets.UTF_8)
        return byteArrayOf(ssidBytes.size.toByte()) + ssidBytes +
            byteArrayOf(passwordBytes.size.toByte()) + passwordBytes
    }

    /** Action 5 Pro 防抖配置 payload。 */
    fun configurePayload(imageStabilization: Int): ByteArray =
        byteArrayOf(0x01, 0x01, 0x1A, 0x00, 0x01, imageStabilization.toByte())

    /** 开播 payload：分辨率/码率/帧率 + URL（[len][0] + url，长度需 < 256）。 */
    fun startStreamingPayload(
        rtmpUrl: String,
        resolutionByte: Int,
        fpsByte: Int,
        bitrateKbps: Int
    ): ByteArray {
        val urlBytes = rtmpUrl.toByteArray(Charsets.UTF_8)
        require(urlBytes.size < 256) { "RTMP URL 过长" }
        val payload = ByteArray(12 + 2 + urlBytes.size)
        var pos = 0
        payload[pos++] = 0x00
        payload[pos++] = 0x2A // Action 5 Pro 专用字节（OA4 为 0x2E）
        payload[pos++] = 0x00
        payload[pos++] = resolutionByte.toByte()
        payload[pos++] = (bitrateKbps and 0xFF).toByte()
        payload[pos++] = ((bitrateKbps shr 8) and 0xFF).toByte()
        payload[pos++] = 0x02
        payload[pos++] = 0x00
        payload[pos++] = fpsByte.toByte()
        payload[pos++] = 0x00
        payload[pos++] = 0x00
        payload[pos++] = 0x00
        payload[pos++] = urlBytes.size.toByte()
        payload[pos++] = 0x00
        urlBytes.forEach { payload[pos++] = it }
        return payload
    }

    /** OA5 确认开播 payload：与停止推流命令同帧，仅最后一位 0x02 → 0x01。 */
    fun confirmStartStreamingPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x1A, 0x00, 0x01, 0x01)

    /** 从广播 manufacturerData 识别机型（AA 08 + 型号两字节）。 */
    fun modelNameFromManufacturerData(data: ByteArray): String? {
        if (data.size < 4) return null
        val model = ((data[2].toInt() and 0xFF)) or ((data[3].toInt() and 0xFF) shl 8)
        return when (model) {
            0x0012 -> "Osmo Action 3"
            0x0014 -> "Osmo Action 4"
            0x0015 -> "Osmo Action 5 Pro"
            0x0020 -> "Osmo Pocket 3"
            else -> null
        }
    }
}
