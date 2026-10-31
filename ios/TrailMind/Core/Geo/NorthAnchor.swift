import Foundation

/// Keeps a rotation-vector heading on magnetic north. Some sensor hubs (the Galaxy Watch4's, for one) fall back to
/// gyro-only fusion when their magnetometer is uncalibrated, and "north" is then wherever the device pointed when the
/// sensor started. Each magnetometer reading shows where magnetic north lies in the rotation vector's own frame; that
/// smoothed offset is taken off its heading. On a rotation vector that already follows the magnetometer it stays near 0.
final class NorthAnchor {
    private var sinA = 0.0
    private var cosA = 0.0
    private var has = false

    /// `r` is the rotation vector's 3x3 row-major matrix; `mx`, `my`, `mz` a magnetometer reading in device axes.
    func add(_ r: [Float], _ mx: Double, _ my: Double, _ mz: Double) {
        let east = Double(r[0]) * mx + Double(r[1]) * my + Double(r[2]) * mz
        let north = Double(r[3]) * mx + Double(r[4]) * my + Double(r[5]) * mz
        // The field's horizontal part gives the direction; skip readings where there is too little of it.
        if east * east + north * north < NorthAnchor.minHorizontalUt * NorthAnchor.minHorizontalUt { return }
        let a = atan2(east, north)
        if !has {
            sinA = sin(a)
            cosA = cos(a)
            has = true
        } else {
            sinA += NorthAnchor.smoothing * (sin(a) - sinA)
            cosA += NorthAnchor.smoothing * (cos(a) - cosA)
        }
    }

    /// Degrees to subtract from the rotation vector's azimuth to get a magnetic heading; 0 before any reading.
    var offsetDeg: Double { has ? toDegrees(atan2(sinA, cosA)) : 0.0 }

    func reset() {
        has = false
    }

    private static let smoothing = 0.05
    private static let minHorizontalUt = 5.0
}
