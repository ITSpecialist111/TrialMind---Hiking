import Foundation

/// International Standard Atmosphere conversions between pressure and height.
enum Barometry {
    static let standardSeaLevelHpa = 1013.25
    private static let scaleM = 44330.77
    private static let exponent = 5.255877

    static func altitudeM(_ pressureHpa: Double, _ seaLevelHpa: Double = standardSeaLevelHpa) -> Double {
        scaleM * (1 - pow(pressureHpa / seaLevelHpa, 1 / exponent))
    }

    static func pressureHpa(_ altitudeM: Double, _ seaLevelHpa: Double = standardSeaLevelHpa) -> Double {
        seaLevelHpa * pow(1 - altitudeM / scaleM, exponent)
    }

    /// The sea-level pressure (QNH) that puts `pressureHpa` at `altitudeM`.
    static func seaLevelHpa(_ pressureHpa: Double, _ altitudeM: Double) -> Double {
        pressureHpa / pow(1 - altitudeM / scaleM, exponent)
    }
}

/// Barometric altitude anchored to GPS. GPS altitude has no drift but is noisy (±10–20 m); the barometer
/// resolves about a metre but drifts as the weather changes. Every good GPS fix nudges the sea-level
/// pressure estimate, so the result follows GPS over minutes and the barometer from moment to moment.
final class BaroAltimeter {
    private let gain: Double
    private let maxAccuracyM: Double
    private(set) var seaLevelHpa: Double? = nil
    private var samples = 0

    init(gain: Double = 0.02, maxAccuracyM: Double = 25.0) {
        self.gain = gain
        self.maxAccuracyM = maxAccuracyM
    }

    func onGps(_ pressureHpa: Double, _ gpsAltitudeM: Double, _ accuracyM: Double) {
        if accuracyM > maxAccuracyM || !(300.0...1100.0).contains(pressureHpa) || gpsAltitudeM.isNaN { return }
        let sample = Barometry.seaLevelHpa(pressureHpa, gpsAltitudeM)
        samples += 1
        // A running mean at first, then a slow filter that averages out GPS noise.
        let k = max(gain, 1.0 / Double(samples))
        seaLevelHpa = seaLevelHpa.map { $0 + k * (sample - $0) } ?? sample
    }

    func altitudeM(_ pressureHpa: Double) -> Double? { seaLevelHpa.map { Barometry.altitudeM(pressureHpa, $0) } }
}

/// Sea-level pressure over the last few hours. A fall of `stormDropHpa` or more within `windowMs` is the
/// classic mountain "storm alarm". Sea-level rather than station pressure is used, so climbing doesn't count.
final class PressureTrend {
    enum Tendency { case unknown, rising, steady, falling, fallingFast }

    private let windowMs: Int64
    private let sampleEveryMs: Int64
    let stormDropHpa: Double

    private var times: [Int64] = []
    private var values: [Double] = []

    init(windowMs: Int64 = 3 * 3_600_000, sampleEveryMs: Int64 = 5 * 60_000, stormDropHpa: Double = 4.0) {
        self.windowMs = windowMs
        self.sampleEveryMs = sampleEveryMs
        self.stormDropHpa = stormDropHpa
    }

    func add(_ timeMs: Int64, _ seaLevelHpa: Double) {
        if let last = times.last, timeMs - last < sampleEveryMs { return }
        times.append(timeMs)
        values.append(seaLevelHpa)
        while timeMs - times.first! > windowMs {
            times.removeFirst()
            values.removeFirst()
        }
    }

    /// Change over the window in hPa (negative = falling), or nil until most of the window is covered.
    func change() -> Double? {
        if times.count < 2 || Double(times.last! - times.first!) < Double(windowMs) * 0.8 { return nil }
        return values.last! - values.first!
    }

    func tendency() -> Tendency {
        guard let c = change() else { return .unknown }
        if c <= -stormDropHpa { return .fallingFast }
        if c <= -1.5 { return .falling }
        if c >= 1.5 { return .rising }
        return .steady
    }
}
