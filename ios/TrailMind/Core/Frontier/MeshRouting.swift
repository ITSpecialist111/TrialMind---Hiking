import Foundation

struct GatewayCandidate: Hashable {
    var deviceId: String
    var hasActiveNtnSignal: Bool
    var batteryPercent: Int
    var processingRank: Int
    var isGalaxyFold7: Bool

    init(deviceId: String, hasActiveNtnSignal: Bool, batteryPercent: Int, processingRank: Int, isGalaxyFold7: Bool = false) throws {
        try FrontierError.require(!FrontierCompat.isBlank(deviceId), "deviceId is required")
        try FrontierError.require((0...100).contains(batteryPercent), "batteryPercent out of range")
        try FrontierError.require(processingRank >= 0, "processingRank must be non-negative")
        self.deviceId = deviceId
        self.hasActiveNtnSignal = hasActiveNtnSignal
        self.batteryPercent = batteryPercent
        self.processingRank = processingRank
        self.isGalaxyFold7 = isGalaxyFold7
    }
}

enum GatewayElection {
    /// Kotlin's `maxWithOrNull`: by NTN signal, battery, Fold7, processing rank, then the lowest device id. The first
    /// of equals wins.
    static func elect<C: Collection>(_ candidates: C) -> GatewayCandidate? where C.Element == GatewayCandidate {
        var best: GatewayCandidate? = nil
        for candidate in candidates {
            if let max = best {
                if compare(max, candidate) < 0 { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    private static func compare(_ a: GatewayCandidate, _ b: GatewayCandidate) -> Int {
        if a.hasActiveNtnSignal != b.hasActiveNtnSignal { return a.hasActiveNtnSignal ? 1 : -1 }
        if a.batteryPercent != b.batteryPercent { return a.batteryPercent < b.batteryPercent ? -1 : 1 }
        if a.isGalaxyFold7 != b.isGalaxyFold7 { return a.isGalaxyFold7 ? 1 : -1 }
        if a.processingRank != b.processingRank { return a.processingRank < b.processingRank ? -1 : 1 }
        return FrontierCompat.compare(b.deviceId, a.deviceId)
    }
}

struct MeshPacket: Hashable {
    static let maxTtl = 3

    var packetId: Int64
    var originDeviceId: String
    var sequence: Int64
    var ttl: Int
    var payload: [UInt8]

    init(packetId: Int64, originDeviceId: String, sequence: Int64, ttl: Int = MeshPacket.maxTtl, payload: [UInt8]) throws {
        try FrontierError.require(packetId >= 0, "packetId must be non-negative")
        try FrontierError.require(!FrontierCompat.isBlank(originDeviceId), "originDeviceId is required")
        try FrontierError.require(sequence >= 0, "sequence must be non-negative")
        try FrontierError.require((0...MeshPacket.maxTtl).contains(ttl), "ttl must be between 0 and \(MeshPacket.maxTtl)")
        try FrontierError.require(payload.count <= FrontierTelemetryCodec.maxPayloadBytes, "payload exceeds micro-payload limit")
        self.packetId = packetId
        self.originDeviceId = originDeviceId
        self.sequence = sequence
        self.ttl = ttl
        self.payload = payload
    }
}

final class MeshRelayDeduplicator {
    private let retentionMs: Int64
    private let maxEntries: Int
    /// Kotlin's `LinkedHashMap<Long, Long>`: when each packet id was first seen, oldest first in `order`.
    private var seen: [Int64: Int64] = [:]
    private var order: [Int64] = []
    private let lock = NSLock()

    init(retentionMs: Int64 = 5 * 60_000, maxEntries: Int = 2_048) throws {
        try FrontierError.require(retentionMs > 0, "retentionMs must be positive")
        try FrontierError.require(maxEntries > 0, "maxEntries must be positive")
        self.retentionMs = retentionMs
        self.maxEntries = maxEntries
    }

    func accept(_ packet: MeshPacket, nowMs: Int64) -> MeshPacket? {
        lock.lock()
        defer { lock.unlock() }
        prune(nowMs)
        if seen[packet.packetId] != nil { return nil }
        seen[packet.packetId] = nowMs
        order.append(packet.packetId)
        while seen.count > maxEntries { seen[order.removeFirst()] = nil }
        guard packet.ttl > 0 else { return nil }
        var relayed = packet
        relayed.ttl = packet.ttl - 1
        return relayed
    }

    func hasSeen(_ packetId: Int64, nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prune(nowMs)
        return seen[packetId] != nil
    }

    private func prune(_ nowMs: Int64) {
        var kept: [Int64] = []
        kept.reserveCapacity(order.count)
        for id in order {
            if let firstSeen = seen[id], nowMs - firstSeen > retentionMs {
                seen[id] = nil
            } else {
                kept.append(id)
            }
        }
        order = kept
    }
}
