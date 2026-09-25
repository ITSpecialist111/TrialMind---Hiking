package com.trailmind.core.watch

import com.trailmind.core.geo.LatLon
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import kotlin.math.roundToInt

/**
 * Phone ↔ watch messages over a Bluetooth RFCOMM socket, framed as `[type: u8][length: i32][payload]`.
 * Both apps use this file, so the encoding cannot drift between them.
 */
object WatchProtocol {
    const val VERSION = 1

    /** RFCOMM service record the phone listens on and the watch connects to. */
    const val SERVICE_UUID = "4f1b8a2e-7c3d-4e59-9a61-2d8f0c5b7e13"
    const val MAX_FRAME_BYTES = 1 shl 20
    const val MAX_POINTS = 20_000
    const val MAX_TILE_ZOOM = 22

    const val HELLO = 1
    const val STATE = 2
    const val ROUTE = 3
    const val TRACK = 4
    const val TILE_REQUEST = 5
    const val TILE = 6
    const val COMMAND = 7
    const val ALERT = 8

    const val CMD_START = 1
    const val CMD_PAUSE = 2
    const val CMD_RESUME = 3
    const val CMD_FINISH = 4
    const val CMD_TRACBACK = 5
    /** The watch app came on screen or left it; the phone sends updates less often while it's hidden. */
    const val CMD_WATCH_VISIBLE = 6
    const val CMD_WATCH_HIDDEN = 7

    const val ALERT_OFF_ROUTE = 1
    const val ALERT_BACK_ON_ROUTE = 2
    const val ALERT_INFO = 3
    const val ALERT_WEATHER = 4

    class Frame(val type: Int, val payload: ByteArray)

    fun writeFrame(out: DataOutputStream, type: Int, payload: ByteArray) {
        require(payload.size <= MAX_FRAME_BYTES) { "frame too large: ${payload.size}" }
        out.writeByte(type)
        out.writeInt(payload.size)
        out.write(payload)
        out.flush()
    }

    /** Rejects lengths a well-behaved peer never sends, so a misbehaving one can't exhaust memory. */
    fun readFrame(input: DataInputStream): Frame {
        val type = input.readUnsignedByte()
        val len = input.readInt()
        if (len < 0 || len > MAX_FRAME_BYTES) throw IOException("bad frame length $len")
        val payload = ByteArray(len)
        input.readFully(payload)
        return Frame(type, payload)
    }

    fun encode(block: DataOutputStream.() -> Unit): ByteArray =
        ByteArrayOutputStream().also { bytes -> DataOutputStream(bytes).use { it.block() } }.toByteArray()

    fun reader(bytes: ByteArray) = DataInputStream(bytes.inputStream())

    fun hello(appVersion: String) = encode { writeInt(VERSION); writeUTF(appVersion) }
    fun command(code: Int) = encode { writeByte(code) }
    fun alert(kind: Int, text: String) = encode { writeByte(kind); writeUTF(text) }

    fun writePoints(out: DataOutputStream, points: List<LatLon>) {
        out.writeInt(points.size)
        for (p in points) {
            out.writeInt((p.lat * 1e6).roundToInt())
            out.writeInt((p.lon * 1e6).roundToInt())
        }
    }

    fun readPoints(input: DataInputStream): List<LatLon> {
        val n = input.readInt()
        if (n < 0 || n > MAX_POINTS) throw IOException("bad point count $n")
        return List(n) { LatLon(input.readInt() / 1e6, input.readInt() / 1e6) }
    }

    /** Evenly thins a line to at most [max] points, keeping both ends (a watch can't show more detail). */
    fun decimate(points: List<LatLon>, max: Int): List<LatLon> {
        if (points.size <= max) return points
        if (max < 2) return points.take(max)
        val step = (points.size - 1).toDouble() / (max - 1)
        return List(max) { i -> points[(i * step).roundToInt().coerceAtMost(points.size - 1)] }
    }
}

data class TileRequest(val mapKey: String, val z: Int, val x: Int, val y: Int) {
    fun encode() = WatchProtocol.encode { writeUTF(mapKey); writeByte(z); writeInt(x); writeInt(y) }

    companion object {
        fun decode(bytes: ByteArray): TileRequest = WatchProtocol.reader(bytes).run {
            val key = readUTF()
            val z = readUnsignedByte()
            val x = readInt()
            val y = readInt()
            if (z > WatchProtocol.MAX_TILE_ZOOM || x !in 0 until (1 shl z) || y !in 0 until (1 shl z)) throw IOException("bad tile $z/$x/$y")
            TileRequest(key, z, x, y)
        }
    }
}

/** A map tile for the watch; [bytes] is null when the phone has no tile for that key (offline, 404…). */
class TileReply(val request: TileRequest, val bytes: ByteArray?) {
    fun encode() = WatchProtocol.encode {
        write(request.encode())
        writeInt(bytes?.size ?: 0)
        bytes?.let { write(it) }
    }

    companion object {
        fun decode(bytes: ByteArray): TileReply = WatchProtocol.reader(bytes).run {
            val key = readUTF()
            val req = TileRequest(key, readUnsignedByte(), readInt(), readInt())
            val n = readInt()
            if (n < 0 || n > WatchProtocol.MAX_FRAME_BYTES) throw IOException("bad tile size $n")
            TileReply(req, if (n == 0) null else ByteArray(n).also { readFully(it) })
        }
    }
}

data class WatchWaypoint(val name: String, val position: LatLon)

/** The followed route, thinned for the watch. [id] is -1 when nothing is being followed. */
data class WatchRoute(val id: Long, val name: String, val points: List<LatLon>, val waypoints: List<WatchWaypoint>) {
    fun encode() = WatchProtocol.encode {
        writeLong(id)
        writeUTF(name)
        WatchProtocol.writePoints(this, points)
        writeInt(waypoints.size)
        waypoints.forEach { writeUTF(it.name); WatchProtocol.writePoints(this, listOf(it.position)) }
    }

    companion object {
        val NONE = WatchRoute(-1, "", emptyList(), emptyList())

        fun decode(bytes: ByteArray): WatchRoute = WatchProtocol.reader(bytes).run {
            val id = readLong()
            val name = readUTF()
            val points = WatchProtocol.readPoints(this)
            val n = readInt()
            if (n < 0 || n > WatchProtocol.MAX_POINTS) throw IOException("bad waypoint count $n")
            WatchRoute(id, name, points, List(n) { WatchWaypoint(readUTF(), WatchProtocol.readPoints(this).single()) })
        }
    }
}

/** The recorded breadcrumb, one list per segment (a pause starts a new segment). */
data class WatchTrack(val segments: List<List<LatLon>>) {
    fun encode() = WatchProtocol.encode {
        writeInt(segments.size)
        segments.forEach { WatchProtocol.writePoints(this, it) }
    }

    companion object {
        fun decode(bytes: ByteArray): WatchTrack = WatchProtocol.reader(bytes).run {
            val n = readInt()
            if (n < 0 || n > WatchProtocol.MAX_POINTS) throw IOException("bad segment count $n")
            WatchTrack(List(n) { WatchProtocol.readPoints(this) })
        }

        /** Thins every segment in proportion to its length so the whole track fits in [max] points. */
        fun of(segments: List<List<LatLon>>, max: Int): WatchTrack {
            val total = segments.sumOf { it.size }
            if (total <= max) return WatchTrack(segments)
            return WatchTrack(segments.map { s -> WatchProtocol.decimate(s, maxOf(2, s.size * max / total)) })
        }
    }
}

/** Everything the watch shows, sent whenever it changes (at most about once a second). NaN means "unknown". */
data class WatchState(
    val recording: Int = IDLE,
    val activeMs: Long = 0,
    val distanceM: Double = 0.0,
    val ascentM: Double = 0.0,
    val imperial: Boolean = false,
    val hasFix: Boolean = false,
    val lat: Double = 0.0,
    val lon: Double = 0.0,
    val accuracyM: Float = 0f,
    val altitudeM: Double = Double.NaN,
    val fixTimeMs: Long = 0,
    val grid: String = "",
    val routeId: Long = -1,
    val routeName: String = "",
    val toGoM: Double = Double.NaN,
    val timeLeftMin: Double = Double.NaN,
    val climbLeftM: Double = Double.NaN,
    val progress: Double = Double.NaN,
    val offRoute: Boolean = false,
    val offRouteM: Double = 0.0,
    val backBearingDeg: Double = Double.NaN,
    val nextName: String = "",
    val nextAlongM: Double = Double.NaN,
    val nextLat: Double = Double.NaN,
    val nextLon: Double = Double.NaN,
    val targetLat: Double = Double.NaN,
    val targetLon: Double = Double.NaN,
    val sunsetMs: Long = 0,
    val mapKey: String = "",
    val attribution: String = "",
    val mapMinZoom: Int = 0,
    val mapMaxZoom: Int = 19,
    /** Station pressure, and the change in sea-level pressure over the last 3 hours (negative = falling). */
    val pressureHpa: Double = Double.NaN,
    val pressureChangeHpa: Double = Double.NaN,
    /** A point a little way ahead along the followed line: the direction to walk to stay on it. */
    val aheadLat: Double = Double.NaN,
    val aheadLon: Double = Double.NaN,
) {
    val following get() = routeId >= 0

    fun encode() = WatchProtocol.encode {
        writeByte(recording); writeLong(activeMs); writeDouble(distanceM); writeDouble(ascentM); writeBoolean(imperial)
        writeBoolean(hasFix); writeDouble(lat); writeDouble(lon); writeFloat(accuracyM); writeDouble(altitudeM); writeLong(fixTimeMs); writeUTF(grid)
        writeLong(routeId); writeUTF(routeName); writeDouble(toGoM); writeDouble(timeLeftMin); writeDouble(climbLeftM); writeDouble(progress)
        writeBoolean(offRoute); writeDouble(offRouteM); writeDouble(backBearingDeg)
        writeUTF(nextName); writeDouble(nextAlongM); writeDouble(nextLat); writeDouble(nextLon)
        writeDouble(targetLat); writeDouble(targetLon); writeLong(sunsetMs)
        writeUTF(mapKey); writeUTF(attribution); writeByte(mapMinZoom); writeByte(mapMaxZoom)
        writeDouble(pressureHpa); writeDouble(pressureChangeHpa); writeDouble(aheadLat); writeDouble(aheadLon)
    }

    companion object {
        const val IDLE = 0
        const val RECORDING = 1
        const val PAUSED = 2

        fun decode(bytes: ByteArray): WatchState = WatchProtocol.reader(bytes).run {
            WatchState(
                recording = readUnsignedByte(), activeMs = readLong(), distanceM = readDouble(), ascentM = readDouble(), imperial = readBoolean(),
                hasFix = readBoolean(), lat = readDouble(), lon = readDouble(), accuracyM = readFloat(), altitudeM = readDouble(), fixTimeMs = readLong(), grid = readUTF(),
                routeId = readLong(), routeName = readUTF(), toGoM = readDouble(), timeLeftMin = readDouble(), climbLeftM = readDouble(), progress = readDouble(),
                offRoute = readBoolean(), offRouteM = readDouble(), backBearingDeg = readDouble(),
                nextName = readUTF(), nextAlongM = readDouble(), nextLat = readDouble(), nextLon = readDouble(),
                targetLat = readDouble(), targetLon = readDouble(), sunsetMs = readLong(),
                mapKey = readUTF(), attribution = readUTF(), mapMinZoom = readUnsignedByte(), mapMaxZoom = readUnsignedByte(),
                // Absent when the phone runs an older TrailMind.
                pressureHpa = if (available() >= 8) readDouble() else Double.NaN,
                pressureChangeHpa = if (available() >= 8) readDouble() else Double.NaN,
                aheadLat = if (available() >= 8) readDouble() else Double.NaN,
                aheadLon = if (available() >= 8) readDouble() else Double.NaN,
            )
        }
    }
}
