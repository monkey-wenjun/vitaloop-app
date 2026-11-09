package com.awen.running.service

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.awen.running.bluetooth.DjiOsmoProtocol
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * 大疆 Osmo Action 3/4/5 / Pocket 3 直播控制（BLE，协议移植自 node-osmo）。
 *
 * 职责：
 *  1. 扫描识别大疆相机（厂商数据 AA 08 + 型号）
 *  2. BLE 连接 + 配对（PIN "love"）+ 订阅 fff3/fff4/fff5 特征
 *  3. 下发 Wi-Fi 名/密码（相机自己连 Wi-Fi 推流，手机不参与推流）
 *  4. 下发 RTMP 地址 + 分辨率/帧率/码率，启动/停止直播
 *  5. 直播中解析电量上报
 *
 * 状态机对应 node-osmo device.ts：配对 → 停止推流清场 → 准备直播 → 下 Wi-Fi
 * → 配置防抖(OA5) → 开播(start + confirm) → 直播中。
 */
object DjiActionManager {

    private const val TAG = "DjiAction"

    enum class DjiState {
        IDLE,          // 空闲
        SCANNING,      // 搜索相机
        CONNECTING,    // BLE 连接/订阅特征中
        CHECKING_PAIRED, // 等待配对响应
        PAIRING,       // 新配对中
        CLEANING_UP,   // 停止推流清场
        PREPARING,     // 准备直播
        SETTING_WIFI,  // 下发 Wi-Fi
        CONFIGURING,   // 配置防抖
        STARTING,      // 启动直播
        STREAMING,     // 直播中
        STOPPING,      // 停止直播
        PAIRED         // 已连接且可开播
    }

    data class DjiCamera(val device: BluetoothDevice, val modelName: String)

    // ==================== 对外状态 ====================

    private val _state = MutableStateFlow(DjiState.IDLE)
    val state: StateFlow<DjiState> = _state.asStateFlow()

    private val _cameras = MutableStateFlow<List<DjiCamera>>(emptyList())
    val cameras: StateFlow<List<DjiCamera>> = _cameras.asStateFlow()

    private val _connectedCamera = MutableStateFlow<DjiCamera?>(null)
    val connectedCamera: StateFlow<DjiCamera?> = _connectedCamera.asStateFlow()

    private val _battery = MutableStateFlow(0)
    val battery: StateFlow<Int> = _battery.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    val isStreaming: Boolean
        get() = _state.value == DjiState.STREAMING

    val isScanning: Boolean
        get() = _state.value == DjiState.SCANNING

    // ==================== 内部状态 ====================

    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var fff3: BluetoothGattCharacteristic? = null
    private var fff4: BluetoothGattCharacteristic? = null

    private var pendingSsid: String? = null
    private var pendingPassword: String? = null
    private var pendingRtmpUrl: String? = null
    private var isAction5Pro = false

    // GATT 操作串行队列：订阅 CCCD / 写 fff3 / 读 fff4 全部串行执行，
    // 避免 Android BLE 并发在途操作导致命令丢失
    private sealed class GattOp {
        class EnableNotify(val characteristic: BluetoothGattCharacteristic) : GattOp()
        class Write(val value: ByteArray) : GattOp()
        class ReadFff4 : GattOp()
    }
    private val opQueue = ArrayDeque<GattOp>()
    private var opInFlight = false
    private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private var mtuRequested = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private var flowWatchdog: Runnable? = null
    private var stopWatchdog: Runnable? = null

    // ==================== 扫描 ====================

    fun startScan(context: Context) {
        if (!hasBlePermissions(context)) {
            _errorMessage.value = "缺少蓝牙权限，无法搜索大疆相机"
            return
        }
        if (_state.value != DjiState.IDLE && _state.value != DjiState.SCANNING) {
            _errorMessage.value = "当前状态无法搜索相机"
            return
        }
        stopScanInternal()
        val adapter = bluetoothAdapter(context) ?: run {
            _errorMessage.value = "蓝牙不可用"
            return
        }
        val scanner = adapter.bluetoothLeScanner ?: run {
            _errorMessage.value = "BLE 扫描不可用"
            return
        }
        _state.value = DjiState.SCANNING
        _cameras.value = emptyList()
        _errorMessage.value = null
        try {
            @SuppressLint("MissingPermission")
            scanner.startScan(scanCallback)
        } catch (e: Exception) {
            _errorMessage.value = "启动扫描失败: ${e.message}"
            _state.value = DjiState.IDLE
        }
    }

    fun stopScan() {
        if (_state.value == DjiState.SCANNING) {
            _state.value = DjiState.IDLE
        }
        stopScanInternal()
    }

    /**
     * 已配对的大疆设备（名称含 Osmo/Action/DJI），无需等待扫描即可直接连接。
     * 有些相机会被手机系统蓝牙/DJI Mimo 占用连接而停止广播，此时只能从这里连。
     */
    fun bondedDjiCameras(context: Context): List<DjiCamera> {
        val adapter = bluetoothAdapter(context) ?: return emptyList()
        val result = mutableListOf<DjiCamera>()
        try {
            @SuppressLint("MissingPermission")
            adapter.bondedDevices.forEach { device ->
                val name = device.name ?: return@forEach
                if (name.contains("osmo", ignoreCase = true) ||
                    name.contains("action", ignoreCase = true) ||
                    name.contains("dji", ignoreCase = true) ||
                    name.contains("pocket", ignoreCase = true)
                ) {
                    result.add(DjiCamera(device, modelNameFromDeviceName(name)))
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "读取已配对设备失败: ${e.message}")
        }
        return result
    }

    private fun stopScanInternal() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner != null) {
            try {
                @SuppressLint("MissingPermission")
                scanner.stopScan(scanCallback)
            } catch (e: Exception) {
                // 忽略
            }
        }
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val record = result.scanRecord ?: return
            val mfg = record.getManufacturerSpecificData(DjiOsmoProtocol.DJI_MANUFACTURER_ID) ?: return
            val modelName = DjiOsmoProtocol.modelNameFromManufacturerData(mfg)
                ?: (result.device.name?.let { modelNameFromDeviceName(it) } ?: "大疆相机")
            val camera = DjiCamera(result.device, modelName)
            val current = _cameras.value
            if (current.none { it.device.address == camera.device.address }) {
                _cameras.value = current + camera
                Log.i(TAG, "发现大疆相机: ${camera.device.name ?: camera.device.address} ($modelName)")
            }
        }

        override fun onScanFailed(errorCode: Int) {
            _errorMessage.value = "扫描失败（错误码 $errorCode），请重试"
            _state.value = DjiState.IDLE
        }
    }

    // ==================== 连接 / 配对 ====================

    @SuppressLint("MissingPermission")
    fun connect(context: Context, device: BluetoothDevice, modelName: String) {
        if (_state.value == DjiState.CONNECTING || _state.value == DjiState.PAIRED) {
            return
        }
        if (!hasBlePermissions(context)) {
            _errorMessage.value = "缺少蓝牙权限"
            return
        }
        cleanupGatt()
        _errorMessage.value = null
        _battery.value = 0
        isAction5Pro = modelName.contains("5") ||
            device.name?.contains("5", ignoreCase = true) == true
        _connectedCamera.value = DjiCamera(device, modelName)
        _state.value = DjiState.CONNECTING
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            device.connectGatt(context, false, gattCallback)
        }
    }

    /** 断开相机 BLE 连接（直播中先发停止命令）。 */
    fun disconnect() {
        if (_state.value == DjiState.STREAMING) {
            stopLiveStream()
            return
        }
        cleanupGatt()
        _connectedCamera.value = null
        _state.value = DjiState.IDLE
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail("连接失败（status=$status）")
                    return
                }
                Log.i(TAG, "BLE 已连接，协商 MTU…")
                mtuRequested = false
                // 大疆消息最长约 185+ 字节，默认 MTU 23 会把长通知截断成 20 字节导致解析失败
                val mtuOk = try {
                    gatt.requestMtu(512)
                } catch (e: Exception) {
                    false
                }
                if (mtuOk) {
                    mtuRequested = true
                } else {
                    discoverServicesSafely(gatt)
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.w(TAG, "BLE 断开 status=$status state=${_state.value}")
                val wasStreaming = _state.value == DjiState.STREAMING
                val wasActive = _state.value != DjiState.IDLE
                cleanupGatt()
                _connectedCamera.value = null
                _state.value = DjiState.IDLE
                if (wasStreaming) {
                    _errorMessage.value = "相机 BLE 连接已断开；若相机 Wi-Fi 正常，直播可能仍在继续（请在相机上确认）"
                } else if (status != 0 && wasActive) {
                    _errorMessage.value = "相机连接已断开（status=$status）"
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("服务发现失败（status=$status）")
                return
            }
            val f3 = findCharacteristic(gatt, DjiOsmoProtocol.UUID_FFF3)
            val f4 = findCharacteristic(gatt, DjiOsmoProtocol.UUID_FFF4)
            if (f3 == null || f4 == null) {
                fail("未找到 DJI 控制特征；请确认相机已开机，且 DJI Mimo 未占用连接")
                return
            }
            fff3 = f3
            fff4 = f4
            enqueueOp(GattOp.EnableNotify(f3))
            enqueueOp(GattOp.EnableNotify(f4))
            findCharacteristic(gatt, DjiOsmoProtocol.UUID_FFF5)?.let {
                enqueueOp(GattOp.EnableNotify(it))
            }
            enqueueOp(GattOp.ReadFff4())
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            handleCharacteristicData(characteristic, value)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            @Suppress("DEPRECATION")
            handleCharacteristicData(characteristic, characteristic.value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            completeOp()
            // 读取 fff4 同样视为配对触发（noble 中订阅后 read 的兼容处理）
            if (status == BluetoothGatt.GATT_SUCCESS && characteristic.uuid == DjiOsmoProtocol.UUID_FFF4) {
                @Suppress("DEPRECATION")
                handleCharacteristicData(characteristic, characteristic.value)
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            completeOp()
            if (status == BluetoothGatt.GATT_SUCCESS && characteristic.uuid == DjiOsmoProtocol.UUID_FFF4) {
                handleCharacteristicData(characteristic, value)
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "CCCD 写入失败 status=$status，继续尝试")
            }
            completeOp()
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("发送命令失败（status=$status）")
                return
            }
            completeOp()
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            Log.i(TAG, "MTU 协商结果: $mtu status=$status")
            if (!mtuRequested) return
            mtuRequested = false
            discoverServicesSafely(gatt)
        }
    }

    private fun discoverServicesSafely(gatt: BluetoothGatt) {
        Log.i(TAG, "发现服务…")
        try {
            @SuppressLint("MissingPermission")
            gatt.discoverServices()
        } catch (e: Exception) {
            fail("服务发现失败: ${e.message}")
        }
    }

    private fun handleCharacteristicData(
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray?
    ) {
        if (value == null || value.isEmpty()) return

        // 配对触发：连接中收到 fff4 数据 → 发送配对请求
        if (_state.value == DjiState.CONNECTING &&
            characteristic.uuid == DjiOsmoProtocol.UUID_FFF4
        ) {
            Log.i(TAG, "收到配对触发，发送配对请求")
            val frame = DjiOsmoProtocol.encodeMessage(
                DjiOsmoProtocol.TARGET_PAIR,
                DjiOsmoProtocol.ID_PAIR,
                DjiOsmoProtocol.TYPE_PAIR,
                DjiOsmoProtocol.pairPayload()
            )
            enqueueOp(GattOp.Write(frame))
            _state.value = DjiState.CHECKING_PAIRED
            return
        }

        val message = DjiOsmoProtocol.parseMessage(value)
        if (message == null) {
            Log.d(TAG, "无法解析的消息: ${value.toHex()}")
            return
        }
        processMessage(message)
    }

    private fun processMessage(message: DjiOsmoProtocol.DjiMessage) {
        Log.d(
            TAG,
            "收到消息 id=0x%04X type=0x%06X payload=${message.payload.toHex()} 状态=${_state.value}"
                .format(message.id, message.type)
        )
        when (_state.value) {
            DjiState.CHECKING_PAIRED -> {
                if (message.id != DjiOsmoProtocol.ID_PAIR) return
                if (message.payload.contentEquals(byteArrayOf(0, 1))) {
                    // 已配对：直接走清场
                    sendStopAndClean()
                } else {
                    _state.value = DjiState.PAIRING
                }
            }

            DjiState.PAIRING -> {
                // 配对完成后收到任意消息 → 发停止清场
                sendStopAndClean()
            }

            DjiState.CLEANING_UP -> {
                if (message.id != DjiOsmoProtocol.ID_STOP_STREAM) return
                if (pendingSsid == null || pendingPassword == null || pendingRtmpUrl == null) {
                    // 连接阶段清场完成：相机就绪，等待用户开播
                    _state.value = DjiState.PAIRED
                    return
                }
                val payload = DjiOsmoProtocol.preparingToLivestreamPayload()
                writeMessage(DjiOsmoProtocol.ID_PREPARE_LIVE, DjiOsmoProtocol.TYPE_PREPARE_LIVE, payload)
                _state.value = DjiState.PREPARING
            }

            DjiState.PREPARING -> {
                if (message.id != DjiOsmoProtocol.ID_PREPARE_LIVE) return
                val ssid = pendingSsid ?: return
                val password = pendingPassword ?: return
                writeMessage(
                    DjiOsmoProtocol.ID_SETUP_WIFI,
                    DjiOsmoProtocol.TYPE_SETUP_WIFI,
                    DjiOsmoProtocol.setupWifiPayload(ssid, password),
                    DjiOsmoProtocol.TARGET_WIFI
                )
                _state.value = DjiState.SETTING_WIFI
            }

            DjiState.SETTING_WIFI -> {
                if (message.id != DjiOsmoProtocol.ID_SETUP_WIFI) return
                // Action 5 Pro 需要先配置防抖再开播
                if (isAction5Pro) {
                    writeMessage(
                        DjiOsmoProtocol.ID_CONFIGURE,
                        DjiOsmoProtocol.TYPE_CONFIGURE,
                        DjiOsmoProtocol.configurePayload(DjiOsmoProtocol.STAB_ROCK_STEADY_PLUS),
                        DjiOsmoProtocol.TARGET_CONFIGURE
                    )
                    _state.value = DjiState.CONFIGURING
                } else {
                    sendStartStreaming()
                }
            }

            DjiState.CONFIGURING -> {
                if (message.id != DjiOsmoProtocol.ID_CONFIGURE) return
                sendStartStreaming()
            }

            DjiState.STARTING -> {
                if (message.id != DjiOsmoProtocol.ID_START_STREAM) return
                cancelFlowWatchdog()
                _state.value = DjiState.STREAMING
                Log.i(TAG, "大疆直播已开始: ${pendingRtmpUrl}")
            }

            DjiState.STREAMING -> {
                if (message.type == DjiOsmoProtocol.TYPE_BATTERY && message.payload.size >= 21) {
                    val battery = message.payload[20].toInt() and 0xFF
                    if (battery != _battery.value) {
                        _battery.value = battery
                        Log.i(TAG, "相机电量: $battery%")
                    }
                }
            }

            DjiState.STOPPING -> {
                if (message.id != DjiOsmoProtocol.ID_STOP_STREAM) return
                cancelStopWatchdog()
                Log.i(TAG, "大疆直播已停止")
                _state.value = DjiState.PAIRED
                _errorMessage.value = null
            }

            else -> {
                // 忽略其他状态的消息
            }
        }
    }

    private fun sendStopAndClean() {
        writeMessage(
            DjiOsmoProtocol.ID_STOP_STREAM,
            DjiOsmoProtocol.TYPE_STOP_STREAM,
            DjiOsmoProtocol.stopStreamingPayload()
        )
        _state.value = DjiState.CLEANING_UP
    }

    private fun sendStartStreaming() {
        val url = pendingRtmpUrl ?: return
        val payload = DjiOsmoProtocol.startStreamingPayload(
            rtmpUrl = url,
            resolutionByte = DjiOsmoProtocol.RES_1080P,
            fpsByte = DjiOsmoProtocol.FPS_30,
            bitrateKbps = 6000
        )
        writeMessage(DjiOsmoProtocol.ID_START_STREAM, DjiOsmoProtocol.TYPE_START_STREAM, payload)
        // OA5 确认帧：与停止推流同帧，仅最后一位为 1，真正触发开播
        if (isAction5Pro) {
            writeMessage(
                DjiOsmoProtocol.ID_STOP_STREAM,
                DjiOsmoProtocol.TYPE_STOP_STREAM,
                DjiOsmoProtocol.confirmStartStreamingPayload()
            )
        }
        _state.value = DjiState.STARTING
    }

    // ==================== 开播 / 停播 ====================

    /**
     * 启动大疆直播：需要相机已连接（[DjiState.PAIRED] 或空闲），
     * 以及 Wi-Fi 名/密码（相机将连接该 Wi-Fi 推流到 RTMP）。
     */
    fun startLiveStream(context: Context, ssid: String, password: String, rtmpUrl: String) {
        if (isStreaming) return
        if (_state.value != DjiState.PAIRED && _state.value != DjiState.IDLE) {
            _errorMessage.value = "当前状态（${_state.value}）无法开播"
            return
        }
        if (_state.value == DjiState.IDLE || gatt == null || fff3 == null) {
            _errorMessage.value = "请先连接大疆相机"
            return
        }
        pendingSsid = ssid
        pendingPassword = password
        pendingRtmpUrl = rtmpUrl
        _errorMessage.value = null
        startFlowWatchdog()
        sendStopAndClean()
    }

    /** 停止大疆直播（通过 BLE 下发停止命令；停止后保持连接可再次开播）。 */
    fun stopLiveStream() {
        if (_state.value == DjiState.IDLE || _state.value == DjiState.PAIRED) {
            pendingSsid = null
            pendingPassword = null
            pendingRtmpUrl = null
            return
        }
        cancelFlowWatchdog()
        writeMessage(
            DjiOsmoProtocol.ID_STOP_STREAM,
            DjiOsmoProtocol.TYPE_STOP_STREAM,
            DjiOsmoProtocol.stopStreamingPayload()
        )
        _state.value = DjiState.STOPPING
        startStopWatchdog()
    }

    /** UI 直接设置错误提示（如缺少 Wi-Fi 配置）。 */
    fun reportError(message: String?) {
        _errorMessage.value = message
    }

    // ==================== BLE 内部工具 ====================

    private fun findCharacteristic(
        gatt: BluetoothGatt,
        uuid: UUID
    ): BluetoothGattCharacteristic? {
        gatt.services.forEach { service ->
            service.characteristics.forEach { characteristic ->
                if (characteristic.uuid == uuid) return characteristic
            }
        }
        return null
    }

    private fun enqueueOp(op: GattOp) {
        synchronized(opQueue) {
            opQueue.addLast(op)
            if (!opInFlight) runNextOp()
        }
    }

    private fun runNextOp() {
        val currentGatt = gatt ?: run {
            opInFlight = false
            opQueue.clear()
            return
        }
        val op = opQueue.firstOrNull() ?: return
        opInFlight = true
        when (op) {
            is GattOp.EnableNotify -> {
                try {
                    @SuppressLint("MissingPermission")
                    val ok = currentGatt.setCharacteristicNotification(op.characteristic, true)
                    Log.i(TAG, "订阅 ${op.characteristic.uuid} notification=$ok")
                    val cccd = op.characteristic.getDescriptor(cccdUuid)
                    if (cccd == null) {
                        opInFlight = false
                        opQueue.removeFirst()
                        runNextOp()
                        return
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        currentGatt.writeDescriptor(
                            cccd,
                            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        currentGatt.writeDescriptor(cccd)
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "订阅 ${op.characteristic.uuid} 失败: ${e.message}")
                    opInFlight = false
                    opQueue.removeFirst()
                    runNextOp()
                }
            }

            is GattOp.Write -> {
                val characteristic = fff3 ?: run {
                    opInFlight = false
                    opQueue.clear()
                    fail("命令特征未就绪")
                    return
                }
                if (!writeGatt(currentGatt, characteristic, op.value)) {
                    opInFlight = false
                    opQueue.clear()
                    fail("命令写入失败")
                }
            }

            is GattOp.ReadFff4 -> {
                val characteristic = fff4 ?: run {
                    opInFlight = false
                    opQueue.removeFirst()
                    runNextOp()
                    return
                }
                @SuppressLint("MissingPermission")
                val ok = try {
                    currentGatt.readCharacteristic(characteristic)
                } catch (e: Exception) {
                    false
                }
                if (!ok) {
                    opInFlight = false
                    opQueue.removeFirst()
                    runNextOp()
                }
            }
        }
    }

    /** 当前在途操作完成：移除队首并启动下一个操作。 */
    private fun completeOp() {
        synchronized(opQueue) {
            if (opInFlight && opQueue.isNotEmpty()) {
                opQueue.removeFirst()
            }
            opInFlight = false
            runNextOp()
        }
    }

    private fun writeMessage(
        id: Int,
        type: Int,
        payload: ByteArray,
        target: Int = DjiOsmoProtocol.TARGET_STREAM
    ) {
        val frame = DjiOsmoProtocol.encodeMessage(
            target,
            id,
            type,
            payload
        )
        enqueueOp(GattOp.Write(frame))
    }

    @SuppressLint("MissingPermission")
    private fun writeGatt(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        gatt.writeCharacteristic(
            characteristic,
            value,
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ) == BluetoothStatusCodes.SUCCESS
    } else {
        @Suppress("DEPRECATION")
        characteristic.value = value
        @Suppress("DEPRECATION")
        gatt.writeCharacteristic(characteristic)
    }

    private fun cleanupGatt() {
        stopScanInternal()
        cancelFlowWatchdog()
        cancelStopWatchdog()
        synchronized(opQueue) {
            opQueue.clear()
            opInFlight = false
        }
        try {
            gatt?.disconnect()
        } catch (_: Exception) {
        }
        try {
            gatt?.close()
        } catch (_: Exception) {
        }
        gatt = null
        fff3 = null
        fff4 = null
        pendingSsid = null
        pendingPassword = null
        pendingRtmpUrl = null
    }

    private fun fail(message: String) {
        Log.e(TAG, message)
        _errorMessage.value = message
        cleanupGatt()
        _connectedCamera.value = null
        _state.value = DjiState.IDLE
    }

    // ==================== 看门狗 ====================

    private fun startFlowWatchdog() {
        cancelFlowWatchdog()
        val runnable = Runnable {
            fail("开播流程超时，请重试")
        }
        flowWatchdog = runnable
        mainHandler.postDelayed(runnable, 60_000)
    }

    private fun cancelFlowWatchdog() {
        flowWatchdog?.let { mainHandler.removeCallbacks(it) }
        flowWatchdog = null
    }

    private fun startStopWatchdog() {
        cancelStopWatchdog()
        val runnable = Runnable {
            cancelStopWatchdog()
            _state.value = DjiState.PAIRED
            _errorMessage.value = "停止命令未收到响应，相机可能仍在推流"
        }
        stopWatchdog = runnable
        mainHandler.postDelayed(runnable, 10_000)
    }

    private fun cancelStopWatchdog() {
        stopWatchdog?.let { mainHandler.removeCallbacks(it) }
        stopWatchdog = null
    }

    // ==================== 工具 ====================

    private fun bluetoothAdapter(context: Context): BluetoothAdapter? {
        if (bluetoothAdapter == null) {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            bluetoothAdapter = manager.adapter
        }
        return bluetoothAdapter
    }

    private fun hasBlePermissions(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) ==
                PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADMIN) ==
                PackageManager.PERMISSION_GRANTED
        }

    private fun modelNameFromDeviceName(name: String): String = when {
        name.contains("5", ignoreCase = true) -> "Osmo Action 5 Pro"
        name.contains("4", ignoreCase = true) -> "Osmo Action 4"
        name.contains("3", ignoreCase = true) -> "Osmo Action 3"
        name.contains("pocket", ignoreCase = true) -> "Osmo Pocket 3"
        else -> "大疆相机"
    }

    private fun ByteArray.toHex(): String = joinToString(" ") { "%02x".format(it) }
}
