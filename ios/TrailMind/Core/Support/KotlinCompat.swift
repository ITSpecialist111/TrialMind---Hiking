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

/// `String.format(Locale.ROOT, ...)`: a decimal point and no grouping, whatever the phone's region, and Java's rounding.
/// Java rounds `%.Nf` half up on the shortest decimal form of the double (123.25 -> "123.3", 1.005 -> "1.01"), where C's
/// printf rounds the exact binary value half to even ("123.2", "1.00"); this follows Java so both apps print the same.
func fmt(_ format: String, _ args: CVarArg...) -> String {
    var out = ""
    var argIndex = 0
    let chars = Array(format)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        guard c == "%" else { out.append(c); i += 1; continue }
        if i + 1 < chars.count, chars[i + 1] == "%" { out.append("%"); i += 2; continue }
        // %[flags][width][.precision]conversion
        var j = i + 1
        var flags = ""
        while j < chars.count, "-+ 0#,".contains(chars[j]) { flags.append(chars[j]); j += 1 }
        var width = ""
        while j < chars.count, chars[j].isNumber { width.append(chars[j]); j += 1 }
        var precision: Int? = nil
        if j < chars.count, chars[j] == "." {
            j += 1
            var p = ""
            while j < chars.count, chars[j].isNumber { p.append(chars[j]); j += 1 }
            precision = Int(p) ?? 0
        }
        // Length modifiers (l, ll, h...) pass through to String(format:).
        var length = ""
        while j < chars.count, "lhqLjzt".contains(chars[j]) { length.append(chars[j]); j += 1 }
        guard j < chars.count else { out.append(contentsOf: chars[i...]); break }
        let conversion = chars[j]
        let spec = String(chars[i...j])
        let arg: CVarArg? = argIndex < args.count ? args[argIndex] : nil
        argIndex += 1
        if conversion == "f" || conversion == "F", let value = (arg as? Double) ?? (arg as? Float).map(Double.init) ?? (arg as? CGFloatConvertible)?.doubleValue {
            var text = javaFixed(value, precision ?? 6)
            if flags.contains("+"), !text.hasPrefix("-") { text = "+" + text }
            else if flags.contains(" "), !text.hasPrefix("-") { text = " " + text }
            if let w = Int(width), text.count < w {
                let pad = w - text.count
                if flags.contains("-") { text += String(repeating: " ", count: pad) }
                else if flags.contains("0") {
                    let signed = text.hasPrefix("-") || text.hasPrefix("+") || text.hasPrefix(" ")
                    let sign = signed ? String(text.prefix(1)) : ""
                    text = sign + String(repeating: "0", count: pad) + String(text.dropFirst(sign.count))
                } else { text = String(repeating: " ", count: pad) + text }
            }
            out += text
        } else if let arg {
            out += String(format: spec, locale: Locale(identifier: "en_US_POSIX"), arguments: [arg])
        } else {
            out += spec
        }
        _ = length
        i = j + 1
    }
    return out
}

/// Lets `fmt` accept CGFloat without importing CoreGraphics into Core.
protocol CGFloatConvertible { var doubleValue: Double { get } }

extension CGFloat: CGFloatConvertible {
    var doubleValue: Double { Double(self) }
}

/// Java's `%.Nf`: the shortest decimal digits of the double, rounded half up (away from zero) to `digits` places.
func javaFixed(_ x: Double, _ digits: Int) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
    let negative = x.sign == .minus
    var s = "\(abs(x))"
    var exponent = 0
    if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exponent = Int(s[s.index(after: e)...]) ?? 0
        s = String(s[..<e])
    }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = String(parts[0])
    let fracPart = parts.count > 1 ? String(parts[1]) : ""
    var digitChars = Array(intPart + fracPart).map { Int($0.asciiValue! - 48) }
    var point = intPart.count + exponent
    // Pad so the decimal point lies within or at the end of the digits.
    if point < 0 { digitChars.insert(contentsOf: Array(repeating: 0, count: -point), at: 0); point = 0 }
    let keep = point + digits
    if keep < digitChars.count {
        let roundUp = digitChars[keep] >= 5
        digitChars = Array(digitChars[0..<keep])
        if roundUp {
            var k = digitChars.count - 1
            var carry = true
            while carry && k >= 0 {
                digitChars[k] += 1
                if digitChars[k] == 10 { digitChars[k] = 0; k -= 1 } else { carry = false }
            }
            if carry { digitChars.insert(1, at: 0); point += 1 }
        }
    } else {
        digitChars += Array(repeating: 0, count: keep - digitChars.count)
    }
    var intDigits = point > 0 ? digitChars[0..<point].map(String.init).joined() : ""
    while intDigits.count > 1 && intDigits.hasPrefix("0") { intDigits.removeFirst() }
    if intDigits.isEmpty { intDigits = "0" }
    let fracDigits = digits > 0 ? digitChars[point..<(point + digits)].map(String.init).joined() : ""
    return (negative ? "-" : "") + intDigits + (digits > 0 ? "." + fracDigits : "")
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
