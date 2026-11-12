import Foundation

struct ImuSample: Hashable {
    var timestampMs: Int64
    var accelerationX: Float
    var accelerationY: Float
    var accelerationZ: Float
    var gyroscopeX: Float
    var gyroscopeY: Float
    var gyroscopeZ: Float
    var altitudeMeters: Float? = nil
}

struct DetectedFall: Hashable {
    var impactTimestampMs: Int64
    var fallVector: FallVector
    var preImpactSamples: [ImuSample]
}

/// Deterministic fall state machine: freefall below 0.2 g, impact above 4.5 g, then 90 seconds
/// without material acceleration or rotation. The retained evidence is bounded to 60 seconds.
final class FallDetector {
    private static let standardGravity: Float = 9.80665
    private static let freefallG: Float = 0.2
    private static let impactG: Float = 4.5
    private static let impactWindowMs: Int64 = 500
    private static let stationaryAccelerationDeltaG: Float = 0.15
    private static let stationaryRotationRadS: Float = 0.15

    private let bufferDurationMs: Int64
    private let immobilityDurationMs: Int64
    /// The retained samples are `samples[first...]`; dropping from the front only moves `first` (Kotlin's ArrayDeque).
    private var samples: [ImuSample] = []
    private var first = 0
    private var freefallStartedMs: Int64? = nil
    private var freefallEndedMs: Int64? = nil
    private var impact: ImuSample? = nil
    private var freefallDurationMs: Int64 = 0
    private var stationaryStartedMs: Int64? = nil
    private var preImpactEvidence: [ImuSample] = []

    init(bufferDurationMs: Int64 = 60_000, immobilityDurationMs: Int64 = 90_000) {
        self.bufferDurationMs = bufferDurationMs
        self.immobilityDurationMs = immobilityDurationMs
    }

    func add(_ sample: ImuSample) -> DetectedFall? {
        samples.append(sample)
        while first < samples.count && sample.timestampMs - samples[first].timestampMs > bufferDurationMs {
            first += 1
        }
        if first > 0 && first * 2 >= samples.count {
            samples.removeFirst(first)
            first = 0
        }

        let accelerationG = magnitude(sample.accelerationX, sample.accelerationY, sample.accelerationZ) / Self.standardGravity
        let rotation = magnitude(sample.gyroscopeX, sample.gyroscopeY, sample.gyroscopeZ)
        guard let currentImpact = impact else {
            if accelerationG < Self.freefallG {
                if freefallStartedMs == nil { freefallStartedMs = sample.timestampMs }
                freefallEndedMs = nil
            } else if let freefallStart = freefallStartedMs {
                let freefallEnd: Int64
                if let ended = freefallEndedMs {
                    freefallEnd = ended
                } else {
                    freefallEnd = sample.timestampMs
                    freefallEndedMs = freefallEnd
                }
                if accelerationG > Self.impactG && sample.timestampMs - freefallEnd <= Self.impactWindowMs {
                    impact = sample
                    freefallDurationMs = freefallEnd - freefallStart
                    stationaryStartedMs = sample.timestampMs
                    preImpactEvidence = Array(samples[first...])
                } else if sample.timestampMs - freefallEnd > Self.impactWindowMs {
                    clearIncident()
                }
            }
            return nil
        }

        let stationary = abs(accelerationG - 1) <= Self.stationaryAccelerationDeltaG &&
            rotation <= Self.stationaryRotationRadS
        if !stationary { stationaryStartedMs = sample.timestampMs }
        let stationarySince: Int64
        if let since = stationaryStartedMs {
            stationarySince = since
        } else {
            stationarySince = sample.timestampMs
            stationaryStartedMs = stationarySince
        }
        if sample.timestampMs - stationarySince < immobilityDurationMs {
            return nil
        }

        let evidence = preImpactEvidence
        let startAltitude = evidence.lazy.compactMap(\.altitudeMeters).first
        let impactAltitude = evidence.reversed().lazy.compactMap(\.altitudeMeters).first
        let deltaAltitude: Float
        if let start = startAltitude, let end = impactAltitude {
            deltaAltitude = end - start
        } else {
            deltaAltitude = 0
        }
        let detected = DetectedFall(
            impactTimestampMs: currentImpact.timestampMs,
            fallVector: FallVector(
                impactGForce: magnitude(
                    currentImpact.accelerationX,
                    currentImpact.accelerationY,
                    currentImpact.accelerationZ
                ) / Self.standardGravity,
                freefallDurationSeconds: Float(freefallDurationMs) / 1_000,
                deltaAltitudeMeters: deltaAltitude
            ),
            preImpactSamples: evidence
        )
        clearIncident()
        return detected
    }

    func reset() {
        samples.removeAll()
        first = 0
        clearIncident()
    }

    private func clearIncident() {
        freefallStartedMs = nil
        freefallEndedMs = nil
        impact = nil
        freefallDurationMs = 0
        stationaryStartedMs = nil
        preImpactEvidence = []
    }

    private func magnitude(_ x: Float, _ y: Float, _ z: Float) -> Float { (x * x + y * y + z * z).squareRoot() }
}

enum InjuryType: Int, CaseIterable {
    case none = 0, leg = 1, arm = 2, head = 3, torso = 4, multiple = 5, other = 6

    var code: Int { rawValue }
}

enum Mobility: Int, CaseIterable {
    case mobile = 0, limited = 1, stationary = 2, unconscious = 3

    var code: Int { rawValue }
}

enum Bleeding: Int, CaseIterable {
    case none = 0, controlled = 1, uncontrolled = 2, unknown = 3

    var code: Int { rawValue }
}

enum TriageCode {
    static func encode(_ injury: InjuryType, _ mobility: Mobility, _ bleeding: Bleeding) -> Int {
        (injury.code & 0x7) | ((mobility.code & 0x3) << 3) | ((bleeding.code & 0x3) << 5)
    }

    static func decode(_ code: Int) throws -> (injury: InjuryType, mobility: Mobility, bleeding: Bleeding) {
        try FrontierError.require((0...255).contains(code), "triage code must fit in one byte")
        return (
            InjuryType.allCases.first { $0.code == code & 0x7 } ?? .other,
            Mobility.allCases.first { $0.code == (code >> 3) & 0x3 } ?? .unconscious,
            Bleeding.allCases.first { $0.code == (code >> 5) & 0x3 } ?? .unknown
        )
    }
}
