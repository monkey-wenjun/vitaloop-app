package com.awen.running.huawei

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.util.Log
import com.awen.running.utils.FileLogger
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiConstants
import java.io.IOException

/**
 * 华为手表经典蓝牙（BR/EDR）传输层
 * 通过 SDP 服务 UUID 建立 RFCOMM Socket，负责读写字节流
 */
class HuaweiBtTransport(private val device: BluetoothDevice) {

    private var socket: BluetoothSocket? = null
    private var output: java.io.OutputStream? = null
    private var running = false
    private var readerThread: Thread? = null

    /** 本端是否主动 close（区别"手表掐链路"和"我们自己关的")，排查连接风暴用 */
    @Volatile
    private var closing = false

    @Volatile
    var onData: ((ByteArray) -> Unit)? = null

    @Volatile
    var onDisconnected: ((Throwable?) -> Unit)? = null

    /** 返回 true 就放弃剩余重试：用户断开后没必要再把 3 次 60 秒的页超时跑完 */
    @Volatile
    var shouldAbort: (() -> Boolean)? = null

    /**
     * 连接手表（阻塞直到连接成功或抛异常）
     */
    @Throws(IOException::class)
    fun connect() {
        // 设备发现会拖慢经典蓝牙连接，先取消
        try {
            BluetoothAdapter.getDefaultAdapter()?.cancelDiscovery()
        } catch (e: Exception) {
            Log.w(TAG, "cancelDiscovery failed", e)
        }

        var lastError: IOException? = null
        for (attempt in 1..CONNECT_ATTEMPTS) {
            if (shouldAbort?.invoke() == true) throw IOException("已取消连接")
            try {
                val s = device.createRfcommSocketToServiceRecord(HuaweiConstants.UUID_SERVICE_HUAWEI_SDP)
                s.connect()
                socket = s
                output = s.outputStream
                running = true
                readerThread = Thread({ readLoop() }, "HuaweiReadThread").apply { start() }
                Log.i(TAG, "Connected to ${device.name ?: device.address} (attempt $attempt)")
                return
            } catch (e: IOException) {
                lastError = e
                Log.w(TAG, "Connect attempt $attempt failed: ${e.message}")
                try {
                    socket?.close()
                } catch (ignore: Exception) {
                    // 忽略关闭失败
                }
                socket = null
                if (attempt < CONNECT_ATTEMPTS) {
                    try {
                        Thread.sleep(CONNECT_RETRY_DELAY_MS)
                    } catch (ie: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                }
            }
        }
        throw lastError ?: IOException("connect failed")
    }

    private fun readLoop() {
        val buffer = ByteArray(1024)
        var lastError: Throwable? = null
        try {
            val input = socket?.inputStream ?: throw IOException("input stream is null")
            while (running) {
                val n = input.read(buffer)
                if (n < 0) break
                onData?.invoke(buffer.copyOf(n))
            }
        } catch (e: Exception) {
            lastError = e
            Log.e(TAG, "Read loop error", e)
        } finally {
            running = false
            val reason = when {
                closing -> "本地主动关闭"
                lastError != null -> "${lastError.javaClass.simpleName}: ${lastError.message}"
                else -> "对端关闭（读到 EOF，手表侧断开）"
            }
            FileLogger.w(TAG, "读线程结束: $reason")
            onDisconnected?.invoke(lastError)
        }
    }

    @Synchronized
    fun write(data: ByteArray) {
        output?.let {
            it.write(data)
            it.flush()
        }
    }

    fun close() {
        closing = true
        running = false
        try {
            socket?.close()
        } catch (e: IOException) {
            Log.w(TAG, "Error closing socket", e)
        }
        socket = null
    }

    companion object {
        private const val TAG = "HuaweiBtTransport"
        private const val CONNECT_ATTEMPTS = 3
        private const val CONNECT_RETRY_DELAY_MS = 2500L
    }
}
