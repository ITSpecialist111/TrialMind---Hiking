package com.trailmind.core.frontier

import java.io.ByteArrayOutputStream
import java.io.IOException

enum class EmergencyStatus(val wireValue: Int) {
    OK(0),
    MANUAL_CHECK_IN(1),
    DELAYED(2),
    INJURED_STATIONARY(3),
    INJURED_MOVING(4),
    FALL_DETECTED(5),
    CRITICAL_SOS(6);

    companion object {
        fun fromWire(value: Int) = entries.firstOrNull { it.wireValue == value } ?: OK
    }
}

data class HikerTelemetry(
    val hikerId: String,
    val latitude: Double,
    val longitude: Double,
    val altitudeMeters: Int,
    val batteryPercent: Int,
    val timestampEpochSeconds: Long,
    val status: EmergencyStatus = EmergencyStatus.OK,
    val triageCode: Int = 0,
) {
    init {
        require(hikerId.toByteArray(Charsets.UTF_8).size in 1..8) { "hikerId must be 1-8 UTF-8 bytes" }
        require(latitude in -90.0..90.0) { "latitude out of range" }
        require(longitude in -180.0..180.0) { "longitude out of range" }
        require(batteryPercent in 0..100) { "batteryPercent out of range" }
        require(timestampEpochSeconds >= 0) { "timestamp must be non-negative" }
        require(triageCode in 0..255) { "triageCode must fit in one byte" }
    }
}

data class FallVector(
    val impactGForce: Float,
    val freefallDurationSeconds: Float,
    val deltaAltitudeMeters: Float,
)

data class GroupMeshPayload(
    val gatewayDeviceId: String,
    val messageSequence: Long,
    val hikers: List<HikerTelemetry>,
    val fallTelemetry: FallVector? = null,
) {
    init {
        require(gatewayDeviceId.toByteArray(Charsets.UTF_8).size in 1..8) {
            "gatewayDeviceId must be 1-8 UTF-8 bytes"
        }
        require(messageSequence >= 0) { "messageSequence must be non-negative" }
        require(hikers.size <= 8) { "at most eight hikers are supported" }
    }
}

data class PackedGroupPayload(
    val bytes: ByteArray,
    val includedHikerIds: List<String>,
    val omittedHikerIds: List<String>,
)

/**
 * Proto3 wire codec for frontier_telemetry.proto. Keeping this small codec in core avoids making
 * offline communication depend on generated-code runtimes while remaining protobuf-compatible.
 */
object FrontierTelemetryCodec {
    const val MAX_PAYLOAD_BYTES = 256

    fun encode(payload: GroupMeshPayload): ByteArray {
        val bytes = encodeUnchecked(payload)
        require(bytes.size <= MAX_PAYLOAD_BYTES) {
            "frontier payload is ${bytes.size} bytes; maximum is $MAX_PAYLOAD_BYTES"
        }
        return bytes
    }

    /**
     * Builds a legal micro-payload and reports any hikers that could not fit. Emergency records are
     * considered first, then the newest records. Callers must queue omitted records for a later SMS.
     */
    fun pack(payload: GroupMeshPayload): PackedGroupPayload {
        val ordered = payload.hikers.sortedWith(
            compareByDescending<HikerTelemetry> { it.status.wireValue }
                .thenByDescending { it.timestampEpochSeconds },
        )
        val included = ArrayList<HikerTelemetry>(ordered.size)
        for (hiker in ordered) {
            val candidate = payload.copy(hikers = included + hiker)
            if (encodeUnchecked(candidate).size <= MAX_PAYLOAD_BYTES) included += hiker
        }
        val selectedIds = included.mapTo(HashSet()) { it.hikerId }
        val selected = payload.copy(hikers = included)
        return PackedGroupPayload(
            bytes = encode(selected),
            includedHikerIds = included.map { it.hikerId },
            omittedHikerIds = ordered.filterNot { it.hikerId in selectedIds }.map { it.hikerId },
        )
    }

    fun decode(bytes: ByteArray): GroupMeshPayload {
        require(bytes.size <= MAX_PAYLOAD_BYTES) {
            "frontier payload is ${bytes.size} bytes; maximum is $MAX_PAYLOAD_BYTES"
        }
        try {
            val reader = ProtoReader(bytes)
            var gatewayId = ""
            var sequence = 0L
            val hikers = ArrayList<HikerTelemetry>()
            var fall: FallVector? = null
            while (!reader.exhausted()) {
                val tag = reader.varint().toInt()
                when (tag ushr 3) {
                    1 -> gatewayId = reader.string(tag)
                    2 -> sequence = reader.varintField(tag)
                    3 -> hikers += decodeHiker(reader.bytes(tag))
                    4 -> fall = decodeFall(reader.bytes(tag))
                    else -> reader.skip(tag)
                }
            }
            return GroupMeshPayload(gatewayId, sequence, hikers, fall)
        } catch (e: IllegalArgumentException) {
            throw IOException("invalid frontier protobuf payload", e)
        }
    }

    private fun encodeUnchecked(payload: GroupMeshPayload): ByteArray = ProtoWriter().apply {
        string(1, payload.gatewayDeviceId)
        uint64(2, payload.messageSequence)
        payload.hikers.forEach { message(3, encodeHiker(it)) }
        payload.fallTelemetry?.let { message(4, encodeFall(it)) }
    }.bytes()

    private fun encodeHiker(hiker: HikerTelemetry) = ProtoWriter().apply {
        string(1, hiker.hikerId)
        double(2, hiker.latitude)
        double(3, hiker.longitude)
        int32(4, hiker.altitudeMeters)
        uint32(5, hiker.batteryPercent)
        uint64(6, hiker.timestampEpochSeconds)
        enum(7, hiker.status.wireValue)
        uint32(8, hiker.triageCode)
    }.bytes()

    private fun decodeHiker(bytes: ByteArray): HikerTelemetry {
        val reader = ProtoReader(bytes)
        var id = ""
        var lat = 0.0
        var lon = 0.0
        var altitude = 0
        var battery = 0
        var timestamp = 0L
        var status = EmergencyStatus.OK
        var triage = 0
        while (!reader.exhausted()) {
            val tag = reader.varint().toInt()
            when (tag ushr 3) {
                1 -> id = reader.string(tag)
                2 -> lat = reader.double(tag)
                3 -> lon = reader.double(tag)
                4 -> altitude = reader.varintField(tag).toInt()
                5 -> battery = reader.varintField(tag).toInt()
                6 -> timestamp = reader.varintField(tag)
                7 -> status = EmergencyStatus.fromWire(reader.varintField(tag).toInt())
                8 -> triage = reader.varintField(tag).toInt()
                else -> reader.skip(tag)
            }
        }
        return HikerTelemetry(id, lat, lon, altitude, battery, timestamp, status, triage)
    }

    private fun encodeFall(fall: FallVector) = ProtoWriter().apply {
        float(1, fall.impactGForce)
        float(2, fall.freefallDurationSeconds)
        float(3, fall.deltaAltitudeMeters)
    }.bytes()

    private fun decodeFall(bytes: ByteArray): FallVector {
        val reader = ProtoReader(bytes)
        var impact = 0f
        var duration = 0f
        var altitude = 0f
        while (!reader.exhausted()) {
            val tag = reader.varint().toInt()
            when (tag ushr 3) {
                1 -> impact = reader.float(tag)
                2 -> duration = reader.float(tag)
                3 -> altitude = reader.float(tag)
                else -> reader.skip(tag)
            }
        }
        return FallVector(impact, duration, altitude)
    }
}

private class ProtoWriter {
    private val out = ByteArrayOutputStream()

    fun string(field: Int, value: String) {
        if (value.isEmpty()) return
        val bytes = value.toByteArray(Charsets.UTF_8)
        tag(field, 2)
        varint(bytes.size.toLong())
        out.write(bytes)
    }

    fun message(field: Int, value: ByteArray) {
        tag(field, 2)
        varint(value.size.toLong())
        out.write(value)
    }

    fun double(field: Int, value: Double) {
        if (value == 0.0) return
        tag(field, 1)
        fixed64(value.toRawBits())
    }

    fun float(field: Int, value: Float) {
        if (value == 0f) return
        tag(field, 5)
        fixed32(value.toRawBits())
    }

    fun int32(field: Int, value: Int) {
        if (value == 0) return
        tag(field, 0)
        varint(value.toLong())
    }

    fun uint32(field: Int, value: Int) {
        if (value == 0) return
        tag(field, 0)
        varint(value.toLong() and 0xffff_ffffL)
    }

    fun uint64(field: Int, value: Long) {
        if (value == 0L) return
        tag(field, 0)
        varint(value)
    }

    fun enum(field: Int, value: Int) = uint32(field, value)
    fun bytes(): ByteArray = out.toByteArray()

    private fun tag(field: Int, wireType: Int) = varint(((field shl 3) or wireType).toLong())

    private fun varint(value: Long) {
        var remaining = value
        while (remaining and -128L != 0L) {
            out.write(((remaining and 0x7f) or 0x80).toInt())
            remaining = remaining ushr 7
        }
        out.write(remaining.toInt())
    }

    private fun fixed32(value: Int) {
        repeat(4) { shift -> out.write(value ushr (shift * 8)) }
    }

    private fun fixed64(value: Long) {
        repeat(8) { shift -> out.write((value ushr (shift * 8)).toInt()) }
    }
}

private class ProtoReader(private val data: ByteArray) {
    private var offset = 0

    fun exhausted() = offset == data.size

    fun varint(): Long {
        var result = 0L
        var shift = 0
        while (shift < 64) {
            if (offset >= data.size) throw IOException("truncated protobuf varint")
            val byte = data[offset++].toInt() and 0xff
            result = result or ((byte and 0x7f).toLong() shl shift)
            if (byte and 0x80 == 0) return result
            shift += 7
        }
        throw IOException("malformed protobuf varint")
    }

    fun varintField(tag: Int): Long {
        requireWire(tag, 0)
        return varint()
    }

    fun string(tag: Int) = bytes(tag).toString(Charsets.UTF_8)

    fun bytes(tag: Int): ByteArray {
        requireWire(tag, 2)
        val size = varint().toInt()
        if (size < 0 || offset + size > data.size) throw IOException("truncated protobuf field")
        return data.copyOfRange(offset, offset + size).also { offset += size }
    }

    fun double(tag: Int): Double {
        requireWire(tag, 1)
        return Double.fromBits(fixed64())
    }

    fun float(tag: Int): Float {
        requireWire(tag, 5)
        return Float.fromBits(fixed32())
    }

    fun skip(tag: Int) {
        when (tag and 7) {
            0 -> varint()
            1 -> take(8)
            2 -> take(varint().toInt())
            5 -> take(4)
            else -> throw IOException("unsupported protobuf wire type ${tag and 7}")
        }
    }

    private fun fixed32(): Int {
        take(4)
        var result = 0
        for (i in 0 until 4) result = result or ((data[offset - 4 + i].toInt() and 0xff) shl (i * 8))
        return result
    }

    private fun fixed64(): Long {
        take(8)
        var result = 0L
        for (i in 0 until 8) result = result or ((data[offset - 8 + i].toLong() and 0xff) shl (i * 8))
        return result
    }

    private fun take(count: Int) {
        if (count < 0 || offset + count > data.size) throw IOException("truncated protobuf field")
        offset += count
    }

    private fun requireWire(tag: Int, expected: Int) {
        if (tag and 7 != expected) throw IOException("unexpected protobuf wire type ${tag and 7}")
    }
}
