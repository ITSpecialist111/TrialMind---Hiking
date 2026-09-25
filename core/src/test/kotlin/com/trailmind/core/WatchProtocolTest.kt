package com.trailmind.core

import com.trailmind.core.geo.LatLon
import com.trailmind.core.watch.TileReply
import com.trailmind.core.watch.TileRequest
import com.trailmind.core.watch.WatchProtocol
import com.trailmind.core.watch.WatchRoute
import com.trailmind.core.watch.WatchState
import com.trailmind.core.watch.WatchTrack
import com.trailmind.core.watch.WatchWaypoint
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WatchProtocolTest {
    private fun roundTrip(type: Int, payload: ByteArray): WatchProtocol.Frame {
        val bytes = ByteArrayOutputStream()
        WatchProtocol.writeFrame(DataOutputStream(bytes), type, payload)
        return WatchProtocol.readFrame(DataInputStream(bytes.toByteArray().inputStream()))
    }

    @Test
    fun framesRoundTrip() {
        val f = roundTrip(WatchProtocol.COMMAND, WatchProtocol.command(WatchProtocol.CMD_PAUSE))
        assertEquals(WatchProtocol.COMMAND, f.type)
        assertEquals(WatchProtocol.CMD_PAUSE, f.payload.single().toInt())
    }

    @Test
    fun oversizedFrameIsRejectedBeforeAllocating() {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).apply { writeByte(WatchProtocol.TILE); writeInt(Int.MAX_VALUE) }
        assertFailsWith<IOException> { WatchProtocol.readFrame(DataInputStream(bytes.toByteArray().inputStream())) }
    }

    @Test
    fun truncatedFrameFails() {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).apply { writeByte(WatchProtocol.STATE); writeInt(10); write(ByteArray(3)) }
        assertFailsWith<IOException> { WatchProtocol.readFrame(DataInputStream(bytes.toByteArray().inputStream())) }
    }

    @Test
    fun stateRoundTrips() {
        val s = WatchState(
            recording = WatchState.PAUSED, activeMs = 3_723_000, distanceM = 4851.2, ascentM = 612.0, imperial = true,
            hasFix = true, lat = 54.5271, lon = -3.0164, accuracyM = 4.5f, altitudeM = 949.0, fixTimeMs = 1_790_000_000_000, grid = "NY 342 151",
            routeId = 7, routeName = "Helvellyn via Striding Edge", toGoM = 1350.0, timeLeftMin = 38.0, climbLeftM = 191.0, progress = 0.72,
            offRoute = true, offRouteM = 105.0, backBearingDeg = 122.0, nextName = "Striding Edge", nextAlongM = 639.0,
            nextLat = 54.5264, nextLon = -3.0055, sunsetMs = 1_790_010_000_000, mapKey = "osm", attribution = "© OpenStreetMap contributors",
            mapMinZoom = 0, mapMaxZoom = 19, pressureHpa = 912.4, pressureChangeHpa = -4.3, aheadLat = 54.5268, aheadLon = -3.0101,
        )
        assertEquals(s, WatchState.decode(s.encode()))
        assertTrue(WatchState.decode(WatchState().encode()).targetLat.isNaN())
        // A state from an older phone, without the barometer and look-ahead fields, still decodes.
        val legacy = s.encode().copyOf(s.encode().size - 32)
        assertTrue(WatchState.decode(legacy).pressureHpa.isNaN())
        assertEquals(s.routeName, WatchState.decode(legacy).routeName)
    }

    @Test
    fun routeAndTrackRoundTripToMicrodegrees() {
        val pts = listOf(LatLon(54.543600, -2.950600), LatLon(54.527100, -3.016400))
        val r = WatchRoute(3, "Test", pts, listOf(WatchWaypoint("Summit", pts[1])))
        assertEquals(r, WatchRoute.decode(r.encode()))
        val t = WatchTrack(listOf(pts, pts.reversed()))
        assertEquals(t, WatchTrack.decode(t.encode()))
    }

    @Test
    fun tilesRoundTripAndBadCoordinatesAreRejected() {
        val req = TileRequest("osm", 15, 16100, 10420)
        assertEquals(req, TileRequest.decode(req.encode()))
        val reply = TileReply.decode(TileReply(req, byteArrayOf(1, 2, 3)).encode())
        assertEquals(req, reply.request)
        assertContentEquals(byteArrayOf(1, 2, 3), reply.bytes)
        assertNull(TileReply.decode(TileReply(req, null).encode()).bytes)
        assertFailsWith<IOException> { TileRequest.decode(TileRequest("osm", 3, 8, 0).encode()) }
    }

    @Test
    fun decimationKeepsEndsAndLimit() {
        val line = (0 until 10_001).map { LatLon(54.0 + it * 1e-5, -3.0) }
        val thin = WatchProtocol.decimate(line, 500)
        assertEquals(500, thin.size)
        assertEquals(line.first(), thin.first())
        assertEquals(line.last(), thin.last())
        val track = WatchTrack.of(listOf(line, line.take(1_000)), 1_100)
        assertTrue(track.segments.sumOf { it.size } <= 1_100)
        assertEquals(line.last(), track.segments[0].last())
    }
}
