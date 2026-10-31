import Foundation

// Kotlin number conversions that Swift doesn't match by default. Swift's `Int(_:)`/`Int64(_:)` trap on NaN and on
// values out of range, and `max`/`min` don't always return NaN for a NaN argument, where Kotlin carries on.

/// Kotlin's `Double.toInt()`: rounds towards zero, NaN becomes 0 and values beyond the 32-bit range saturate.
@inline(__always) func kTruncate(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 2_147_483_647.0 { return 2_147_483_647 }
    if x <= -2_147_483_648.0 { return -2_147_483_648 }
    return Int(x)
}

/// Kotlin's `Double.toLong()`: rounds towards zero, NaN becomes 0 and values beyond the 64-bit range saturate.
@inline(__always) func kTruncateL(_ x: Double) -> Int64 {
    if x.isNaN { return 0 }
    if x >= 9_223_372_036_854_775_807.0 { return Int64.max }
    if x <= -9_223_372_036_854_775_808.0 { return Int64.min }
    return Int64(x)
}

/// Kotlin's `maxOf(a, b)` for doubles (Java's `Math.max`): NaN when either argument is NaN.
@inline(__always) func kMaxOf(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : max(a, b) }

/// Kotlin's `minOf(a, b)` for doubles (Java's `Math.min`): NaN when either argument is NaN.
@inline(__always) func kMinOf(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : min(a, b) }
