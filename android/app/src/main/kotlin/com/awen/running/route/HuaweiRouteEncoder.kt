package com.awen.running.route

import android.location.Location
import com.awen.running.utils.CoordinateConverter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.roundToInt

/**
 * 华为手表路线文件编码。旧版逆向自 com.huawei.health 17.0.7.320 的
 * libtrack_feature_extra.so；新版保存的路线统一是 GCJ-02，下发前先转回 WGS-84。
 *
 * v1 = 12 字节头 + 40 字节点；v2 = 264 字节头 + 56 字节点。
 * 支持能力位 218（路线 CP）的手表必须发 v2，否则手表会按错误布局解析并拒绝。
 */
data class WatchRoutePoint(
    val lat: Double,
    val lon: Double,
)

data class WatchRoute(
    val name: String,
    val distanceMeters: Double,
    val points: List<WatchRoutePoint>,
)

object HuaweiRouteEncoder {
    const val HEADER_SIZE = 12
    const val POINT_SIZE = 40
    const val V2_HEADER_SIZE = 264
    const val V2_POINT_SIZE = 56

    const val VERSION_V1 = 1
    const val VERSION_V2 = 2

    private const val METERS_PER_DEGREE = 1_111_949.375
    private const val DEG_TO_RAD = 0.0174532925199433
    private const val SECONDS_PER_KILOMETER = 420.0
    private const val POINT_KIND_FIRST = 1
    private const val POINT_KIND_NORMAL = 2
    private const val V2_NAME_BYTES = 36
    private const val MAX_SAVED_POINTS = 4000

    fun totalTimeSeconds(distanceMeters: Double): Int =
        (distanceMeters / 1000.0 * SECONDS_PER_KILOMETER)
            .toLong()
            .coerceIn(0, 0xFFFF_FFFFL)
            .toInt()

    fun pointCount(bytes: ByteArray, version: Int): Int =
        if (version == VERSION_V2) {
            (bytes.size - V2_HEADER_SIZE) / V2_POINT_SIZE
        } else {
            (bytes.size - HEADER_SIZE) / POINT_SIZE
        }

    fun encode(
        route: WatchRoute,
        maxPoints: Int = MAX_SAVED_POINTS,
        version: Int = VERSION_V1,
        distanceMeters: (WatchRoutePoint, WatchRoutePoint) -> Double = ::distanceMeters,
    ): ByteArray {
        val track = buildTrack(route, maxPoints, distanceMeters)
        return if (version == VERSION_V2) encodeV2(route.name, track) else encodeV1(track)
    }

    private class Track(
        val points: List<WatchRoutePoint>,
        val distanceMeters: Double,
        val totalTimeSeconds: Int,
        val xs: IntArray,
        val ys: IntArray,
        val cumulativeMeters: DoubleArray,
    )

    private fun buildTrack(
        route: WatchRoute,
        maxPoints: Int,
        distanceMeters: (WatchRoutePoint, WatchRoutePoint) -> Double,
    ): Track {
        val sourcePoints = route.points
            .filter { CoordinateConverter.isPlottable(it.lat, it.lon) }
            .map { point ->
                val (lat, lon) = CoordinateConverter.gcj02ToWgs84(point.lat, point.lon)
                WatchRoutePoint(lat, lon)
            }
        val points = downsample(sourcePoints, maxPoints.coerceIn(2, Int.MAX_VALUE))
        require(points.size >= 2) { "route needs at least 2 points" }

        val baseLat = points.first().lat
        val baseLon = points.first().lon
        val lonScale = METERS_PER_DEGREE * cos(baseLat * DEG_TO_RAD)
        val xs = IntArray(points.size)
        val ys = IntArray(points.size)
        val cumulative = DoubleArray(points.size)
        var acc = 0.0
        points.forEachIndexed { index, point ->
            if (index > 0) {
                acc += distanceMeters(points[index - 1], point)
            }
            xs[index] = ((point.lon - baseLon) * lonScale).toInt()
            ys[index] = ((point.lat - baseLat) * METERS_PER_DEGREE).toInt()
            cumulative[index] = acc
        }
        val distance = if (route.distanceMeters > 0) route.distanceMeters else acc
        return Track(points, distance, totalTimeSeconds(distance), xs, ys, cumulative)
    }

    private fun downsample(points: List<WatchRoutePoint>, maxPoints: Int): List<WatchRoutePoint> {
        if (maxPoints <= 1 || points.size <= maxPoints) return points
        val step = (points.size - 1).toDouble() / (maxPoints - 1)
        return (0 until maxPoints).map { index ->
            points[(index * step).roundToInt().coerceIn(0, points.lastIndex)]
        }
    }

    private fun distanceMeters(from: WatchRoutePoint, to: WatchRoutePoint): Double {
        val results = FloatArray(1)
        Location.distanceBetween(from.lat, from.lon, to.lat, to.lon, results)
        return results[0].toDouble()
    }

    private fun encodeV1(track: Track): ByteArray {
        val out = ByteBuffer.allocate(HEADER_SIZE + track.points.size * POINT_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN)
        out.putInt(track.totalTimeSeconds)
        out.putFloat(track.distanceMeters.toFloat())
        out.putInt(track.points.size)
        track.points.forEachIndexed { index, point ->
            out.putDouble(point.lon)
            out.putDouble(point.lat)
            out.putInt(track.xs[index])
            out.putInt(track.ys[index])
            out.putInt(index)
            out.putUInt(track.cumulativeMeters[index])
            out.putShort(0)
            out.put(kind(index))
            out.put(0)
            out.put(0)
            out.put(byteArrayOf(0, 0, 0))
        }
        return out.array()
    }

    private fun encodeV2(name: String, track: Track): ByteArray {
        val out = ByteBuffer.allocate(V2_HEADER_SIZE + track.points.size * V2_POINT_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN)
        out.putInt(-1)
        out.put(0x04, VERSION_V2.toByte())
        out.position(0x8)
        out.putInt(track.totalTimeSeconds)
        out.putFloat(track.distanceMeters.toFloat())
        out.putInt(track.points.size)
        writeFixedUtf8(out, name, V2_NAME_BYTES)
        out.position(0xb8)
        out.putFloat(track.distanceMeters.toFloat())
        out.position(V2_HEADER_SIZE)
        track.points.forEachIndexed { index, point ->
            out.putDouble(point.lon)
            out.putDouble(point.lat)
            out.putInt(track.xs[index])
            out.putInt(track.ys[index])
            out.putInt(index)
            out.putUInt(track.cumulativeMeters[index])
            out.putShort(0)
            out.put(kind(index))
            out.put(0)
            out.putInt(track.cumulativeMeters[index].toInt())
            out.putDouble(0.0)
            out.putInt(0)
            out.putInt(0)
        }
        return out.array()
    }

    private fun kind(index: Int): Byte =
        (if (index == 0) POINT_KIND_FIRST else POINT_KIND_NORMAL).toByte()

    private fun ByteBuffer.putUInt(value: Double) {
        putInt(value.toLong().coerceAtMost(0xFFFF_FFFFL).toInt())
    }

    private fun writeFixedUtf8(out: ByteBuffer, value: String, size: Int) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        out.put(bytes, 0, minOf(size - 1, bytes.size))
    }
}
