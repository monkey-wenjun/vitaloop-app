package com.awen.running.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Build
import com.awen.running.utils.BodyCompositionCalculator
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.pow

/**
 * 标准 BLE 心率带直连：扫描 → GATT 连接 → 订阅 0x2A37 → 把心率抛给 Flutter。
 * 只做旧版 BluetoothLeManager 的心率带部分；小米手环与华为手表有各自协议，不在这里抢链路。
 */
@SuppressLint("MissingPermission")
class VitaloopBleManager private constructor(private val context: Context) {

    companion object {
        private val HEART_RATE_SERVICE = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        private val HEART_RATE_MEASUREMENT = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val CLIENT_CONFIG = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val BATTERY_SERVICE = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_LEVEL = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
        private val WEIGHT_SCALE_SERVICE = UUID.fromString("0000181d-0000-1000-8000-00805f9b34fb")
        private val WEIGHT_MEASUREMENT = UUID.fromString("00002a9d-0000-1000-8000-00805f9b34fb")
        private val BLOOD_PRESSURE_SERVICE = UUID.fromString("00001810-0000-1000-8000-00805f9b34fb")
        private val BLOOD_PRESSURE_MEASUREMENT = UUID.fromString("00002a35-0000-1000-8000-00805f9b34fb")
        private val GLUCOSE_SERVICE = UUID.fromString("00001808-0000-1000-8000-00805f9b34fb")
        private val GLUCOSE_MEASUREMENT = UUID.fromString("00002a18-0000-1000-8000-00805f9b34fb")
        private val AFU_WL_NOTIFY = UUID.fromString("0000ffb2-0000-1000-8000-00805f9b34fb")
        private val AFU_WL_WRITE = UUID.fromString("0000ffb1-0000-1000-8000-00805f9b34fb")
        private const val PREFS = "vitaloop_ble"
        private const val KEY_HISTORY = "history"
        private const val KEY_LAST = "last"
        private const val KEY_HEIGHT = "scale_height_cm"
        private const val KEY_AGE = "scale_age"
        private const val KEY_SEX = "scale_sex"
        private const val KEY_AFU_DEVICE_TYPE = "afu_device_type"
        private const val DEFAULT_AFU_DEVICE_TYPE = 0x29

        @Volatile
        private var instance: VitaloopBleManager? = null

        fun getInstance(context: Context): VitaloopBleManager =
            instance ?: synchronized(this) {
                instance ?: VitaloopBleManager(context.applicationContext).also { instance = it }
            }

        data class HeartRateSample(val bpm: Int, val rrIntervals: List<Int>)

        /// 标准 Bluetooth SIG Heart Rate Measurement（0x2A37）。
        /// bit 0: BPM 是 UINT8 还是 UINT16；bit 3: 是否带能量消耗字段；
        /// bit 4: 是否带 RR 间期（每个 1/1024 秒，小端序）。
        fun parseHeartRateMeasurement(value: ByteArray): HeartRateSample? {
            if (value.size < 2) return null
            val flags = value[0].toInt() and 0xFF
            val wideBpm = (flags and 0x01) != 0
            if (wideBpm && value.size < 3) return null
            val bpm = if (wideBpm) {
                (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
            } else {
                value[1].toInt() and 0xFF
            }
            if (bpm <= 0) return null

            val rr = mutableListOf<Int>()
            if ((flags and 0x10) != 0) {
                var offset = if (wideBpm) 3 else 2
                if ((flags and 0x08) != 0) offset += 2
                while (offset + 1 < value.size) {
                    val raw = (value[offset].toInt() and 0xFF) or
                        ((value[offset + 1].toInt() and 0xFF) shl 8)
                    if (raw > 0) rr.add((raw * 1000 + 512) / 1024)
                    offset += 2
                }
            }
            return HeartRateSample(bpm, rr)
        }
    }

    data class DeviceInfo(
        val address: String,
        val name: String,
        var rssi: Int = 0,
        var state: String = "disconnected",
        var kind: String = "",
        var heartRate: Int = 0,
        var battery: Int = -1,
        var display: String = "",
    )

    @Volatile
    var onEvent: ((JSONObject) -> Unit)? = null

    private val adapter: BluetoothAdapter? by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    }
    private val prefs by lazy { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    private val gatts = ConcurrentHashMap<String, BluetoothGatt>()
    private val known = ConcurrentHashMap<String, DeviceInfo>()
    private val afuProtocols = ConcurrentHashMap<String, AfuScaleProtocol>()
    private val afuStableWeight = ConcurrentHashMap<String, Double>()
    private val afuRewritten = ConcurrentHashMap.newKeySet<String>()
    private val afuCharging = ConcurrentHashMap<String, Boolean>()
    private val afuBattery = ConcurrentHashMap<String, Int>()
    private var scanning = false
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val name = try {
                result.scanRecord?.deviceName ?: device.name ?: ""
            } catch (_: SecurityException) {
                ""
            }
            val hasHeartRate = result.scanRecord?.serviceUuids?.any { it.uuid == HEART_RATE_SERVICE } == true
            val lowerName = name.lowercase()
            val hasAfu = lowerName.contains("afu-wl") || lowerName.startsWith("afu") ||
                result.scanRecord?.serviceUuids?.any { it.uuid == AFU_WL_NOTIFY || it.uuid == AFU_WL_WRITE } == true
            val kind = when {
                result.scanRecord?.serviceUuids?.any { it.uuid == WEIGHT_SCALE_SERVICE } == true -> "weight"
                hasAfu -> "scale"
                result.scanRecord?.serviceUuids?.any { it.uuid == BLOOD_PRESSURE_SERVICE } == true -> "bp"
                result.scanRecord?.serviceUuids?.any { it.uuid == GLUCOSE_SERVICE } == true -> "glucose"
                hasHeartRate -> "hr"
                else -> ""
            }
            if (name.isBlank() && kind.isEmpty()) return
            if (known[device.address]?.state == "connected") return
            var info = known.getOrPut(device.address) { DeviceInfo(device.address, name) }
            if (name.isNotBlank() && info.name != name) {
                info = info.copy(name = name)
            }
            if (kind.isNotEmpty()) info.kind = kind
            info.rssi = result.rssi
            known[device.address] = info
            // 部分体脂秤每次唤醒会换 BLE 随机地址；不清理同名旧地址，
            // 体重页会把同一台秤显示成两个蓝牙设备。
            if (kind == "scale" && name.isNotBlank()) {
                known.values
                    .filter {
                        it.address != device.address &&
                            it.kind == "scale" &&
                            it.state != "connected" &&
                            it.name.equals(name, ignoreCase = true)
                    }
                    .map { it.address }
                    .forEach { stale ->
                        known.remove(stale)
                        emit(JSONObject().put("type", "forget").put("address", stale))
                    }
            }
            emit(JSONObject()
                .put("type", "device")
                .put("address", info.address)
                .put("name", info.name)
                .put("rssi", info.rssi)
                .put("state", info.state)
                .put("kind", info.kind)
                .put("heartRate", info.heartRate)
                .put("battery", info.battery)
                .put("display", info.display))
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            emit(JSONObject().put("type", "scan").put("scanning", false).put("error", errorCode))
        }
    }

    fun hasPermissions(): Boolean {
        val required = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(
                android.Manifest.permission.BLUETOOTH,
                android.Manifest.permission.BLUETOOTH_ADMIN,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }
        return required.all {
            context.checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
    }

    fun startScan(): Boolean {
        if (!hasPermissions()) return false
        val scanner = adapter?.bluetoothLeScanner ?: return false
        if (scanning) return true
        scanning = true
        emit(JSONObject().put("type", "scan").put("scanning", true))
        scanner.startScan(scanCallback)
        return true
    }

    fun stopScan() {
        if (!scanning) return
        scanning = false
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: SecurityException) {
        }
        emit(JSONObject().put("type", "scan").put("scanning", false))
    }

    fun connect(address: String, name: String): Boolean {
        if (!hasPermissions()) return false
        stopScan()
        val device = try {
            adapter?.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            null
        } ?: return false
        gatts[address]?.let {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        val info = known.getOrPut(address) { DeviceInfo(address, name) }
        info.state = "connecting"
        emitState(info)
        val gatt = device.connectGatt(context, false, callback(address, name), BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) {
            info.state = "failed"
            emitState(info)
            return false
        }
        gatts[address] = gatt
        return true
    }

    fun disconnect(address: String) {
        val gatt = gatts.remove(address) ?: return
        try {
            gatt.disconnect()
            gatt.close()
        } catch (_: Exception) {
        }
        known[address]?.let {
            it.state = "disconnected"
            it.heartRate = 0
            emitState(it)
        }
    }

    fun forget(address: String) {
        disconnect(address)
        known.remove(address)
        val history = history().toMutableMap()
        history.remove(address)
        saveHistory(history)
        if (prefs.getString(KEY_LAST, null) == address) prefs.edit().remove(KEY_LAST).apply()
        emit(JSONObject().put("type", "forget").put("address", address))
    }

    fun connectLast(): Boolean {
        val address = prefs.getString(KEY_LAST, null) ?: return false
        val name = history()[address] ?: "蓝牙设备"
        return connect(address, name)
    }

    /** Flutter 侧把用户档案同步过来，AFU 体脂秤需要用身高/年龄/性别算人体成分。 */
    fun configureProfile(heightCm: Double, age: Int, sex: String) {
        prefs.edit()
            .putFloat(KEY_HEIGHT, if (heightCm > 0) heightCm.toFloat() else 170f)
            .putInt(KEY_AGE, if (age in 1..120) age else 30)
            .putString(KEY_SEX, sex)
            .apply()
    }

    fun devices(): String {
        val arr = org.json.JSONArray()
        known.values.forEach { info ->
            arr.put(JSONObject()
                .put("address", info.address)
                .put("name", info.name)
                .put("rssi", info.rssi)
                .put("state", info.state)
                .put("kind", info.kind)
                .put("heartRate", info.heartRate)
                .put("battery", info.battery)
                .put("display", info.display))
        }
        return arr.toString()
    }

    /** 已连接心率带/手环的最新心率；共享轨迹上报时读取，不额外订阅 GATT。 */
    fun latestHeartRate(): Int = known.values
        .asSequence()
        .filter { it.state == "connected" }
        .map { it.heartRate }
        .firstOrNull { it > 0 } ?: 0

    fun history(): Map<String, String> {
        val raw = prefs.getString(KEY_HISTORY, null) ?: return emptyMap()
        return try {
            val obj = JSONObject(raw)
            buildMap {
                obj.keys().forEach { key -> put(key, obj.optString(key)) }
            }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    private fun saveHistoryItem(address: String, name: String) {
        val map = history().toMutableMap()
        map[address] = name.ifBlank { "蓝牙设备" }
        saveHistory(map)
        prefs.edit().putString(KEY_LAST, address).apply()
    }

    private fun saveHistory(map: Map<String, String>) {
        val obj = JSONObject()
        map.forEach { (k, v) -> obj.put(k, v) }
        prefs.edit().putString(KEY_HISTORY, obj.toString()).apply()
    }

    private fun callback(address: String, fallbackName: String) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val info = known.getOrPut(address) { DeviceInfo(address, fallbackName) }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    info.state = "connected"
                    emitState(info)
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    info.state = if (status == BluetoothGatt.GATT_SUCCESS) "disconnected" else "failed"
                    info.heartRate = 0
                    emitState(info)
                    gatts.remove(address)
                    try {
                        gatt.close()
                    } catch (_: Exception) {
                    }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val info = known[address] ?: return
            saveHistoryItem(address, info.name.ifBlank { fallbackName })
            val afuNotify = gatt.services.firstNotNullOfOrNull { it.getCharacteristic(AFU_WL_NOTIFY) }
            val afuWrite = gatt.services.firstNotNullOfOrNull { it.getCharacteristic(AFU_WL_WRITE) }
            if (afuNotify != null && afuWrite != null) {
                setupAfuScale(gatt, address, info, afuNotify, afuWrite)
                return
            }
            val hr = gatt.getService(HEART_RATE_SERVICE)?.getCharacteristic(HEART_RATE_MEASUREMENT)
            val weight = gatt.getService(WEIGHT_SCALE_SERVICE)?.getCharacteristic(WEIGHT_MEASUREMENT)
            val bp = gatt.getService(BLOOD_PRESSURE_SERVICE)?.getCharacteristic(BLOOD_PRESSURE_MEASUREMENT)
            val glucose = gatt.getService(GLUCOSE_SERVICE)?.getCharacteristic(GLUCOSE_MEASUREMENT)
            if (hr == null && weight == null && bp == null && glucose == null) {
                info.state = "failed"
                emit(JSONObject()
                    .put("type", "error")
                    .put("address", address)
                    .put("message", "该设备没有标准健康服务（心率/体重/血压/血糖）"))
                emitState(info)
                return
            }
            val targets = listOfNotNull(
                hr?.let { "hr" to it },
                weight?.let { "weight" to it },
                bp?.let { "bp" to it },
                glucose?.let { "glucose" to it },
            )
            info.kind = targets.first().first
            targets.forEach { (_, characteristic) ->
                gatt.setCharacteristicNotification(characteristic, true)
                val descriptor = characteristic.getDescriptor(CLIENT_CONFIG)
                if (descriptor != null) writeDescriptor(gatt, descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            }
            emitState(info)
            val battery = gatt.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_LEVEL)
            if (battery != null) gatt.readCharacteristic(battery)
        }

        private fun setupAfuScale(
            gatt: BluetoothGatt,
            address: String,
            info: DeviceInfo,
            notify: BluetoothGattCharacteristic,
            write: BluetoothGattCharacteristic,
        ) {
            // 同一台秤换随机地址重连后，旧 GATT 可能还挂着 connected。
            // 只保留当前这条连接，否则体重页会同时出现两个“已连接”的蓝牙。
            known.values
                .filter {
                    it.address != address &&
                        it.kind == "scale" &&
                        it.state == "connected" &&
                        it.name.equals(info.name, ignoreCase = true)
                }
                .map { it.address }
                .forEach { stale -> disconnect(stale) }
            afuProtocols[address] = AfuScaleProtocol()
            afuStableWeight.remove(address)
            afuRewritten.remove(address)
            info.kind = "scale"
            info.state = "connected"
            gatt.setCharacteristicNotification(notify, true)
            val descriptor = notify.getDescriptor(CLIENT_CONFIG)
            if (descriptor != null) {
                writeDescriptor(gatt, descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            }
            emitState(info)
            // 等 CCCD 写完再发用户资料，否则秤可能收不到触发命令。
            handler.postDelayed({
                if (gatts[address] === gatt) writeAfuUserInfo(gatt, address, write)
            }, 450)
        }

        private fun writeAfuUserInfo(
            gatt: BluetoothGatt,
            address: String,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val height = prefs.getFloat(KEY_HEIGHT, 170f).toInt().coerceIn(100, 230)
            val age = prefs.getInt(KEY_AGE, 30).coerceIn(10, 120)
            val sex = prefs.getString(KEY_SEX, "male") ?: "male"
            val sexValue = if (sex.equals("female", ignoreCase = true)) 2 else 1
            val deviceType = prefs.getInt(KEY_AFU_DEVICE_TYPE, DEFAULT_AFU_DEVICE_TYPE)
            val functionFlags = (1 shl 0) or (1 shl 1)
            val now = (System.currentTimeMillis() / 1000).toInt()
            val utcQuarters = ((java.util.TimeZone.getDefault().rawOffset / 1000) / 900) and 0xFF

            val payload = ByteArray(19)
            payload[0] = 0xAC.toByte()
            payload[1] = (deviceType and 0xFF).toByte()
            writeU32(payload, 2, now)
            payload[6] = utcQuarters.toByte()
            payload[7] = 0 // kg
            payload[8] = 1 // user index
            payload[9] = height.toByte()
            writeU16(payload, 10, 0)
            payload[12] = age.toByte()
            payload[13] = sexValue.toByte()
            writeU16(payload, 14, 0)
            payload[16] = functionFlags.toByte()
            payload[17] = 0
            payload[18] = 0xD0.toByte()
            val checksum = payload.copyOfRange(2, 19).sumOf { it.toInt() and 0xFF } and 0xFF
            val cmd = payload + checksum.toByte()

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(
                        characteristic,
                        cmd,
                        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                    )
                } else {
                    @Suppress("DEPRECATION")
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    @Suppress("DEPRECATION")
                    characteristic.value = cmd
                    @Suppress("DEPRECATION")
                    gatt.writeCharacteristic(characteristic)
                }
            } catch (_: SecurityException) {
            }
        }

        private fun writeU16(data: ByteArray, offset: Int, value: Int) {
            data[offset] = ((value ushr 8) and 0xFF).toByte()
            data[offset + 1] = (value and 0xFF).toByte()
        }

        private fun writeU32(data: ByteArray, offset: Int, value: Int) {
            data[offset] = ((value ushr 24) and 0xFF).toByte()
            data[offset + 1] = ((value ushr 16) and 0xFF).toByte()
            data[offset + 2] = ((value ushr 8) and 0xFF).toByte()
            data[offset + 3] = (value and 0xFF).toByte()
        }

        private fun handleAfuNotify(address: String, value: ByteArray) {
            val protocol = afuProtocols.getOrPut(address) { AfuScaleProtocol() }
            val result = protocol.feed(value)
            for (event in result.events) {
                maybeUpdateAfuDeviceType(address, event)
                when (event["kind"]) {
                    "weight" -> {
                        (event["battery"] as? Number)?.toInt()?.let {
                            afuBattery[address] = it
                            known[address]?.let { info -> info.battery = it }
                        }
                        (event["charging"] as? Boolean)?.let { afuCharging[address] = it }
                        val kg = event["weight_kg"] as? Double ?: continue
                        val stable = (event["stable"] as? Boolean ?: false) ||
                            (event["state"] as? Int ?: 0) == 1
                        val info = known[address] ?: continue
                        info.kind = "scale"
                        info.state = "connected"
                        info.display = String.format("%.1f kg", kg)
                        emitState(info)
                        if (kg > 0) {
                            if (stable) afuStableWeight[address] = kg
                            // 称重过程中也要实时推数字；stable=false 时 Flutter 侧
                            // 只更新当前读数，不会落历史（避免每次晃动都存一条）。
                            emitScaleWeight(
                                address,
                                kg,
                                stable,
                                null,
                                afuCharging[address],
                                afuBattery[address],
                            )
                        }
                    }
                    "adc" -> {
                        val kg = (event["weight_kg"] as? Double) ?: afuStableWeight[address] ?: continue
                        val impedances = (event["impendences"] as? List<*>)
                            ?.mapNotNull { (it as? Number)?.toDouble() }
                            ?: continue
                        val comp = composition(kg, impedances) ?: continue
                        afuStableWeight[address] = kg
                        emitScaleWeight(
                            address,
                            kg,
                            true,
                            comp,
                            afuCharging[address],
                            afuBattery[address],
                        )
                    }
                }
            }
        }

        private fun maybeUpdateAfuDeviceType(address: String, event: Map<String, Any?>) {
            val kind = event["kind"] as? String ?: return
            if (kind == "history" || kind == "setting") return
            val deviceType = event["device_type"] as? Int ?: return
            if (deviceType <= 0) return
            val current = prefs.getInt(KEY_AFU_DEVICE_TYPE, DEFAULT_AFU_DEVICE_TYPE)
            if (deviceType != current) {
                prefs.edit().putInt(KEY_AFU_DEVICE_TYPE, deviceType).apply()
            }
            if (afuRewritten.add(address)) {
                val gatt = gatts[address]
                val write = gatt?.services?.firstNotNullOfOrNull { it.getCharacteristic(AFU_WL_WRITE) }
                if (gatt != null && write != null) writeAfuUserInfo(gatt, address, write)
            }
        }

        private fun composition(
            kg: Double,
            impedances: List<Double>,
        ): BodyCompositionCalculator.BodyCompositionResult? {
            return BodyCompositionCalculator.estimate(
                weightKg = kg,
                heightCm = prefs.getFloat(KEY_HEIGHT, 170f).toDouble(),
                age = prefs.getInt(KEY_AGE, 30),
                sex = prefs.getString(KEY_SEX, "male") ?: "male",
                impedances = impedances,
            )
        }

        private fun emitScaleWeight(
            address: String,
            kg: Double,
            stable: Boolean,
            comp: BodyCompositionCalculator.BodyCompositionResult?,
            charging: Boolean?,
            battery: Int?,
        ) {
            val info = known[address] ?: return
            val obj = JSONObject()
                .put("type", "weight")
                .put("address", address)
                .put("name", info.name)
                .put("state", info.state)
                .put("kind", "scale")
                .put("weightKg", kg)
                .put("stable", stable)
                .put("ts", System.currentTimeMillis())
            if (charging != null) obj.put("charging", charging)
            if (battery != null) obj.put("battery", battery)
            if (comp != null) {
                obj.put("bodyFatPercent", comp.bodyFatPercent)
                obj.put("fatMassKg", comp.fatMassKg)
                obj.put("musclePercent", comp.musclePercent)
                obj.put("muscleMassKg", comp.muscleMassKg)
                obj.put("waterPercent", comp.waterPercent)
                obj.put("waterMassKg", comp.waterMassKg)
                obj.put("proteinPercent", comp.proteinPercent)
                obj.put("proteinMassKg", comp.proteinMassKg)
                obj.put("bonePercent", comp.bonePercent)
                obj.put("boneMassKg", comp.boneMassKg)
                obj.put("skeletalMusclePercent", comp.skeletalMusclePercent)
                obj.put("skeletalMuscleMassKg", comp.skeletalMuscleMassKg)
                obj.put("subcutaneousFatPercent", comp.subcutaneousFatPercent)
                obj.put("subcutaneousFatMassKg", comp.subcutaneousFatMassKg)
                obj.put("resistanceOhm", comp.resistanceOhm)
                obj.put("model", comp.model)
                obj.put("heightCm", prefs.getFloat(KEY_HEIGHT, 170f).toDouble())
            }
            emit(obj)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            @Suppress("DEPRECATION")
            handleRead(characteristic.uuid, characteristic.value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            handleRead(characteristic.uuid, value)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            handleChanged(address, characteristic.uuid, characteristic.value)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handleChanged(address, characteristic.uuid, value)
        }

        private fun handleRead(uuid: UUID, value: ByteArray) {
            if (uuid == BATTERY_LEVEL && value.isNotEmpty()) {
                val info = known[address] ?: return
                info.battery = value[0].toInt() and 0xFF
                emitState(info)
            }
        }

        private fun handleChanged(address: String, uuid: UUID, value: ByteArray) {
            when (uuid) {
                HEART_RATE_MEASUREMENT -> parseHeartRate(address, value)
                WEIGHT_MEASUREMENT -> parseWeight(address, value)
                BLOOD_PRESSURE_MEASUREMENT -> parseBloodPressure(address, value)
                GLUCOSE_MEASUREMENT -> parseGlucose(address, value)
                AFU_WL_NOTIFY -> handleAfuNotify(address, value)
            }
        }

        private fun parseHeartRate(address: String, value: ByteArray) {
            val sample = parseHeartRateMeasurement(value) ?: return
            if (sample.bpm > 255) return
            val info = known[address] ?: return
            info.heartRate = sample.bpm
            info.state = "connected"
            emitState(info, heartRate = true, rrIntervals = sample.rrIntervals)
        }

        private fun parseWeight(address: String, value: ByteArray) {
            if (value.size < 3) return
            val flags = value[0].toInt() and 0xFF
            val raw = (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
            val kg = if ((flags and 0x01) == 0) raw * 0.005 else raw * 0.01 * 0.45359237
            if (kg < 10 || kg > 300) return
            val ts = if ((flags and 0x02) != 0) parseTimestamp(value, 3) else System.currentTimeMillis()
            val info = known[address] ?: return
            info.kind = "weight"
            info.state = "connected"
            info.display = String.format("%.1f kg", kg)
            emit(JSONObject()
                .put("type", "weight")
                .put("address", address)
                .put("name", info.name)
                .put("state", info.state)
                .put("kind", info.kind)
                .put("weightKg", kg)
                .put("ts", ts))
        }

        private fun parseBloodPressure(address: String, value: ByteArray) {
            if (value.size < 7) return
            val flags = value[0].toInt() and 0xFF
            var idx = 1
            fun u16(): Int {
                val v = (value[idx].toInt() and 0xFF) or ((value[idx + 1].toInt() and 0xFF) shl 8)
                idx += 2
                return v
            }
            val unitKpa = (flags and 0x01) != 0
            val systolic: Double
            val diastolic: Double
            if (unitKpa) {
                systolic = sfloat(value[idx], value[idx + 1]) * 7.50062; idx += 2
                diastolic = sfloat(value[idx], value[idx + 1]) * 7.50062; idx += 2
                if (idx + 2 <= value.size) idx += 2
            } else {
                systolic = u16().toDouble()
                diastolic = u16().toDouble()
                if (idx + 2 <= value.size) idx += 2
            }
            val ts = if ((flags and 0x02) != 0) parseTimestamp(value, idx) else System.currentTimeMillis()
            if ((flags and 0x02) != 0) idx += 7
            var pulse = 0
            if ((flags and 0x04) != 0 && idx + 2 <= value.size) {
                pulse = (value[idx].toInt() and 0xFF) or ((value[idx + 1].toInt() and 0xFF) shl 8)
            }
            val sys = systolic.roundToInt()
            val dia = diastolic.roundToInt()
            if (sys < 50 || sys > 260 || dia < 30 || dia > 180) return
            val info = known[address] ?: return
            info.kind = "bp"
            info.state = "connected"
            info.display = "$sys/$dia"
            emit(JSONObject()
                .put("type", "bp")
                .put("address", address)
                .put("name", info.name)
                .put("state", info.state)
                .put("kind", info.kind)
                .put("systolic", sys)
                .put("diastolic", dia)
                .put("pulse", pulse)
                .put("ts", ts))
        }

        private fun parseGlucose(address: String, value: ByteArray) {
            if (value.size < 10) return
            val flags = value[0].toInt() and 0xFF
            var idx = 1
            idx += 2 // sequence number
            val ts = parseTimestamp(value, idx)
            idx += 7
            if (idx + 3 > value.size) return
            val raw = sfloat(value[idx], value[idx + 1])
            // 0 = kg/L，1 = mol/L；统一换算成 mmol/L
            val mmol = if ((flags and 0x02) != 0) raw * 1000.0 else raw * 100000.0 / 180.156
            if (mmol < 1 || mmol > 40) return
            val info = known[address] ?: return
            info.kind = "glucose"
            info.state = "connected"
            info.display = String.format("%.1f mmol", mmol)
            emit(JSONObject()
                .put("type", "glucose")
                .put("address", address)
                .put("name", info.name)
                .put("state", info.state)
                .put("kind", info.kind)
                .put("value", mmol)
                .put("ts", ts))
        }

        private fun parseTimestamp(value: ByteArray, start: Int): Long {
            if (start + 7 > value.size) return System.currentTimeMillis()
            return try {
                val year = (value[start].toInt() and 0xFF) or ((value[start + 1].toInt() and 0xFF) shl 8)
                val month = value[start + 2].toInt() and 0xFF
                val day = value[start + 3].toInt() and 0xFF
                val hour = value[start + 4].toInt() and 0xFF
                val minute = value[start + 5].toInt() and 0xFF
                val second = value[start + 6].toInt() and 0xFF
                java.time.LocalDateTime.of(year, month, day, hour, minute, second)
                    .atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
            } catch (_: Exception) {
                System.currentTimeMillis()
            }
        }

        private fun sfloat(lo: Byte, hi: Byte): Double {
            val raw = (lo.toInt() and 0xFF) or ((hi.toInt() and 0xFF) shl 8)
            var mantissa = raw and 0x0FFF
            var exponent = raw shr 12
            if (exponent >= 8) exponent -= 16
            if (mantissa >= 0x0800) mantissa -= 0x1000
            return mantissa * 10.0.pow(exponent)
        }

        private fun Double.roundToInt(): Int = kotlin.math.round(this).toInt()
    }

    private fun writeDescriptor(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray) {
        if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(descriptor, value)
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = value
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
    }

    private fun emitState(
        info: DeviceInfo,
        heartRate: Boolean = false,
        rrIntervals: List<Int> = emptyList(),
    ) {
        val obj = JSONObject()
            .put("type", if (heartRate) "hr" else "state")
            .put("address", info.address)
            .put("name", info.name)
            .put("state", info.state)
            .put("kind", info.kind)
            .put("display", info.display)
            .put("heartRate", info.heartRate)
            .put("battery", info.battery)
            .put("ts", System.currentTimeMillis())
        if (rrIntervals.isNotEmpty()) {
            obj.put("rr", JSONArray(rrIntervals))
        }
        emit(obj)
    }

    private fun emit(obj: JSONObject) {
        onEvent?.invoke(obj)
    }
}
