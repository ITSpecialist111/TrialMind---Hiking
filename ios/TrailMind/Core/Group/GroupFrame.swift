import Foundation

extension EmergencyStatus {
    /// Statuses a trip group treats as a call for help: relayed first and further, and alerted on other phones.
    var needsHelp: Bool { wireValue >= EmergencyStatus.injuredStationary.wireValue }
}

/// What one phone says about one member. Every frame is `GroupFrames.size` bytes before it is sealed.
/// Kotlin's sealed interface: the only frames are `PositionFrame`, `ProfileFrame` and `RangeFrame`.
protocol GroupFrame: Hashable {
    var memberId: Int { get }
    var hops: Int { get }
    var ttl: Int { get }
    var needsHelp: Bool { get }

    /// The copy another phone passes on, or nil once it has travelled as far as it may.
    func relayed() -> (any GroupFrame)?
}

extension GroupFrame {
    var needsHelp: Bool { (self as? PositionFrame)?.status.needsHelp == true }
}

struct PositionFrame: GroupFrame {
    var memberId: Int
    var sequence: Int64
    var originTimeS: Int64
    var latE7: Int
    var lonE7: Int
    var altitudeM: Int?
    var accuracyM: Int
    var batteryPercent: Int
    var status: EmergencyStatus
    var triageCode: Int
    var hops: Int
    var ttl: Int
    var capabilities: Int
    var flags: Int

    init(
        memberId: Int, sequence: Int64, originTimeS: Int64, latE7: Int, lonE7: Int, altitudeM: Int?, accuracyM: Int,
        batteryPercent: Int, status: EmergencyStatus, triageCode: Int = 0, hops: Int = 0, ttl: Int = GroupFrames.ttl,
        capabilities: Int = 0, flags: Int = 0
    ) throws {
        try FrontierError.require((0...0xFFFF_FFFF).contains(sequence), "sequence out of range")
        try FrontierError.require((0...0xFFFF_FFFF).contains(originTimeS), "origin time out of range")
        try FrontierError.require((-900_000_000...900_000_000).contains(latE7), "latitude out of range")
        try FrontierError.require((-1_800_000_000...1_800_000_000).contains(lonE7), "longitude out of range")
        try FrontierError.require(
            altitudeM.map { (Int(Int16.min) + 1...Int(Int16.max)).contains($0) } ?? true, "altitude out of range"
        )
        try FrontierError.require(
            (0...255).contains(accuracyM) && (0...100).contains(batteryPercent) && (0...255).contains(triageCode),
            "byte field out of range"
        )
        try FrontierError.require(
            (0...15).contains(hops) && (0...15).contains(ttl) && (0...255).contains(capabilities) && (0...15).contains(flags),
            "header field out of range"
        )
        self.memberId = memberId
        self.sequence = sequence
        self.originTimeS = originTimeS
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.altitudeM = altitudeM
        self.accuracyM = accuracyM
        self.batteryPercent = batteryPercent
        self.status = status
        self.triageCode = triageCode
        self.hops = hops
        self.ttl = ttl
        self.capabilities = capabilities
        self.flags = flags
    }

    var lat: Double { Double(latE7) / 1e7 }
    var lon: Double { Double(lonE7) / 1e7 }

    func relayed() -> (any GroupFrame)? {
        guard ttl > 0 else { return nil }
        var next = self
        next.ttl = ttl - 1
        next.hops = min(hops + 1, 15)
        return next
    }

    static func of(
        memberId: Int, sequence: Int64, originTimeS: Int64, lat: Double, lon: Double, altitudeM: Double?, accuracyM: Float,
        batteryPercent: Int, status: EmergencyStatus, triageCode: Int = 0, capabilities: Int = 0, flags: Int = 0
    ) throws -> PositionFrame {
        try PositionFrame(
            memberId: memberId, sequence: sequence, originTimeS: originTimeS,
            latE7: try roundToInt(lat * 1e7), lonE7: try roundToInt(lon * 1e7),
            altitudeM: try altitudeM.map { try roundToInt($0).clamped(Int(Int16.min) + 1, Int(Int16.max)) },
            accuracyM: try roundToInt(Double(accuracyM)).clamped(0, 255), batteryPercent: batteryPercent.clamped(0, 100),
            status: status, triageCode: triageCode.clamped(0, 255),
            ttl: status.needsHelp ? GroupFrames.sosTtl : GroupFrames.ttl,
            capabilities: capabilities, flags: flags
        )
    }

    /// Kotlin's `roundToInt()`: halves up, clamped to a 32-bit Int, and NaN refused.
    private static func roundToInt(_ x: Double) throws -> Int {
        if x.isNaN { throw FrontierError.illegalArgument("Cannot round NaN value.") }
        return kRound(x).clamped(Int(Int32.min), Int(Int32.max))
    }
}

/// The name and colour a member picked, so other phones can label them.
struct ProfileFrame: GroupFrame {
    var memberId: Int
    var colour: Int
    var name: String
    var hops: Int
    var ttl: Int

    init(memberId: Int, colour: Int, name: String, hops: Int = 0, ttl: Int = GroupFrames.ttl) throws {
        try FrontierError.require(
            (0...255).contains(colour) && (0...15).contains(hops) && (0...15).contains(ttl), "profile field out of range"
        )
        self.memberId = memberId
        self.colour = colour
        self.name = name
        self.hops = hops
        self.ttl = ttl
    }

    func relayed() -> (any GroupFrame)? {
        guard ttl > 0 else { return nil }
        var next = self
        next.ttl = ttl - 1
        next.hops = min(hops + 1, 15)
        return next
    }
}

/// The fixed 30-byte plaintext layout of each frame (appendix A of the group sharing plan). Integers are big-endian.
enum GroupFrames {
    static let size = 30
    static let ttl = 2
    static let sosTtl = 3
    static let nameBytes = 23
    static let typePosition = 1
    static let typeProfile = 2
    static let typeRange = 3

    static let capCodedTx = 1
    static let capCodedRx = 2
    static let capRelay = 4
    static let capSatellite = 8
    /// Can be found with UWB using provisioned STS (`UwbSession.configProvisioned`).
    static let capUwb = 16
    /// Can be found with UWB using static STS (`UwbSession.configStatic`).
    static let capUwbStatic = 32

    static let flagRecording = 1
    static let flagPaused = 2
    /// The hike being recorded is one the whole trip group is invited to record (see `GroupHikeWatch`).
    static let flagGroupHike = 4

    private static let unknownAltitude = Int(Int16.min)

    static func encode(_ frame: any GroupFrame) -> [UInt8] {
        var b = GroupByteWriter(count: size)
        switch frame {
        case let frame as PositionFrame:
            b.put((typePosition << 4) | frame.flags)
            b.putInt(frame.memberId)
            b.putInt(frame.sequence)
            b.putInt(frame.originTimeS)
            b.putInt(frame.latE7)
            b.putInt(frame.lonE7)
            b.putShort(frame.altitudeM ?? unknownAltitude)
            b.put(frame.accuracyM)
            b.put(frame.batteryPercent)
            b.put(frame.status.wireValue)
            b.put(frame.triageCode)
            b.put((frame.hops << 4) | frame.ttl)
            b.put(frame.capabilities)
        case let frame as ProfileFrame:
            b.put(typeProfile << 4)
            b.putInt(frame.memberId)
            b.put(frame.colour)
            b.put(nameBytes(frame.name))
            b.position = size - 1
            b.put((frame.hops << 4) | frame.ttl)
        case let frame as RangeFrame:
            b.put((typeRange << 4) | frame.kind)
            b.putInt(frame.memberId)
            b.putInt(frame.targetId)
            b.putLong(frame.nonce)
            b.putInt(frame.timeS)
            b.put(frame.configId)
            b.put(frame.channel)
            b.put(frame.preambleIndex)
            b.put(frame.updateRate)
            b.put(frame.reason)
        default:
            preconditionFailure("not a group frame: \(type(of: frame))")
        }
        return b.bytes
    }

    /// The frame in `bytes`, or nil if it isn't a frame this version understands.
    static func decode(_ bytes: [UInt8]) -> (any GroupFrame)? {
        if bytes.count != size { return nil }
        var b = GroupByteReader(bytes)
        let head = b.get()
        let memberId = b.getInt()
        do {
            switch head >> 4 {
            case typePosition:
                let sequence = Int64(UInt32(truncatingIfNeeded: b.getInt()))
                let origin = Int64(UInt32(truncatingIfNeeded: b.getInt()))
                let lat = b.getInt()
                let lon = b.getInt()
                let altitude = b.getShort()
                let alt: Int? = altitude != unknownAltitude ? altitude : nil
                let accuracy = b.get()
                let battery = b.get()
                let status = EmergencyStatus.fromWire(b.get())
                let triage = b.get()
                let route = b.get()
                let capabilities = b.get()
                return try PositionFrame(
                    memberId: memberId, sequence: sequence, originTimeS: origin, latE7: lat, lonE7: lon, altitudeM: alt,
                    accuracyM: accuracy, batteryPercent: battery, status: status, triageCode: triage,
                    hops: route >> 4, ttl: route & 0xF, capabilities: capabilities, flags: head & 0xF
                )
            case typeProfile:
                let colour = b.get()
                let name = b.get(nameBytes)
                let route = b.get()
                let end = name.firstIndex(of: 0) ?? nameBytes
                return try ProfileFrame(
                    memberId: memberId, colour: colour, name: String(decoding: name[0..<end], as: UTF8.self),
                    hops: route >> 4, ttl: route & 0xF
                )
            case typeRange:
                return try RangeFrame(
                    memberId: memberId, targetId: b.getInt(), kind: head & 0xF, nonce: b.getLong(),
                    timeS: Int64(UInt32(truncatingIfNeeded: b.getInt())),
                    configId: b.get(), channel: b.get(), preambleIndex: b.get(), updateRate: b.get(), reason: b.get()
                )
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    /// `name` as UTF-8, cut at a character boundary to fit `nameBytes`.
    static func nameBytes(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in FrontierCompat.trim(name).unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if out.count + bytes.count > GroupFrames.nameBytes { break }
            out += bytes
        }
        return out
    }
}

/// Java's big-endian `ByteBuffer.put*` for the group's fixed layouts. Each value is cut to its field's width as
/// Kotlin's `toByte()`, `toShort()` and `toInt()` do.
struct GroupByteWriter {
    private(set) var bytes: [UInt8]
    var position = 0

    init(count: Int) { bytes = [UInt8](repeating: 0, count: count) }

    mutating func put<T: BinaryInteger>(_ value: T) {
        bytes[position] = UInt8(truncatingIfNeeded: value)
        position += 1
    }

    mutating func put(_ array: [UInt8]) {
        bytes.replaceSubrange(position..<(position + array.count), with: array)
        position += array.count
    }

    mutating func putShort<T: BinaryInteger>(_ value: T) { putBigEndian(UInt64(UInt16(truncatingIfNeeded: value)), 2) }
    mutating func putInt<T: BinaryInteger>(_ value: T) { putBigEndian(UInt64(UInt32(truncatingIfNeeded: value)), 4) }
    mutating func putLong<T: BinaryInteger>(_ value: T) { putBigEndian(UInt64(truncatingIfNeeded: value), 8) }

    private mutating func putBigEndian(_ value: UInt64, _ count: Int) {
        for i in 0..<count { put(value >> (8 * (count - 1 - i))) }
    }
}

/// Java's big-endian `ByteBuffer.get*`: bytes unsigned, shorts and ints signed, as the Kotlin reads them.
struct GroupByteReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// One byte, `& 0xFF`.
    mutating func get() -> Int {
        defer { position += 1 }
        return Int(bytes[position])
    }

    mutating func get(_ count: Int) -> [UInt8] {
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }

    mutating func getShort() -> Int { Int(Int16(truncatingIfNeeded: getBigEndian(2))) }
    mutating func getInt() -> Int { Int(Int32(truncatingIfNeeded: getBigEndian(4))) }
    mutating func getLong() -> Int64 { Int64(bitPattern: getBigEndian(8)) }

    private mutating func getBigEndian(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count { value = (value << 8) | UInt64(get()) }
        return value
    }
}