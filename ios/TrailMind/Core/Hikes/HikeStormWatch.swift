import Foundation

/// The barometer's storm alarm while a hike records (the Android app's Barometer, BaroAltimeter, PressureTrend and
/// TrackingService.checkWeather). GPS altitude has no drift but is noisy; the barometer resolves a metre but drifts
/// with the weather. Every good GPS fix nudges an estimate of the sea-level pressure, which is sampled every five
/// minutes over three hours: a fall of `stormDropHpa` or more is the classic mountain "storm alarm", given at most once
/// every three hours. Sea-level rather than station pressure is used, so climbing doesn't count.
final class HikeStormWatch {
    /// International Standard Atmosphere constants (Barometry).
    static let scaleM = 44330.77
    static let exponent = 5.255877

    let stormDropHpa: Double
    private let gain: Double
    private let maxAccuracyM: Double
    private let windowMs: Int64
    private let sampleEveryMs: Int64
    private static let alertEveryMs: Int64 = 3 * 3_600_000

    /// Smoothed station pressure in hPa; nil before the first reading.
    private(set) var pressureHpa: Double? = nil
    /// The sea-level pressure (QNH) that puts the barometer at the GPS altitude, filtered over many fixes.
    private(set) var seaLevelHpa: Double? = nil
    private var samples = 0
    private var times: [Int64] = []
    private var values: [Double] = []
    private var lastAlertMs: Int64 = 0

    init(stormDropHpa: Double = 4.0, gain: Double = 0.02, maxAccuracyM: Double = 25.0,
         windowMs: Int64 = 3 * 3_600_000, sampleEveryMs: Int64 = 5 * 60_000) {
        self.stormDropHpa = stormDropHpa
        self.gain = gain
        self.maxAccuracyM = maxAccuracyM
        self.windowMs = windowMs
        self.sampleEveryMs = sampleEveryMs
    }

    /// The sea-level pressure that puts `pressureHpa` at `altitudeM` (Barometry.seaLevelHpa).
    static func seaLevelHpa(_ pressureHpa: Double, _ altitudeM: Double) -> Double {
        pressureHpa / pow(1 - altitudeM / scaleM, exponent)
    }

    /// A barometer reading in hPa, smoothed as the Android sensor listener smooths it.
    func onPressure(_ hpa: Double) {
        pressureHpa = pressureHpa.map { $0 + 0.3 * (hpa - $0) } ?? hpa
    }

    /// A GPS fix: calibrates the sea-level estimate against its altitude (when it has one) and samples the estimate
    /// into the trend (Barometer.altitudeFor). `accuracyM` is the fix's vertical accuracy.
    func onFix(gpsAltitudeM: Double?, accuracyM: Double, nowMs: Int64) {
        guard let p = pressureHpa else { return }
        if let altitude = gpsAltitudeM { onGps(p, altitude, accuracyM) }
        if let s = seaLevelHpa { add(nowMs, s) }
    }

    private func onGps(_ pressureHpa: Double, _ gpsAltitudeM: Double, _ accuracyM: Double) {
        if accuracyM > maxAccuracyM || !(300.0...1100.0).contains(pressureHpa) || gpsAltitudeM.isNaN { return }
        let sample = Self.seaLevelHpa(pressureHpa, gpsAltitudeM)
        samples += 1
        // A running mean at first, then a slow filter that averages out GPS noise.
        let k = max(gain, 1.0 / Double(samples))
        seaLevelHpa = seaLevelHpa.map { $0 + k * (sample - $0) } ?? sample
    }

    private func add(_ timeMs: Int64, _ seaLevelHpa: Double) {
        if let last = times.last, timeMs - last < sampleEveryMs { return }
        times.append(timeMs)
        values.append(seaLevelHpa)
        while let first = times.first, timeMs - first > windowMs {
            times.removeFirst()
            values.removeFirst()
        }
    }

    /// Change in sea-level pressure over the window in hPa (negative = falling), or nil until most of it is covered.
    func change() -> Double? {
        guard times.count >= 2, let first = times.first, let last = times.last,
              Double(last - first) >= Double(windowMs) * 0.8 else { return nil }
        return values[values.count - 1] - values[0]
    }

    /// A new recording may warn straight away (each Android recording service starts with no warning given).
    func resetAlerts() { lastAlertMs = 0 }

    /// The fall to warn about now (a negative change in hPa), or nil: the fall must reach `stormDropHpa` and the last
    /// warning must be three hours old.
    func alertDue(nowMs: Int64) -> Double? {
        guard let change = change() else { return nil }
        if change > -stormDropHpa || nowMs - lastAlertMs < Self.alertEveryMs { return nil }
        lastAlertMs = nowMs
        return change
    }
}
