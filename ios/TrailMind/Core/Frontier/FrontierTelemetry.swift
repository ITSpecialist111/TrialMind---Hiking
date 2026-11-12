import Foundation

enum EmergencyStatus: Int, CaseIterable {
    case ok = 0
    case manualCheckIn = 1
    case delayed = 2
    case injuredStationary = 3
    case injuredMoving = 4
    case fallDetected = 5
    case criticalSos = 6

    var wireValue: Int { rawValue }

    static func fromWire(_ value: Int) -> EmergencyStatus { allCases.first { $0.wireValue == value } ?? .ok }
}

struct HikerTelemetry: Hashable {
    var hikerId: String
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Int
    var batteryPercent: Int
    var timestampEpochSeconds: Int64
    var status: EmergencyStatus
    var triageCode: Int

    init(
        hikerId: String, latitude: Double, longitude: Double, altitudeMeters: Int, batteryPercent: Int,
        timestampEpochSeconds: Int64, status: EmergencyStatus = .ok, triageCode: Int = 0
    ) throws {
        try FrontierError.require((1...8).contains(hikerId.utf8.count), "hikerId must be 1-8 UTF-8 bytes")
        try FrontierError.require((-90.0...90.0).contains(latitude), "latitude out of range")
        try FrontierError.require((-180.0...180.0).contains(longitude), "longitude out of range")
        try FrontierError.require((0...100).contains(batteryPercent), "batteryPercent out of range")
        try FrontierError.require(timestampEpochSeconds >= 0, "timestamp must be non-negative")
        try FrontierError.require((0...255).contains(triageCode), "triageCode must fit in one byte")
        self.hikerId = hikerId
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.batteryPercent = batteryPercent
        self.timestampEpochSeconds = timestampEpochSeconds
        self.status = status
        self.triageCode = triageCode
    }
}

struct FallVector: Hashable {
    var impactGForce: Float
    var freefallDurationSeconds: Float
    var deltaAltitudeMeters: Float
}

struct GroupMeshPayload: Hashable {
    var gatewayDeviceId: String
    var messageSequence: Int64
    var hikers: [HikerTelemetry]
    var fallTelemetry: FallVector?

    init(gatewayDeviceId: String, messageSequence: Int64, hikers: [HikerTelemetry], fallTelemetry: FallVector? = nil) throws {
        try FrontierError.require((1...8).contains(gatewayDeviceId.utf8.count), "gatewayDeviceId must be 1-8 UTF-8 bytes")
        try FrontierError.require(messageSequence >= 0, "messageSequence must be non-negative")
        try FrontierError.require(hikers.count <= 8, "at most eight hikers are supported")
        self.gatewayDeviceId = gatewayDeviceId
        self.messageSequence = messageSequence
        self.hikers = hikers
        self.fallTelemetry = fallTelemetry
    }
}

struct PackedGroupPayload: Hashable {
    var bytes: [UInt8]
    var includedHikerIds: [String]
    var omittedHikerIds: [String]
}

/// Proto3 wire codec for frontier_telemetry.proto. Keeping this small codec in core avoids making
/// offline communication depend on generated-code runtimes while remaining protobuf-compatible.
enum FrontierTelemetryCodec {
    static let maxPayloadBytes = 256

    static func encode(_ payload: GroupMeshPayload) throws -> [UInt8] {
        let bytes = encodeUnchecked(payload)
        try FrontierError.require(
            bytes.count <= maxPayloadBytes, "frontier payload is \(bytes.count) bytes; maximum is \(maxPayloadBytes)"
        )
        return bytes
    }

    /// Builds a legal micro-payload and reports any hikers that could not fit. Emergency records are
    /// considered first, then the newest records. Callers must queue omitted records for a later SMS.
    static func pack(_ payload: GroupMeshPayload) throws -> PackedGroupPayload {
        let ordered = FrontierCompat.stableSorted(payload.hikers) { a, b in
            if a.status.wireValue != b.status.wireValue { return a.status.wireValue > b.status.wireValue }
            return a.timestampEpochSeconds > b.timestampEpochSeconds
        }
        var included: [HikerTelemetry] = []
        included.reserveCapacity(ordered.count)
        for hiker in ordered {
            var candidate = payload
            candidate.hikers = included + [hiker]
            if encodeUnchecked(candidate).count <= maxPayloadBytes { included.append(hiker) }
        }
        let selectedIds = Set(included.map(\.hikerId))
        var selected = payload
        selected.hikers = included
        return PackedGroupPayload(
            bytes: try encode(selected),
            includedHikerIds: included.map(\.hikerId),
            omittedHikerIds: ordered.filter { !selectedIds.contains($0.hikerId) }.map(\.hikerId)
        )
    }

    static func decode(_ bytes: [UInt8]) throws -> GroupMeshPayload {
        try FrontierError.require(
            bytes.count <= maxPayloadBytes, "frontier payload is \(bytes.count) bytes; maximum is \(maxPayloadBytes)"
        )
        do {
            var reader = ProtoReader(bytes)
            var gatewayId = ""
            var sequence: Int64 = 0
            var hikers: [HikerTelemetry] = []
            var fall: FallVector? = nil
            while !reader.exhausted() {
                let tag = Int32(truncatingIfNeeded: try reader.varint())
                switch UInt32(bitPattern: tag) >> 3 {
                case 1: gatewayId = try reader.string(tag)
                case 2: sequence = try reader.varintField(tag)
                case 3: hikers.append(try decodeHiker(try reader.bytes(tag)))
                case 4: fall = try decodeFall(try reader.bytes(tag))
                default: try reader.skip(tag)
                }
            }
            return try GroupMeshPayload(gatewayDeviceId: gatewayId, messageSequence: sequence, hikers: hikers, fallTelemetry: fall)
        } catch FrontierError.illegalArgument {
            throw FrontierError.io("invalid frontier protobuf payload")
        }
    }

    private static func encodeUnchecked(_ payload: GroupMeshPayload) -> [UInt8] {
        var writer = ProtoWriter()
        writer.string(1, payload.gatewayDeviceId)
        writer.uint64(2, payload.messageSequence)
        for hiker in payload.hikers { writer.message(3, encodeHiker(hiker)) }
        if let fall = payload.fallTelemetry { writer.message(4, encodeFall(fall)) }
        return writer.bytes()
    }

    private static func encodeHiker(_ hiker: HikerTelemetry) -> [UInt8] {
        var writer = ProtoWriter()
        writer.string(1, hiker.hikerId)
        writer.double(2, hiker.latitude)
        writer.double(3, hiker.longitude)
        writer.int32(4, hiker.altitudeMeters)
        writer.uint32(5, hiker.batteryPercent)
        writer.uint64(6, hiker.timestampEpochSeconds)
        writer.enumField(7, hiker.status.wireValue)
        writer.uint32(8, hiker.triageCode)
        return writer.bytes()
    }

    private static func decodeHiker(_ bytes: [UInt8]) throws -> HikerTelemetry {
        var reader = ProtoReader(bytes)
        var id = ""
        var lat = 0.0
        var lon = 0.0
        var altitude = 0
        var battery = 0
        var timestamp: Int64 = 0
        var status = EmergencyStatus.ok
        var triage = 0
        while !reader.exhausted() {
            let tag = Int32(truncatingIfNeeded: try reader.varint())
            switch UInt32(bitPattern: tag) >> 3 {
            case 1: id = try reader.string(tag)
            case 2: lat = try reader.double(tag)
            case 3: lon = try reader.double(tag)
            case 4: altitude = toInt(try reader.varintField(tag))
            case 5: battery = toInt(try reader.varintField(tag))
            case 6: timestamp = try reader.varintField(tag)
            case 7: status = EmergencyStatus.fromWire(toInt(try reader.varintField(tag)))
            case 8: triage = toInt(try reader.varintField(tag))
            default: try reader.skip(tag)
            }
        }
        return try HikerTelemetry(
            hikerId: id, latitude: lat, longitude: lon, altitudeMeters: altitude, batteryPercent: battery,
            timestampEpochSeconds: timestamp, status: status, triageCode: triage
        )
    }

    private static func encodeFall(_ fall: FallVector) -> [UInt8] {
        var writer = ProtoWriter()
        writer.float(1, fall.impactGForce)
        writer.float(2, fall.freefallDurationSeconds)
        writer.float(3, fall.deltaAltitudeMeters)
        return writer.bytes()
    }

    private static func decodeFall(_ bytes: [UInt8]) throws -> FallVector {
        var reader = ProtoReader(bytes)
        var impact: Float = 0
        var duration: Float = 0
        var altitude: Float = 0
        while !reader.exhausted() {
            let tag = Int32(truncatingIfNeeded: try reader.varint())
            switch UInt32(bitPattern: tag) >> 3 {
            case 1: impact = try reader.float(tag)
            case 2: duration = try reader.float(tag)
            case 3: altitude = try reader.float(tag)
            default: try reader.skip(tag)
            }
        }
        return FallVector(impactGForce: impact, freefallDurationSeconds: duration, deltaAltitudeMeters: altitude)
    }

    /// Kotlin's `Long.toInt()`: the low 32 bits, signed.
    private static func toInt(_ value: Int64) -> Int { Int(Int32(truncatingIfNeeded: value)) }
}

/// Kotlin `Int` arguments are 32-bit; they are narrowed the same way here so the bytes match Android's.
private struct ProtoWriter {
    private var out: [UInt8] = []

    mutating func string(_ field: Int, _ value: String) {
        if value.isEmpty { return }
        let bytes = Array(value.utf8)
        tag(field, 2)
        varint(Int64(bytes.count))
        out += bytes
    }

    mutating func message(_ field: Int, _ value: [UInt8]) {
        tag(field, 2)
        varint(Int64(value.count))
        out += value
    }

    mutating func double(_ field: Int, _ value: Double) {
        if value == 0.0 { return }
        tag(field, 1)
        fixed64(value.bitPattern)
    }

    mutating func float(_ field: Int, _ value: Float) {
        if value == 0 { return }
        tag(field, 5)
        fixed32(value.bitPattern)
    }

    mutating func int32(_ field: Int, _ value: Int) {
        let v = Int32(truncatingIfNeeded: value)
        if v == 0 { return }
        tag(field, 0)
        varint(Int64(v))
    }

    mutating func uint32(_ field: Int, _ value: Int) {
        let v = Int32(truncatingIfNeeded: value)
        if v == 0 { return }
        tag(field, 0)
        varint(Int64(UInt32(bitPattern: v)))
    }

    mutating func uint64(_ field: Int, _ value: Int64) {
        if value == 0 { return }
        tag(field, 0)
        varint(value)
    }

    /// Kotlin's `enum(field, value)`.
    mutating func enumField(_ field: Int, _ value: Int) { uint32(field, value) }

    func bytes() -> [UInt8] { out }

    private mutating func tag(_ field: Int, _ wireType: Int) { varint(Int64(Int32(truncatingIfNeeded: (field << 3) | wireType))) }

    private mutating func varint(_ value: Int64) {
        var remaining = UInt64(bitPattern: value)
        while remaining & ~0x7F != 0 {
            out.append(UInt8(truncatingIfNeeded: (remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        out.append(UInt8(truncatingIfNeeded: remaining))
    }

    private mutating func fixed32(_ value: UInt32) {
        for shift in 0..<4 { out.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }

    private mutating func fixed64(_ value: UInt64) {
        for shift in 0..<8 { out.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }
}

private struct ProtoReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) { self.data = data }

    func exhausted() -> Bool { offset == data.count }

    mutating func varint() throws -> Int64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            if offset >= data.count { throw FrontierError.io("truncated protobuf varint") }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return Int64(bitPattern: result) }
            shift += 7
        }
        throw FrontierError.io("malformed protobuf varint")
    }

    mutating func varintField(_ tag: Int32) throws -> Int64 {
        try requireWire(tag, 0)
        return try varint()
    }

    mutating func string(_ tag: Int32) throws -> String { String(decoding: try bytes(tag), as: UTF8.self) }

    mutating func bytes(_ tag: Int32) throws -> [UInt8] {
        try requireWire(tag, 2)
        let size = Int(Int32(truncatingIfNeeded: try varint()))
        if size < 0 || offset + size > data.count { throw FrontierError.io("truncated protobuf field") }
        defer { offset += size }
        return Array(data[offset..<(offset + size)])
    }

    mutating func double(_ tag: Int32) throws -> Double {
        try requireWire(tag, 1)
        return Double(bitPattern: try fixed64())
    }

    mutating func float(_ tag: Int32) throws -> Float {
        try requireWire(tag, 5)
        return Float(bitPattern: try fixed32())
    }

    mutating func skip(_ tag: Int32) throws {
        switch tag & 7 {
        case 0: _ = try varint()
        case 1: try take(8)
        case 2: try take(Int(Int32(truncatingIfNeeded: try varint())))
        case 5: try take(4)
        default: throw FrontierError.io("unsupported protobuf wire type \(tag & 7)")
        }
    }

    private mutating func fixed32() throws -> UInt32 {
        try take(4)
        var result: UInt32 = 0
        for i in 0..<4 { result |= UInt32(data[offset - 4 + i]) << (i * 8) }
        return result
    }

    private mutating func fixed64() throws -> UInt64 {
        try take(8)
        var result: UInt64 = 0
        for i in 0..<8 { result |= UInt64(data[offset - 8 + i]) << (i * 8) }
        return result
    }

    private mutating func take(_ count: Int) throws {
        if count < 0 || offset + count > data.count { throw FrontierError.io("truncated protobuf field") }
        offset += count
    }

    private func requireWire(_ tag: Int32, _ expected: Int32) throws {
        if tag & 7 != expected { throw FrontierError.io("unexpected protobuf wire type \(tag & 7)") }
    }
}
