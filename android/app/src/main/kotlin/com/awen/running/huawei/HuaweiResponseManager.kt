package com.awen.running.huawei

import android.util.Log
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests.Request
import java.util.Collections

/**
 * 华为协议响应分发（移植自 Gadgetbridge ResponseManager）
 * 负责把 Socket 读到的字节流组装成完整包，并分发给等待中的请求
 */
class HuaweiResponseManager(private val support: IHuaweiSupport) {

    private val handlers = Collections.synchronizedList(ArrayList<Request>())
    private var receivedPacket: HuaweiPacket? = null

    fun addHandler(handler: Request) {
        synchronized(handlers) { handlers.add(handler) }
    }

    fun removeHandler(handler: Request) {
        synchronized(handlers) { handlers.remove(handler) }
    }

    fun removeHandlers(handlersToRemove: List<Request>) {
        synchronized(handlers) { handlers.removeAll(handlersToRemove) }
    }

    /**
     * 断链时清空分发状态。
     *
     * 残留的等待者只按 serviceId/commandId 匹配，会把下一次连接的响应抢先处理掉：
     * 上一次连接失败的 GetHiChainRequest 还在列表里时，新连接的 HiChain 响应会被它接手，
     * 用旧的 seed/randSelf 算 tokenCheck，必然对不上（表现为"authkey 失效"），清了 authkey
     * 走首次配对又会因为密钥为空抛 `IllegalArgumentException: Empty key`。
     * 半包状态同理：断链时残留的 partial 字节会跟新连接的字节流拼在一起，解析必然错位。
     */
    fun reset() {
        synchronized(handlers) { handlers.clear() }
        receivedPacket = null
    }

    /**
     * 解析收到的数据；处理拼接包（left > 0 表示还有剩余字节）
     */
    fun handleData(data: ByteArray) {
        var chunk = data
        var left = 0
        do {
            if (left > 0) {
                chunk = chunk.copyOfRange(chunk.size - left, chunk.size)
            }
            try {
                receivedPacket = if (receivedPacket == null) {
                    HuaweiPacket(support.paramsProvider).parse(chunk)
                } else {
                    receivedPacket!!.parse(chunk)
                }
                left = receivedPacket!!.left
            } catch (e: HuaweiPacket.ParseException) {
                Log.e(TAG, "Packet parse exception", e)
                receivedPacket = null
                return
            }

            if (receivedPacket!!.complete) {
                var handler: Request? = null
                synchronized(handlers) {
                    for (req in handlers) {
                        if (req.handleResponse(receivedPacket!!)) {
                            handler = req
                            break
                        }
                    }
                }

                if (handler == null) {
                    Log.d(
                        TAG,
                        "Async response service=${Integer.toHexString(receivedPacket!!.serviceId.toInt() and 0xff)} " +
                            "command=${Integer.toHexString(receivedPacket!!.commandId.toInt() and 0xff)}"
                    )
                    // 异步包需要先解析 TLV（如 P2P 消息），否则字段为空
                    try {
                        receivedPacket!!.parseTlv()
                    } catch (e: HuaweiPacket.ParseException) {
                        Log.e(TAG, "Async packet parseTlv exception", e)
                    }
                    support.onAsyncPacket(receivedPacket!!)
                } else {
                    Log.d(
                        TAG,
                        "Handled by ${handler!!.javaClass.simpleName}"
                    )
                    if (handler!!.autoRemoveFromResponseHandler()) {
                        synchronized(handlers) { handlers.remove(handler) }
                    }
                    handler!!.handleResponse()
                }
                receivedPacket = null
            }
        } while (left > 0)
    }

    companion object {
        private const val TAG = "HuaweiResponseManager"
    }
}
