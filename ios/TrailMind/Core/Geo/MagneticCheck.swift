import Foundation

/// Whether a magnetometer sees only the Earth's field, judged by comparing the strength and dip of what it
/// measures with the geomagnetic model at your position. Nearby steel, a magnet, electronics or an offset the
/// sensor has not calibrated out all show up here, even while the sensor reports itself as calibrated.
final class MagneticCheck {
    private let strengthTolerance: Double
    private let dipToleranceDeg: Double
    private var expectedUt = Double.nan
    private var expectedDipDeg = Double.nan

    /// Smoothed measured strength, microtesla.
    private(set) var strengthUt = Double.nan
    /// Smoothed measured dip below the horizontal, degrees.
    private(set) var dipDeg = Double.nan
    private(set) var disturbed = false

    init(strengthTolerance: Double = 0.15, dipToleranceDeg: Double = 10.0) {
        self.strengthTolerance = strengthTolerance
        self.dipToleranceDeg = dipToleranceDeg
    }

    /// The model's field where you are: strength in microtesla and dip (inclination) in degrees below horizontal.
    func expect(_ strengthUt: Double, _ dipDeg: Double) {
        expectedUt = strengthUt
        expectedDipDeg = dipDeg
    }

    /// A reading `mx`, `my`, `mz` in microtesla and the unit vector `ux`, `uy`, `uz` pointing up, both in device axes.
    func add(_ mx: Double, _ my: Double, _ mz: Double, _ ux: Double, _ uy: Double, _ uz: Double) {
        let s = sqrt(mx * mx + my * my + mz * mz)
        if s == 0.0 || s.isNaN { return }
        let d = toDegrees(asin((-(mx * ux + my * uy + mz * uz) / s).clamped(-1.0, 1.0)))
        if strengthUt.isNaN {
            strengthUt = s
            dipDeg = d
        } else {
            strengthUt += MagneticCheck.smoothing * (s - strengthUt)
            dipDeg += MagneticCheck.smoothing * (d - dipDeg)
        }
        if expectedUt.isNaN { return }
        let excess = MagneticCheck.mathMax(abs(strengthUt / expectedUt - 1) / strengthTolerance,
                                           abs(dipDeg - expectedDipDeg) / dipToleranceDeg)
        // Hysteresis, so a reading near the limit does not flicker the warning.
        disturbed = excess > (disturbed ? 0.75 : 1.0)
    }

    func reset() {
        strengthUt = .nan
        dipDeg = .nan
        disturbed = false
    }

    private static let smoothing = 0.25

    /// Kotlin's `max`: NaN if either is (Swift's `max` keeps whichever operand its comparison favours).
    private static func mathMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : max(a, b) }
}
