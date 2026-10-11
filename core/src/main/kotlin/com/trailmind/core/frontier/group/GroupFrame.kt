package com.trailmind.core.frontier.group

import com.trailmind.core.frontier.EmergencyStatus
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/** Statuses a trip group treats as a call for help: relayed first and further, and alerted on other phones. */
val EmergencyStatus.needsHelp: Boolean get() = wireValue >= EmergencyStatus.INJURED_STATIONARY.wireValue

/** What one phone says about one member. Every frame is [GroupFrames.SIZE] bytes before it is sealed. */
sealed interface GroupFrame {
    val memberId: Int
    val hops: Int
    val ttl: Int
    val needsHelp: Boolean get() = (this as? PositionFrame)?.status?.needsHelp == true

    /** The copy another phone passes on, or null once it has travelled as far as it may. */
    fun relayed(): GroupFrame?
}

data class PositionFrame(
    override val memberId: Int,
    val sequence: Long,
    val originTimeS: Long,
    val latE7: Int,
    val lonE7: Int,
    val altitudeM: Int?,
    val accuracyM: Int,
    val batteryPercent: Int,
    val status: EmergencyStatus,
    val triageCode: Int = 0,
    override val hops: Int = 0,
    override val ttl: Int = GroupFrames.TTL,
    val capabilities: Int = 0,
    val flags: Int = 0,
) : GroupFrame {
    init {
        require(sequence in 0..0xFFFF_FFFFL) { "sequence out of range" }
        require(originTimeS in 0..0xFFFF_FFFFL) { "origin time out of range" }
        require(latE7 in -900_000_000..900_000_000) { "latitude out of range" }
        require(lonE7 in -1_800_000_000..1_800_000_000) { "longitude out of range" }
        require(altitudeM == null || altitudeM in (Short.MIN_VALUE + 1)..Short.MAX_VALUE) { "altitude out of range" }
        require(accuracyM in 0..255 && batteryPercent in 0..100 && triageCode in 0..255) { "byte field out of range" }
        require(hops in 0..15 && ttl in 0..15 && capabilities in 0..255 && flags in 0..15) { "header field out of range" }
    }

    val lat: Double get() = latE7 / 1e7
    val lon: Double get() = lonE7 / 1e7

    override fun relayed(): PositionFrame? = if (ttl > 0) copy(ttl = ttl - 1, hops = minOf(hops + 1, 15)) else null

    companion object {
        fun of(
            memberId: Int, sequence: Long, originTimeS: Long, lat: Double, lon: Double, altitudeM: Double?, accuracyM: Float,
            batteryPercent: Int, status: EmergencyStatus, triageCode: Int = 0, capabilities: Int = 0, flags: Int = 0,
        ) = PositionFrame(
            memberId = memberId, sequence = sequence, originTimeS = originTimeS,
            latE7 = (lat * 1e7).roundToInt(), lonE7 = (lon * 1e7).roundToInt(),
            altitudeM = altitudeM?.roundToInt()?.coerceIn(Short.MIN_VALUE + 1, Short.MAX_VALUE.toInt()),
            accuracyM = accuracyM.roundToInt().coerceIn(0, 255), batteryPercent = batteryPercent.coerceIn(0, 100),
            status = status, triageCode = triageCode.coerceIn(0, 255),
            ttl = if (status.needsHelp) GroupFrames.SOS_TTL else GroupFrames.TTL,
            capabilities = capabilities, flags = flags,
        )
    }
}

/** The name and colour a member picked, so other phones can label them. */
data class ProfileFrame(
    override val memberId: Int,
    val colour: Int,
    val name: String,
    override val hops: Int = 0,
    override val ttl: Int = GroupFrames.TTL,
) : GroupFrame {
    init {
        require(colour in 0..255 && hops in 0..15 && ttl in 0..15) { "profile field out of range" }
    }

    override fun relayed(): ProfileFrame? = if (ttl > 0) copy(ttl = ttl - 1, hops = minOf(hops + 1, 15)) else null
}

/** The fixed 30-byte plaintext layout of each frame (appendix A of the group sharing plan). Integers are big-endian. */
object GroupFrames {
    const val SIZE = 30
    const val TTL = 2
    const val SOS_TTL = 3
    const val NAME_BYTES = 23
    const val TYPE_POSITION = 1
    const val TYPE_PROFILE = 2
    const val TYPE_RANGE = 3

    const val CAP_CODED_TX = 1
    const val CAP_CODED_RX = 2
    const val CAP_RELAY = 4
    const val CAP_SATELLITE = 8
    /** Can be found with UWB using provisioned STS ([UwbSession.CONFIG_PROVISIONED]). */
    const val CAP_UWB = 16
    /** Can be found with UWB using static STS ([UwbSession.CONFIG_STATIC]). */
    const val CAP_UWB_STATIC = 32

    const val FLAG_RECORDING = 1
    const val FLAG_PAUSED = 2
    /** The hike being recorded is one the whole trip group is invited to record (see [GroupHikeWatch]). */
    const val FLAG_GROUP_HIKE = 4

    private const val UNKNOWN_ALTITUDE = Short.MIN_VALUE.toInt()

    fun encode(frame: GroupFrame): ByteArray {
        val b = ByteBuffer.allocate(SIZE)
        when (frame) {
            is PositionFrame -> {
                b.put(((TYPE_POSITION shl 4) or frame.flags).toByte())
                b.putInt(frame.memberId)
                b.putInt(frame.sequence.toInt())
                b.putInt(frame.originTimeS.toInt())
                b.putInt(frame.latE7)
                b.putInt(frame.lonE7)
                b.putShort((frame.altitudeM ?: UNKNOWN_ALTITUDE).toShort())
                b.put(frame.accuracyM.toByte())
                b.put(frame.batteryPercent.toByte())
                b.put(frame.status.wireValue.toByte())
                b.put(frame.triageCode.toByte())
                b.put(((frame.hops shl 4) or frame.ttl).toByte())
                b.put(frame.capabilities.toByte())
            }
            is ProfileFrame -> {
                b.put((TYPE_PROFILE shl 4).toByte())
                b.putInt(frame.memberId)
                b.put(frame.colour.toByte())
                b.put(nameBytes(frame.name))
                b.position(SIZE - 1)
                b.put(((frame.hops shl 4) or frame.ttl).toByte())
            }
            is RangeFrame -> {
                b.put(((TYPE_RANGE shl 4) or frame.kind).toByte())
                b.putInt(frame.memberId)
                b.putInt(frame.targetId)
                b.putLong(frame.nonce)
                b.putInt(frame.timeS.toInt())
                b.put(frame.configId.toByte())
                b.put(frame.channel.toByte())
                b.put(frame.preambleIndex.toByte())
                b.put(frame.updateRate.toByte())
                b.put(frame.reason.toByte())
            }
        }
        return b.array()
    }

    /** The frame in [bytes], or null if it isn't a frame this version understands. */
    fun decode(bytes: ByteArray): GroupFrame? {
        if (bytes.size != SIZE) return null
        val b = ByteBuffer.wrap(bytes)
        val head = b.get().toInt() and 0xFF
        val memberId = b.int
        return runCatching {
            when (head ushr 4) {
                TYPE_POSITION -> {
                    val sequence = b.int.toLong() and 0xFFFF_FFFFL
                    val origin = b.int.toLong() and 0xFFFF_FFFFL
                    val lat = b.int
                    val lon = b.int
                    val alt = b.short.toInt().takeIf { it != UNKNOWN_ALTITUDE }
                    val accuracy = b.get().toInt() and 0xFF
                    val battery = b.get().toInt() and 0xFF
                    val status = EmergencyStatus.fromWire(b.get().toInt() and 0xFF)
                    val triage = b.get().toInt() and 0xFF
                    val route = b.get().toInt() and 0xFF
                    val capabilities = b.get().toInt() and 0xFF
                    PositionFrame(memberId, sequence, origin, lat, lon, alt, accuracy, battery, status, triage,
                        hops = route ushr 4, ttl = route and 0xF, capabilities = capabilities, flags = head and 0xF)
                }
                TYPE_PROFILE -> {
                    val colour = b.get().toInt() and 0xFF
                    val name = ByteArray(NAME_BYTES).also { b.get(it) }
                    val route = b.get().toInt() and 0xFF
                    val end = name.indexOf(0).let { if (it < 0) NAME_BYTES else it }
                    ProfileFrame(memberId, colour, String(name, 0, end, Charsets.UTF_8), hops = route ushr 4, ttl = route and 0xF)
                }
                TYPE_RANGE -> RangeFrame(
                    memberId = memberId, targetId = b.int, kind = head and 0xF, nonce = b.long, timeS = b.int.toLong() and 0xFFFF_FFFFL,
                    configId = b.get().toInt() and 0xFF, channel = b.get().toInt() and 0xFF, preambleIndex = b.get().toInt() and 0xFF,
                    updateRate = b.get().toInt() and 0xFF, reason = b.get().toInt() and 0xFF,
                )
                else -> null
            }
        }.getOrNull()
    }

    /** [name] as UTF-8, cut at a character boundary to fit [NAME_BYTES]. */
    fun nameBytes(name: String): ByteArray {
        val out = java.io.ByteArrayOutputStream(NAME_BYTES)
        var i = 0
        val trimmed = name.trim()
        while (i < trimmed.length) {
            val cp = trimmed.codePointAt(i)
            val bytes = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8)
            if (out.size() + bytes.size > NAME_BYTES) break
            out.write(bytes)
            i += Character.charCount(cp)
        }
        return out.toByteArray()
    }
}
