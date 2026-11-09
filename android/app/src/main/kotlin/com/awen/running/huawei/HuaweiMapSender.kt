package com.awen.running.huawei

import com.awen.running.utils.FileLogger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiBaseP2PService.HuaweiP2PCallback
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PMapService

/**
 * 离线地图下发编排（官方 OfflineMapTransmitManager → DeviceSenderService）：
 * ping → 传输握手(cmd 0x04) → 地图文件（0x28 文件通道）→ 等手表解析完成帧(cmd 0x08)。
 *
 * 地图包是华为 map-drcn 云的私有矢量瓦片，本 App 不生成也不下载它，只原样转发
 * 用户自己拿到的文件。握手按“全新标准地图”给固定值：mapType=0、syncType=0、
 * downloadType=0、mapSize=文件实际 MB 数（官方就是按 originalSize 的 MB 数取整）。
 */
class HuaweiMapSender(private val service: HuaweiP2PMapService) {
    companion object {
        private const val TAG = "HuaweiMapSender"
        private const val HANDSHAKE_TIMEOUT_MS = 20_000L
        /** GT 5 经典蓝牙 RFCOMM 实测约 68 KB/s。 */
        private const val LINK_BYTES_PER_SEC = 68L * 1024
        private const val MIN_FILE_TRANSFER_TIMEOUT_MS = 5 * 60_000L
        private const val MAX_FILE_TRANSFER_TIMEOUT_MS = 3 * 60 * 60_000L
        private const val PARSE_ACK_TIMEOUT_MS = 120_000L

        private const val MAP_TYPE_STANDARD = 0
        private const val SYNC_TYPE_FULL = 0
        private const val DOWNLOAD_TYPE_MANUAL = 0
        private const val BYTES_PER_MEGABYTE = 1024 * 1024

        private val CMD_REMAIN = HuaweiP2PMapService.CMD_QUERY_REMAIN_SPACE
        private val CMD_LIST = HuaweiP2PMapService.CMD_QUERY_DOWNLOADED_MAP
        private val CMD_HANDSHAKE = HuaweiP2PMapService.CMD_TRANSMIT_HANDSHAKE
        private val CMD_FILE = HuaweiP2PMapService.KEY_FILE_TRANSFER
    }

    /** 只读探测：确认 mapkit 通道能不能通、手表剩余空间、表上已有地图。 */
    suspend fun probe(): Result<String> = withContext(Dispatchers.IO) {
        val remain = request(CMD_REMAIN) { callback -> service.queryRemainSpace(callback) }
            ?: return@withContext Result.failure(IllegalStateException("查询手表存储空间无响应（超时）"))
        val list = request(CMD_LIST) { callback -> service.queryDownloadedMaps(callback) }
            ?: return@withContext Result.failure(IllegalStateException("查询手表已下载地图无响应（超时）"))
        Result.success(
            "手表剩余空间原始值 ${remain.first}（按 KB 约 ${remain.first / 1024} MB）；" +
                "表上已有 ${list.first} 张地图"
        )
    }

    suspend fun pushMap(fileName: String, fileBytes: ByteArray): Result<String> =
        withContext(Dispatchers.IO) {
            val mapSizeMb = ((fileBytes.size + BYTES_PER_MEGABYTE - 1) / BYTES_PER_MEGABYTE)
                .coerceAtMost(65535)
            FileLogger.i(TAG, "地图握手: $fileName bytes=${fileBytes.size} mapSizeMb=$mapSizeMb")

            val handshake = request(CMD_HANDSHAKE) { callback ->
                service.sendTransmitHandshake(
                    mapSizeMb,
                    MAP_TYPE_STANDARD,
                    SYNC_TYPE_FULL,
                    DOWNLOAD_TYPE_MANUAL,
                    callback,
                )
            } ?: return@withContext Result.failure(IllegalStateException("地图握手无响应（超时）"))
            if (handshake.first != HuaweiP2PMapService.MAP_SUCCESS) {
                return@withContext Result.failure(
                    IllegalStateException("手表拒绝地图传输: ${handshakeError(handshake.first)}")
                )
            }

            val transfer = request(CMD_FILE, fileTransferTimeoutMs(fileBytes.size)) { callback ->
                service.pushMapFile(fileName, fileBytes, callback)
            } ?: return@withContext Result.failure(IllegalStateException("地图文件传输无响应（超时）"))
            if (transfer.first == HuaweiP2PMapService.RESULT_TRANSPORT_ERROR) {
                return@withContext Result.failure(
                    IllegalStateException("地图文件传输失败（通道未就绪或被其它传输占用）")
                )
            }

            val parsed = withTimeoutOrNull(PARSE_ACK_TIMEOUT_MS) {
                suspendCancellableCoroutine<Pair<Int, ByteArray?>> { cont ->
                    service.awaitParseAck(HuaweiP2PCallback { code, data ->
                        if (cont.isActive) cont.resumeWith(Result.success(code to data))
                    })
                }
            }
            when (parsed?.first) {
                null -> Result.failure(
                    IllegalStateException("地图文件已发送到手表，但手表未回解析完成帧，请在手表地图列表检查")
                )
                0 -> Result.success("地图已导入手表（$fileName，$mapSizeMb MB）")
                else -> Result.failure(IllegalStateException("手表解析地图失败 code=${parsed.first}"))
            }
        }

    private suspend fun request(
        key: Int,
        timeoutMs: Long = HANDSHAKE_TIMEOUT_MS,
        send: (HuaweiP2PCallback) -> Unit,
    ): Pair<Int, ByteArray?>? = withTimeoutOrNull(timeoutMs) {
        suspendCancellableCoroutine<Pair<Int, ByteArray?>> { cont ->
            send(HuaweiP2PCallback { code, data ->
                if (cont.isActive) cont.resumeWith(Result.success(code to data))
            })
        }
    }

    private fun fileTransferTimeoutMs(fileBytes: Int): Long =
        ((fileBytes.toLong() / LINK_BYTES_PER_SEC) * 2_000L)
            .coerceIn(MIN_FILE_TRANSFER_TIMEOUT_MS, MAX_FILE_TRANSFER_TIMEOUT_MS)

    private fun handshakeError(code: Int): String = when (code) {
        1 -> "手表存储空间不足"
        2 -> "手表上的地图已是最新，无需更新"
        3 -> "手表正在使用该地图"
        4 -> "手表处理地图失败"
        HuaweiP2PMapService.RESULT_TRANSPORT_ERROR -> "通道不可用（ping 失败或文件槽被占用）"
        else -> "未知回码 $code"
    }
}
