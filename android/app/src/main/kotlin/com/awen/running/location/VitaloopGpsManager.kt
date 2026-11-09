package com.awen.running.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** 手机 GPS 采点：只负责把定位点抛给 Flutter，距离/轨迹由 Dart 侧累计后写 Rust。 */
@SuppressLint("MissingPermission")
class VitaloopGpsManager private constructor(private val context: Context) {

    companion object {
        @Volatile
        private var instance: VitaloopGpsManager? = null

        fun getInstance(context: Context): VitaloopGpsManager =
            instance ?: synchronized(this) {
                instance ?: VitaloopGpsManager(context.applicationContext).also { instance = it }
            }
    }

    @Volatile
    var onPoint: ((JSONObject) -> Unit)? = null

    @Volatile
    var onState: ((String) -> Unit)? = null

    private val pointListeners = CopyOnWriteArrayList<(JSONObject) -> Unit>()
    private val clients = HashSet<String>()

    private val manager by lazy {
        context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    }
    private var listening = false
    private var lastEmitMs = 0L

    private val listener = LocationListener { location -> emit(location) }

    fun addPointListener(listener: (JSONObject) -> Unit) {
        if (!pointListeners.contains(listener)) pointListeners.add(listener)
    }

    fun removePointListener(listener: (JSONObject) -> Unit) {
        pointListeners.remove(listener)
    }

    fun hasPermissions(): Boolean {
        val fine = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    /**
     * 多个调用方共用一条 LocationListener。client 用固定字符串标识（运动记录 /
     * 共享轨迹），重复 start 不会叠加监听；只有最后一个 client stop 才真正停 GPS。
     */
    fun start(client: String = "default"): Boolean {
        if (!hasPermissions()) return false
        synchronized(clients) { clients.add(client) }
        if (listening) return true
        val providers = buildList {
            if (manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) add(LocationManager.GPS_PROVIDER)
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) add(LocationManager.NETWORK_PROVIDER)
        }
        if (providers.isEmpty()) {
            synchronized(clients) { clients.remove(client) }
            onState?.invoke("failed:系统定位服务未开启")
            return false
        }
        listening = true
        try {
            for (provider in providers) {
                manager.requestLocationUpdates(provider, 1000L, 2f, listener, Looper.getMainLooper())
                manager.getLastKnownLocation(provider)?.let { emit(it, cached = true) }
            }
            onState?.invoke("started")
            return true
        } catch (e: Exception) {
            listening = false
            synchronized(clients) { clients.remove(client) }
            onState?.invoke("failed:${e.message ?: "定位启动失败"}")
            return false
        }
    }

    fun stop(client: String = "default") {
        val shouldStop = synchronized(clients) {
            clients.remove(client)
            clients.isEmpty()
        }
        if (!shouldStop) return
        if (!listening) return
        listening = false
        try {
            manager.removeUpdates(listener)
        } catch (_: Exception) {
        }
        onState?.invoke("stopped")
    }

    fun lastKnown(): String? {
        if (!hasPermissions()) return null
        val location = try {
            manager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: manager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) {
            null
        } ?: return null
        return toJson(location).toString()
    }

    /**
     * 一次性取当前位置，供天气同步等短任务使用。优先用 10 分钟内的缓存点，
     * 否则等一次定位回调，超时后退回任意 lastKnown。
     */
    fun currentLocation(timeoutMs: Long = 8_000L): Location? {
        if (!hasPermissions()) return null
        val cached = try {
            manager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                ?: manager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) {
            null
        }
        if (cached != null && System.currentTimeMillis() - cached.time <= 10 * 60_000L) {
            return cached
        }

        val providers = buildList {
            if (manager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                add(LocationManager.GPS_PROVIDER)
            }
            if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                add(LocationManager.NETWORK_PROVIDER)
            }
        }
        if (providers.isEmpty()) return cached

        val latch = CountDownLatch(1)
        val result = AtomicReference<Location?>()
        val listener = LocationListener { location ->
            if (result.compareAndSet(null, location)) latch.countDown()
        }
        return try {
            for (provider in providers) {
                manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            }
            latch.await(timeoutMs.coerceIn(1_000L, 20_000L), TimeUnit.MILLISECONDS)
            result.get() ?: cached
        } catch (_: Exception) {
            cached
        } finally {
            try {
                manager.removeUpdates(listener)
            } catch (_: Exception) {
            }
        }
    }

    private fun emit(location: Location, cached: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!cached && now - lastEmitMs < 700) return
        lastEmitMs = now
        Log.d("VitaloopGps", "point ${location.latitude},${location.longitude} acc=${location.accuracy} speed=${location.speed}")
        val json = toJson(location).put("cached", cached)
        onPoint?.invoke(json)
        for (callback in pointListeners) {
            try {
                callback(json)
            } catch (e: Exception) {
                Log.w("VitaloopGps", "point listener failed", e)
            }
        }
    }

    private fun toJson(location: Location): JSONObject = JSONObject()
        .put("type", "point")
        .put("provider", location.provider ?: "")
        .put("lat", location.latitude)
        .put("lon", location.longitude)
        .put("alt", if (location.hasAltitude()) location.altitude else 0.0)
        .put("speed", if (location.hasSpeed()) location.speed.toDouble() else 0.0)
        .put("accuracy", if (location.hasAccuracy()) location.accuracy.toDouble() else 0.0)
        .put("bearing", if (location.hasBearing()) location.bearing.toDouble() else 0.0)
        .put("ts", location.time.takeIf { it > 0 } ?: System.currentTimeMillis())
}
