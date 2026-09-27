package com.trailmind.core.frontier

data class GatewayCandidate(
    val deviceId: String,
    val hasActiveNtnSignal: Boolean,
    val batteryPercent: Int,
    val processingRank: Int,
    val isGalaxyFold7: Boolean = false,
) {
    init {
        require(deviceId.isNotBlank()) { "deviceId is required" }
        require(batteryPercent in 0..100) { "batteryPercent out of range" }
        require(processingRank >= 0) { "processingRank must be non-negative" }
    }
}

object GatewayElection {
    fun elect(candidates: Collection<GatewayCandidate>): GatewayCandidate? =
        candidates.maxWithOrNull(
            compareBy<GatewayCandidate> { it.hasActiveNtnSignal }
                .thenBy { it.batteryPercent }
                .thenBy { it.isGalaxyFold7 }
                .thenBy { it.processingRank }
                .thenByDescending { it.deviceId },
        )
}

data class MeshPacket(
    val packetId: Long,
    val originDeviceId: String,
    val sequence: Long,
    val ttl: Int = MAX_TTL,
    val payload: ByteArray,
) {
    init {
        require(packetId >= 0) { "packetId must be non-negative" }
        require(originDeviceId.isNotBlank()) { "originDeviceId is required" }
        require(sequence >= 0) { "sequence must be non-negative" }
        require(ttl in 0..MAX_TTL) { "ttl must be between 0 and $MAX_TTL" }
        require(payload.size <= FrontierTelemetryCodec.MAX_PAYLOAD_BYTES) { "payload exceeds micro-payload limit" }
    }

    companion object {
        const val MAX_TTL = 3
    }
}

class MeshRelayDeduplicator(
    private val retentionMs: Long = 5 * 60_000L,
    private val maxEntries: Int = 2_048,
) {
    private val seen = LinkedHashMap<Long, Long>()

    init {
        require(retentionMs > 0) { "retentionMs must be positive" }
        require(maxEntries > 0) { "maxEntries must be positive" }
    }

    @Synchronized
    fun accept(packet: MeshPacket, nowMs: Long): MeshPacket? {
        prune(nowMs)
        if (seen.putIfAbsent(packet.packetId, nowMs) != null) return null
        while (seen.size > maxEntries) seen.remove(seen.keys.first())
        return if (packet.ttl > 0) packet.copy(ttl = packet.ttl - 1) else null
    }

    @Synchronized
    fun hasSeen(packetId: Long, nowMs: Long): Boolean {
        prune(nowMs)
        return packetId in seen
    }

    private fun prune(nowMs: Long) {
        val iterator = seen.iterator()
        while (iterator.hasNext()) {
            if (nowMs - iterator.next().value > retentionMs) iterator.remove()
        }
    }
}
