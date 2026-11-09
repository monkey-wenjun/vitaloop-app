package com.awen.running.route

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class HuaweiRouteEncoderTest {
    private fun route(count: Int) = WatchRoute(
        name = "滨江环线",
        distanceMeters = 300.0,
        points = List(count) { index ->
            WatchRoutePoint(
                lat = 30.0 + index * 0.0001,
                lon = 120.0 + index * 0.0001,
            )
        },
    )

    private fun noDistance(@Suppress("UNUSED_PARAMETER") from: WatchRoutePoint, @Suppress("UNUSED_PARAMETER") to: WatchRoutePoint) = 0.0

    @Test
    fun `v1 layout is 12 byte header plus 40 byte points`() {
        val encoded = HuaweiRouteEncoder.encode(
            route(100),
            maxPoints = 100,
            version = HuaweiRouteEncoder.VERSION_V1,
            distanceMeters = ::noDistance,
        )
        assertEquals(
            HuaweiRouteEncoder.HEADER_SIZE + 100 * HuaweiRouteEncoder.POINT_SIZE,
            encoded.size,
        )
        assertEquals(100, HuaweiRouteEncoder.pointCount(encoded, HuaweiRouteEncoder.VERSION_V1))

        val header = ByteBuffer.wrap(encoded).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(126, header.getInt(0))
        assertEquals(300f, header.getFloat(4))
        assertEquals(100, header.getInt(8))
    }

    @Test
    fun `v2 layout is 264 byte header plus 56 byte points`() {
        val encoded = HuaweiRouteEncoder.encode(
            route(100),
            maxPoints = 100,
            version = HuaweiRouteEncoder.VERSION_V2,
            distanceMeters = ::noDistance,
        )
        assertEquals(
            HuaweiRouteEncoder.V2_HEADER_SIZE + 100 * HuaweiRouteEncoder.V2_POINT_SIZE,
            encoded.size,
        )
        assertEquals(100, HuaweiRouteEncoder.pointCount(encoded, HuaweiRouteEncoder.VERSION_V2))

        val header = ByteBuffer.wrap(encoded).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(-1, header.getInt(0))
        assertEquals(2, header.get(4).toInt())
        assertEquals(126, header.getInt(8))
    }

    @Test
    fun `downsample keeps both ends and rejects one point route`() {
        val encoded = HuaweiRouteEncoder.encode(
            route(1000),
            maxPoints = 25,
            version = HuaweiRouteEncoder.VERSION_V1,
            distanceMeters = ::noDistance,
        )
        assertEquals(25, HuaweiRouteEncoder.pointCount(encoded, HuaweiRouteEncoder.VERSION_V1))
    }

    @Test
    fun `gcj02 points are converted back to wgs84 before encoding`() {
        val input = WatchRoutePoint(30.0, 120.0)
        val encoded = HuaweiRouteEncoder.encode(
            WatchRoute("test", 0.0, listOf(input, WatchRoutePoint(30.001, 120.001))),
            maxPoints = 100,
            version = HuaweiRouteEncoder.VERSION_V1,
            distanceMeters = ::noDistance,
        )
        val point = ByteBuffer.wrap(encoded, HuaweiRouteEncoder.HEADER_SIZE, HuaweiRouteEncoder.POINT_SIZE)
            .order(ByteOrder.LITTLE_ENDIAN)
        assertNotEquals(input.lon, point.getDouble(0))
        assertNotEquals(input.lat, point.getDouble(8))
    }
}
