package com.awen.running.huawei

import com.awen.running.route.HuaweiRouteEncoder
import com.awen.running.route.WatchRoute
import com.awen.running.utils.FileLogger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.TrainingPlan
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiBaseP2PService.HuaweiP2PCallback
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.p2p.HuaweiP2PCoursePlanService
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 路线下发编排（旧版 HuaweiRouteSender 的迁移）：
 * 握手(bt=5, TLV 路线名) → 手表回 state/pointMaxNum → 编码并发送 byte.bin(bt=6)。
 */
class HuaweiRouteSender(private val service: HuaweiP2PCoursePlanService) {
    companion object {
        private const val TAG = "HuaweiRouteSender"
        private const val RESPONSE_TIMEOUT_MS = 20_000L
        private const val WATCH_ACK_TIMEOUT_MS = 10_000L
        private const val MIN_POINT_LIMIT = 200
        private const val MAX_POINT_LIMIT = 4000
        private const val WATCH_RESULT_ACCEPTED = 1
        private const val TRANSPORT_DELIVERED = 2
        private const val TRANSPORT_ERROR = -1

        internal fun effectivePointLimit(pointMaxNum: Int): Int =
            pointMaxNum.coerceIn(MIN_POINT_LIMIT, MAX_POINT_LIMIT)
    }

    private data class Handshake(val state: Int, val pointMaxNum: Int)

    suspend fun pushRoute(route: WatchRoute, supportsRouteCp: Boolean = false): Result<String> =
        withContext(Dispatchers.IO) {
            FileLogger.i(TAG, "路线握手: ${route.name} points=${route.points.size}")
            val handshake = requestHandshake(route.name)
                ?: return@withContext Result.failure(IllegalStateException("路线握手无响应（超时）"))
            if (handshake.state != 1) {
                return@withContext Result.failure(IllegalStateException(handshakeError(handshake.state)))
            }

            val version = if (supportsRouteCp) HuaweiRouteEncoder.VERSION_V2 else HuaweiRouteEncoder.VERSION_V1
            val maxPoints = effectivePointLimit(handshake.pointMaxNum)
            val encoded = runCatching { HuaweiRouteEncoder.encode(route, maxPoints, version) }
                .getOrElse { return@withContext Result.failure(it) }
            val sentPointCount = HuaweiRouteEncoder.pointCount(encoded, version)
            FileLogger.i(TAG, "下发路线: v$version maxPoints=$maxPoints bytes=${encoded.size} points=$sentPointCount")

            val result = requestFileUpload { callback -> service.pushRouteFile(encoded, callback) }
                ?: return@withContext Result.failure(IllegalStateException("路线文件传输无响应（超时）"))
            when (result) {
                WATCH_RESULT_ACCEPTED ->
                    Result.success("路线已导入手表（$sentPointCount 个轨迹点）")
                TRANSPORT_DELIVERED -> {
                    if (awaitWatchRouteAck()) {
                        Result.success("路线已导入手表（$sentPointCount 个轨迹点）")
                    } else {
                        Result.failure(
                            IllegalStateException("文件已发送到手表，但手表未确认导入，请在手表路线列表检查")
                        )
                    }
                }
                TRANSPORT_ERROR -> Result.failure(IllegalStateException("路线文件传输失败（通道未就绪或被其它传输占用）"))
                else -> Result.failure(IllegalStateException("手表拒绝路线文件 result=$result"))
            }
        }

    private suspend fun awaitWatchRouteAck(): Boolean =
        withTimeoutOrNull(WATCH_ACK_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                service.awaitRouteAck(HuaweiP2PCallback { accepted, _ ->
                    if (cont.isActive) {
                        cont.resumeWith(Result.success(accepted == WATCH_RESULT_ACCEPTED))
                    }
                })
            }
        } == true

    private suspend fun requestHandshake(name: String): Handshake? =
        withTimeoutOrNull(RESPONSE_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                service.sendRouteHandshake(name, HuaweiP2PCallback { code, data ->
                    val state = parseFirstInt(data) ?: code
                    val pointMax = parseSecondInt(data) ?: 0
                    FileLogger.i(TAG, "路线握手响应: state=$state pointMaxNum=$pointMax")
                    cont.resumeWith(Result.success(Handshake(state, pointMax)))
                })
            }
        }

    private suspend fun requestFileUpload(send: (HuaweiP2PCallback) -> Unit): Int? =
        withTimeoutOrNull(RESPONSE_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                send(HuaweiP2PCallback { code, data ->
                    val result = parseFirstInt(data) ?: code
                    FileLogger.i(TAG, "路线文件响应: code=$code result=$result")
                    cont.resumeWith(Result.success(result))
                })
            }
        }

    private fun parseFirstInt(data: ByteArray?): Int? {
        if (data == null || data.size < TrainingPlan.HEADER_SIZE + 4) return null
        return ByteBuffer.wrap(data, TrainingPlan.HEADER_SIZE, 4)
            .order(ByteOrder.LITTLE_ENDIAN).int
    }

    private fun parseSecondInt(data: ByteArray?): Int? {
        if (data == null || data.size < TrainingPlan.HEADER_SIZE + 8) return null
        return ByteBuffer.wrap(data, TrainingPlan.HEADER_SIZE + 4, 4)
            .order(ByteOrder.LITTLE_ENDIAN).int
    }

    private fun handshakeError(state: Int): String = when (state) {
        2 -> "手表路线空间已满"
        3 -> "手表上已存在同名路线"
        4 -> "手表处理路线失败"
        5 -> "路线名称过长"
        else -> "路线握手失败: state=$state"
    }
}
