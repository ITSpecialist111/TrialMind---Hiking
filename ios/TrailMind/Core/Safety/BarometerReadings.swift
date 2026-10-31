import Foundation

/// The pressure sensor's readings as Android's sensor/Barometer.kt keeps them, without the sensor plumbing: the station
/// pressure smoothed as it arrives, a barometric altitude anchored to GPS once per fix (however many listeners report
/// the fix), and the sea-level pressure trend for the "weather may be turning" warning.
final class BarometerReadings {
    private let altimeter = BaroAltimeter()
    private let trend = PressureTrend()
    private var lastFixTimeMs: Int64 = 0

    /// Smoothed station pressure in hPa; nil before the first reading or after `clear()`.
    private(set) var pressureHpa: Double? = nil

    var stormDropHpa: Double { trend.stormDropHpa }

    /// A sensor reading, hPa.
    func onPressure(_ hpa: Double) {
        pressureHpa = pressureHpa.map { $0 + 0.3 * (hpa - $0) } ?? hpa
    }

    /// The sensor stopped: there is no current pressure until it reports again.
    func clear() { pressureHpa = nil }

    /// Calibrates against a GPS fix (once per fix time) and returns the barometric altitude, or nil without a pressure
    /// reading or calibration. `verticalAccuracyM` is nil when the fix has none; then 1.5 × the horizontal accuracy counts.
    func altitudeFor(fixTimeMs: Int64, gpsAltitudeM: Double?, verticalAccuracyM: Double?, horizontalAccuracyM: Double?,
                     nowMs: Int64) -> Double? {
        guard let p = pressureHpa else { return nil }
        if fixTimeMs != lastFixTimeMs {
            lastFixTimeMs = fixTimeMs
            let accuracy = verticalAccuracyM ?? horizontalAccuracyM.map { $0 * 1.5 } ?? Double.greatestFiniteMagnitude
            if let gpsAltitudeM { altimeter.onGps(p, gpsAltitudeM, accuracy) }
            if let seaLevel = altimeter.seaLevelHpa { trend.add(nowMs, seaLevel) }
        }
        return altimeter.altitudeM(p)
    }

    /// Change in sea-level pressure over the last 3 hours (negative = falling), once enough is recorded.
    func change3hHpa() -> Double? { trend.change() }

    func tendency() -> PressureTrend.Tendency { trend.tendency() }

    /// For example "Pressure 1003 hPa · steady"; nil without a reading.
    func summary() -> String? {
        guard let p = pressureHpa else { return nil }
        return SafetyText.pressure(p, change: trend.change(), tendency: trend.tendency())
    }
}
