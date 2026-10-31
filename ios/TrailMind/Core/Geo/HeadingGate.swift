import Foundation

final class HeadingGate {
    private var headingDeg: Double? = nil
    private var acceptedAtMs: Int64 = 0
    private var pendingDeg: Double? = nil

    func accept(_ degrees: Double, _ elapsedMs: Int64) -> Bool {
        if !degrees.isFinite { return false }
        let previous = headingDeg
        if let previous = previous, abs(Geo.angleDiffDeg(previous, degrees)) < 1.0 {
            pendingDeg = nil
            return false
        }
        if previous != nil && elapsedMs - acceptedAtMs < 67 {
            pendingDeg = degrees
            return false
        }
        headingDeg = Geo.normalizeDeg(degrees)
        acceptedAtMs = elapsedMs
        pendingDeg = nil
        return true
    }

    func pendingDelayMs(_ elapsedMs: Int64) -> Int64? { pendingDeg.map { _ in max(67 - (elapsedMs - acceptedAtMs), 0) } }

    func flush(_ elapsedMs: Int64) -> Double? {
        guard let pending = pendingDeg else { return nil }
        return accept(pending, elapsedMs) ? headingDeg : nil
    }

    func reset() {
        headingDeg = nil
        pendingDeg = nil
        acceptedAtMs = 0
    }
}
