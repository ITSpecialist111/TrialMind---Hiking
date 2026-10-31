import Foundation

// Helpers that keep ported Kotlin behaviour identical, so Android and iPhone show the same figures.

/// Kotlin's `roundToInt()`/`Math.round`: halves round towards positive infinity (-2.5 -> -2), unlike Swift's `.rounded()`.
@inline(__always) func kRound(_ x: Double) -> Int {
    guard x.isFinite else { return x.isNaN ? 0 : (x > 0 ? Int.max : Int.min) }
    return Int((x + 0.5).rounded(.down))
}

/// Kotlin's `roundToLong()`.
@inline(__always) func kRoundL(_ x: Double) -> Int64 {
    guard x.isFinite else { return x.isNaN ? 0 : (x > 0 ? Int64.max : Int64.min) }
    return Int64((x + 0.5).rounded(.down))
}

/// `String.format(Locale.ROOT, ...)`: a decimal point and no grouping, whatever the phone's region.
func fmt(_ format: String, _ args: CVarArg...) -> String {
    String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
}

@inline(__always) func toRadians(_ deg: Double) -> Double { deg * .pi / 180.0 }
@inline(__always) func toDegrees(_ rad: Double) -> Double { rad * 180.0 / .pi }

extension Comparable {
    /// Kotlin's `coerceIn`.
    @inline(__always) func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

extension String {
    /// Kotlin's `padStart`.
    func padStart(_ length: Int, _ pad: Character = " ") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}

/// Kotlin's `Int.mod`: always non-negative for a positive divisor.
@inline(__always) func kMod(_ a: Int, _ n: Int) -> Int { let r = a % n; return r < 0 ? r + n : r }

/// Wall-clock milliseconds since 1970, the unit every stored time uses (as on Android).
@inline(__always) func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
