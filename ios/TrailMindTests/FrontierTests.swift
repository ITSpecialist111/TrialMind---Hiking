import XCTest
@testable import TrailMind

/// Port of core/src/test/kotlin/com/trailmind/core/FrontierTest.kt.
final class FrontierTests: XCTestCase {
    func testProtobufPayloadRoundTripsWithinSatelliteLimit() throws {
        let source = try GroupMeshPayload(
            gatewayDeviceId: "gate0001",
            messageSequence: 42,
            hikers: [try telemetry("hiker001"), try telemetry("hiker002", .injuredStationary)],
            fallTelemetry: FallVector(impactGForce: 5.2, freefallDurationSeconds: 0.8, deltaAltitudeMeters: -3.5)
        )
        let bytes = try FrontierTelemetryCodec.encode(source)
        XCTAssertTrue(bytes.count <= 256)
        XCTAssertEqual(source, try FrontierTelemetryCodec.decode(bytes))
    }

    func testPackPrioritizesEmergencyRecordsAndReportsOverflow() throws {
        let hikers = try (1...8).map {
            try telemetry("hiker" + String($0).padStart(3, "0"), $0 == 8 ? .criticalSos : .ok)
        }
        let packed = try FrontierTelemetryCodec.pack(try GroupMeshPayload(gatewayDeviceId: "gate0001", messageSequence: 1, hikers: hikers))
        XCTAssertTrue(packed.bytes.count <= 256)
        XCTAssertTrue(packed.includedHikerIds.contains("hiker008"))
        XCTAssertFalse(packed.omittedHikerIds.isEmpty)
    }

    func testGatewayElectionUsesOrderedCriteria() throws {
        let elected = GatewayElection.elect([
            try GatewayCandidate(deviceId: "fold", hasActiveNtnSignal: false, batteryPercent: 100, processingRank: 100, isGalaxyFold7: true),
            try GatewayCandidate(deviceId: "ntn-low", hasActiveNtnSignal: true, batteryPercent: 20, processingRank: 1),
            try GatewayCandidate(deviceId: "ntn-high", hasActiveNtnSignal: true, batteryPercent: 80, processingRank: 1),
        ])
        XCTAssertEqual("ntn-high", elected?.deviceId)
    }

    func testRelayDeduplicatesAndStopsAfterThreeHops() throws {
        let dedupe = try MeshRelayDeduplicator()
        var packet = try MeshPacket(packetId: 7, originDeviceId: "hiker001", sequence: 1, payload: [1])
        packet = try XCTUnwrap(dedupe.accept(packet, nowMs: 1_000))
        XCTAssertEqual(2, packet.ttl)
        XCTAssertNil(dedupe.accept(packet, nowMs: 1_001))

        packet = try MeshPacket(packetId: 8, originDeviceId: "hiker001", sequence: 2, ttl: 0, payload: [1])
        XCTAssertNil(dedupe.accept(packet, nowMs: 2_000))
        XCTAssertTrue(dedupe.hasSeen(8, nowMs: 2_000))
    }

    func testFallRequiresFreefallImpactAndNinetySecondsImmobility() throws {
        let detector = FallDetector()
        _ = detector.add(sample(0, 9.80665, altitude: 100))
        _ = detector.add(sample(1_000, 0.5, altitude: 99))
        _ = detector.add(sample(1_600, 9, altitude: 97))
        _ = detector.add(sample(1_700, 18, altitude: 96.5))
        _ = detector.add(sample(1_800, 50, altitude: 96))
        XCTAssertNil(detector.add(sample(90_000, 9.80665, altitude: 96)))
        let fall = try XCTUnwrap(detector.add(sample(91_800, 9.80665, altitude: 96)))
        XCTAssertTrue(fall.fallVector.impactGForce > 4.5)
        XCTAssertEqual(0.6, fall.fallVector.freefallDurationSeconds)
        XCTAssertEqual(-4, fall.fallVector.deltaAltitudeMeters)

        _ = detector.add(sample(100_000, 0.5, altitude: 96))
        _ = detector.add(sample(100_700, 50, altitude: 95))
        XCTAssertNotNil(detector.add(sample(190_700, 9.80665, altitude: 95)))
    }

    func testTriageCodeIsOneByteAndReversible() throws {
        for injury in InjuryType.allCases {
            for mobility in Mobility.allCases {
                for bleeding in Bleeding.allCases {
                    let code = TriageCode.encode(injury, mobility, bleeding)
                    XCTAssertTrue((0...255).contains(code))
                    let decoded = try TriageCode.decode(code)
                    XCTAssertEqual(injury, decoded.injury)
                    XCTAssertEqual(mobility, decoded.mobility)
                    XCTAssertEqual(bleeding, decoded.bleeding)
                }
            }
        }
        for code in 0...255 { _ = try TriageCode.decode(code) }
    }

    private func telemetry(_ id: String, _ status: EmergencyStatus = .ok) throws -> HikerTelemetry {
        try HikerTelemetry(
            hikerId: id,
            latitude: 54.5271,
            longitude: -3.0164,
            altitudeMeters: 949,
            batteryPercent: 73,
            timestampEpochSeconds: 1_790_000_000,
            status: status,
            triageCode: status == .ok ? 0 : 42
        )
    }

    private func sample(_ timeMs: Int64, _ accelerationZ: Float, altitude: Float) -> ImuSample {
        ImuSample(
            timestampMs: timeMs,
            accelerationX: 0,
            accelerationY: 0,
            accelerationZ: accelerationZ,
            gyroscopeX: 0,
            gyroscopeY: 0,
            gyroscopeZ: 0,
            altitudeMeters: altitude
        )
    }
}
