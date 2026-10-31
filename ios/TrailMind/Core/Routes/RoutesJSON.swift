import Foundation

/// JSON as the Android app reads and writes it with org.json (`JSONObject`, `JSONArray`) and `JsonReader`: the same
/// conversions between strings and numbers, the same "No value for ..." failures, and a reader that can walk a
/// response one element at a time, so a reply cut short at a size limit still yields what came before the cut.
enum RoutesJSON {
    struct JSONError: Error, LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The reader ran out of input in the middle of a value.
    struct EndOfInput: Error, LocalizedError, Equatable {
        var errorDescription: String? { "End of input" }
    }

    /// An object's members in the order they arrived (org.json keeps insertion order); a repeated key replaces the
    /// earlier value, as `JSONObject.put` does.
    struct Object: Equatable {
        private(set) var keys: [String] = []
        private(set) var values: [String: Value] = [:]

        init() {}

        init(_ pairs: [(String, Value)]) {
            for (k, v) in pairs { self[k] = v }
        }

        subscript(_ key: String) -> Value? {
            get { values[key] }
            set {
                if values[key] == nil, newValue != nil { keys.append(key) }
                if newValue == nil { keys.removeAll { $0 == key } }
                values[key] = newValue
            }
        }
    }

    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        /// The literal as it was written, as `JsonReader.nextString()` returns it.
        case number(String)
        case string(String)
        case array([Value])
        case object(Object)

        static func double(_ d: Double) -> Value { .number(RoutesJSON.numberText(d)) }
        static func long(_ l: Int64) -> Value { .number(String(l)) }

        var objectValue: Object? { if case .object(let o) = self { return o }; return nil }
        var arrayValue: [Value]? { if case .array(let a) = self { return a }; return nil }
        var isNull: Bool { if case .null = self { return true }; return false }

        // MARK: org.json conversions (libcore's JSON.toString / toDouble / toLong / toBoolean)

        /// `JSON.toString`: strings as they are, other values as Java prints them (JSON null as "null").
        var javaString: String {
            switch self {
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .number(let literal): return RoutesJSON.javaNumberString(literal)
            case .string(let s): return s
            case .array, .object: return serialized()
            }
        }

        /// `JSON.toDouble`: numbers, and strings Java can read as a double; nil for anything else.
        var javaDouble: Double? {
            switch self {
            case .number(let literal): return RoutesJSON.numberDouble(literal)
            case .string(let s): return RoutesJSON.parseJavaDouble(s)
            default: return nil
            }
        }

        /// `JSON.toLong`: integral numbers exactly, others as Java's `(long)` cast of their double value.
        var javaLong: Int64? {
            switch self {
            case .number(let literal):
                if let l = RoutesJSON.integralLiteral(literal) { return l }
                return RoutesJSON.numberDouble(literal).map(RoutesJSON.javaLongCast)
            case .string(let s): return RoutesJSON.parseJavaDouble(s).map(RoutesJSON.javaLongCast)
            default: return nil
            }
        }

        /// `JSON.toBoolean`: booleans, and the strings "true" and "false" in any case.
        var javaBool: Bool? {
            switch self {
            case .bool(let b): return b
            case .string(let s):
                if s.lowercased() == "true" { return true }
                if s.lowercased() == "false" { return false }
                return nil
            default: return nil
            }
        }

        // MARK: JSONObject accessors

        func opt(_ name: String) -> Value? { objectValue?[name] }

        func get(_ name: String) throws -> Value {
            guard let v = opt(name) else { throw JSONError("No value for \(name)") }
            return v
        }

        func optString(_ name: String, _ fallback: String = "") -> String { opt(name)?.javaString ?? fallback }

        func getString(_ name: String) throws -> String { try get(name).javaString }

        func optDouble(_ name: String, _ fallback: Double = .nan) -> Double { opt(name)?.javaDouble ?? fallback }

        func getDouble(_ name: String) throws -> Double {
            let v = try get(name)
            guard let d = v.javaDouble else { throw mismatch(v, name, "double") }
            return d
        }

        func optLong(_ name: String, _ fallback: Int64 = 0) -> Int64 { opt(name)?.javaLong ?? fallback }

        func getLong(_ name: String) throws -> Int64 {
            let v = try get(name)
            guard let l = v.javaLong else { throw mismatch(v, name, "long") }
            return l
        }

        func optBoolean(_ name: String, _ fallback: Bool = false) -> Bool { opt(name)?.javaBool ?? fallback }

        func optJSONObject(_ name: String) -> Value? { opt(name).flatMap { $0.objectValue != nil ? $0 : nil } }

        func getJSONObject(_ name: String) throws -> Value {
            let v = try get(name)
            guard v.objectValue != nil else { throw mismatch(v, name, "JSONObject") }
            return v
        }

        func optJSONArray(_ name: String) -> [Value]? { opt(name)?.arrayValue }

        func getJSONArray(_ name: String) throws -> [Value] {
            let v = try get(name)
            guard let a = v.arrayValue else { throw mismatch(v, name, "JSONArray") }
            return a
        }

        private func mismatch(_ v: Value, _ name: String, _ type: String) -> JSONError {
            JSONError("Value \(v.javaString) at \(name) cannot be converted to \(type)")
        }

        // MARK: Writing

        /// Compact JSON as `JSONObject.toString()` writes it.
        func serialized() -> String {
            var out = ""
            write(&out)
            return out
        }

        private func write(_ out: inout String) {
            switch self {
            case .null: out += "null"
            case .bool(let b): out += b ? "true" : "false"
            case .number(let literal): out += literal
            case .string(let s): RoutesJSON.quote(s, into: &out)
            case .array(let a):
                out += "["
                for (i, v) in a.enumerated() {
                    if i > 0 { out += "," }
                    v.write(&out)
                }
                out += "]"
            case .object(let o):
                out += "{"
                for (i, k) in o.keys.enumerated() {
                    if i > 0 { out += "," }
                    RoutesJSON.quote(k, into: &out)
                    out += ":"
                    o[k]?.write(&out)
                }
                out += "}"
            }
        }
    }

    // MARK: JSONArray accessors

    static func optDouble(_ a: [Value], _ i: Int, _ fallback: Double = .nan) -> Double {
        a.indices.contains(i) ? (a[i].javaDouble ?? fallback) : fallback
    }

    static func getDouble(_ a: [Value], _ i: Int) throws -> Double {
        guard a.indices.contains(i) else { throw JSONError("Index \(i) out of range [0..\(a.count))") }
        guard let d = a[i].javaDouble else { throw JSONError("Value \(a[i].javaString) at \(i) cannot be converted to double") }
        return d
    }

    static func getLong(_ a: [Value], _ i: Int) throws -> Int64 {
        guard a.indices.contains(i) else { throw JSONError("Index \(i) out of range [0..\(a.count))") }
        guard let l = a[i].javaLong else { throw JSONError("Value \(a[i].javaString) at \(i) cannot be converted to long") }
        return l
    }

    static func getJSONArray(_ a: [Value], _ i: Int) throws -> [Value] {
        guard a.indices.contains(i) else { throw JSONError("Index \(i) out of range [0..\(a.count))") }
        guard let v = a[i].arrayValue else { throw JSONError("Value \(a[i].javaString) at \(i) cannot be converted to JSONArray") }
        return v
    }

    static func getJSONObject(_ a: [Value], _ i: Int) throws -> Value {
        guard a.indices.contains(i) else { throw JSONError("Index \(i) out of range [0..\(a.count))") }
        guard a[i].objectValue != nil else { throw JSONError("Value \(a[i].javaString) at \(i) cannot be converted to JSONObject") }
        return a[i]
    }

    /// `JSONArray.isNull`: out of range or JSON null.
    static func isNull(_ a: [Value], _ i: Int) -> Bool { !a.indices.contains(i) || a[i].isNull }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> Value { try parse([UInt8](data)) }

    static func parse(_ text: String) throws -> Value { try parse(Array(text.utf8)) }

    static func parse(_ bytes: [UInt8]) throws -> Value {
        var reader = Reader(bytes)
        let value = try reader.value()
        reader.skipWhitespace()
        if !reader.atEnd { throw JSONError("Unexpected text after the JSON value at \(reader.offset)") }
        return value
    }

    /// A cursor over JSON bytes, for walking a document member by member as `JsonReader` does.
    struct Reader {
        private let b: [UInt8]
        /// The bytes stop at a size limit rather than at the end of the document, so a number running into the end
        /// may have been cut short too.
        private let truncated: Bool
        private(set) var offset = 0

        init(_ bytes: [UInt8], truncated: Bool = false) {
            b = bytes
            self.truncated = truncated
        }

        var atEnd: Bool { offset >= b.count }

        mutating func skipWhitespace() {
            while offset < b.count, b[offset] == 0x20 || b[offset] == 0x0A || b[offset] == 0x0D || b[offset] == 0x09 { offset += 1 }
        }

        /// The next significant byte, or EndOfInput.
        mutating func peek() throws -> UInt8 {
            skipWhitespace()
            guard offset < b.count else { throw EndOfInput() }
            return b[offset]
        }

        mutating func expect(_ c: UInt8) throws {
            let next = try peek()
            guard next == c else { throw JSONError("Expected '\(Character(Unicode.Scalar(c)))' at \(offset)") }
            offset += 1
        }

        mutating func beginObject() throws { try expect(UInt8(ascii: "{")) }
        mutating func beginArray() throws { try expect(UInt8(ascii: "[")) }

        /// Whether the object or array being read has another member, consuming the comma before it.
        mutating func hasNext(first: inout Bool, closing: UInt8) throws -> Bool {
            let next = try peek()
            if next == closing {
                offset += 1
                return false
            }
            if !first {
                guard next == UInt8(ascii: ",") else { throw JSONError("Expected ',' at \(offset)") }
                offset += 1
            }
            first = false
            return true
        }

        mutating func nextName() throws -> String {
            guard try peek() == UInt8(ascii: "\"") else { throw JSONError("Expected a name at \(offset)") }
            let name = try string()
            try expect(UInt8(ascii: ":"))
            return name
        }

        mutating func value() throws -> Value {
            let c = try peek()
            switch c {
            case UInt8(ascii: "{"):
                offset += 1
                var o = Object()
                var first = true
                while try hasNext(first: &first, closing: UInt8(ascii: "}")) {
                    let name = try nextName()
                    o[name] = try value()
                }
                return .object(o)
            case UInt8(ascii: "["):
                offset += 1
                var a: [Value] = []
                var first = true
                while try hasNext(first: &first, closing: UInt8(ascii: "]")) { a.append(try value()) }
                return .array(a)
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try word("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try word("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try word("null")
                return .null
            default:
                return .number(try number())
            }
        }

        mutating func skipValue() throws { _ = try value() }

        private mutating func word(_ w: String) throws {
            for u in w.utf8 {
                guard offset < b.count else { throw EndOfInput() }
                guard b[offset] == u else { throw JSONError("Unexpected character at \(offset)") }
                offset += 1
            }
        }

        private mutating func number() throws -> String {
            let start = offset
            func isNumberByte(_ c: UInt8) -> Bool {
                (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                    || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
            }
            while offset < b.count, isNumberByte(b[offset]) { offset += 1 }
            if offset >= b.count && truncated { throw EndOfInput() }
            let literal = String(decoding: b[start..<offset], as: UTF8.self)
            guard !literal.isEmpty, RoutesJSON.numberDouble(literal) != nil else {
                throw JSONError("Unexpected character at \(start)")
            }
            return literal
        }

        mutating func string() throws -> String {
            guard offset < b.count, b[offset] == UInt8(ascii: "\"") else { throw JSONError("Expected a string at \(offset)") }
            offset += 1
            var bytes: [UInt8] = []
            while true {
                guard offset < b.count else { throw EndOfInput() }
                let c = b[offset]
                offset += 1
                if c == UInt8(ascii: "\"") { break }
                if c != UInt8(ascii: "\\") {
                    bytes.append(c)
                    continue
                }
                guard offset < b.count else { throw EndOfInput() }
                let e = b[offset]
                offset += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "'"): bytes.append(e)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "u"):
                    var unit = try hex4()
                    var scalar: Unicode.Scalar?
                    if (0xD800...0xDBFF).contains(unit), offset + 1 < b.count, b[offset] == UInt8(ascii: "\\"), b[offset + 1] == UInt8(ascii: "u") {
                        let save = offset
                        offset += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                        } else {
                            offset = save
                        }
                    }
                    if scalar == nil {
                        if (0xD800...0xDFFF).contains(unit) { unit = 0xFFFD }
                        scalar = Unicode.Scalar(unit)
                    }
                    bytes.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
                default:
                    throw JSONError("Invalid escape sequence at \(offset - 2)")
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        private mutating func hex4() throws -> UInt32 {
            guard offset + 4 <= b.count else { throw EndOfInput() }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[offset]
                offset += 1
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw JSONError("Invalid escape sequence at \(offset - 1)")
                }
                v = v << 4 | d
            }
            return v
        }
    }

    // MARK: Numbers and text as Java has them

    /// An integral literal (no point or exponent) as `Long.parseLong` reads it, or nil.
    static func integralLiteral(_ literal: String) -> Int64? {
        if literal.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { return nil }
        return Int64(literal)
    }

    static func numberDouble(_ literal: String) -> Double? { Double(literal) }

    /// What `String.valueOf` gives for the number org.json made of `literal`: an Integer or Long when it is
    /// integral and fits, else a Double.
    static func javaNumberString(_ literal: String) -> String {
        if let l = integralLiteral(literal) { return String(l) }
        return numberDouble(literal).map(javaDoubleString) ?? literal
    }

    /// `Double.parseDouble` after trimming, as `Double.valueOf` reads a string: nil where Java would throw.
    static func parseJavaDouble(_ s: String) -> Double? {
        var t = s
        while let f = t.unicodeScalars.first, f.value <= 0x20 { t.unicodeScalars.removeFirst() }
        while let l = t.unicodeScalars.last, l.value <= 0x20 { t.unicodeScalars.removeLast() }
        if t.isEmpty { return nil }
        if let last = t.last, "fFdD".contains(last) { t.removeLast() }
        switch t {
        case "NaN", "+NaN", "-NaN": return .nan
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        guard t.range(of: "^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return Double(t)
    }

    /// Java's `(long) d`: truncation, with NaN as 0 and saturation at the ends of the range.
    static func javaLongCast(_ d: Double) -> Int64 { kTruncateL(d) }

    /// `Double.toString`: shortest digits, plain between 10^-3 and 10^7, else computer scientific ("1.0E-4").
    static func javaDoubleString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let (digits, exponent) = shortestDigits(abs(d))
        let sign = d < 0 ? "-" : ""
        let magnitude = abs(d)
        if magnitude >= 1e-3 && magnitude < 1e7 {
            // exponent: the power of ten of the first digit.
            if exponent >= 0 {
                let intCount = exponent + 1
                let intPart = digits.count >= intCount
                    ? String(digits.prefix(intCount)) : digits + String(repeating: "0", count: intCount - digits.count)
                let frac = digits.count > intCount ? String(digits.dropFirst(intCount)) : "0"
                return sign + intPart + "." + frac
            } else {
                return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits
            }
        }
        let mantissa = String(digits.prefix(1)) + "." + (digits.count > 1 ? String(digits.dropFirst()) : "0")
        return sign + mantissa + "E" + String(exponent)
    }

    /// The shortest round-trip decimal digits of a positive finite `d` and the power of ten of the first one.
    private static func shortestDigits(_ d: Double) -> (String, Int) {
        var s = "\(d)"
        var exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(s[s.index(after: e)...]) ?? 0
            s = String(s[..<e])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var all = intPart + fracPart
        var pointPos = intPart.count + exp
        // Strip leading zeros, moving the point.
        while all.count > 1, all.first == "0" {
            all.removeFirst()
            pointPos -= 1
        }
        while all.count > 1, all.last == "0" { all.removeLast() }
        return (all, pointPos - 1)
    }

    /// How org.json writes a double: integral values as longs ("54"), others as `Double.toString`.
    static func numberText(_ d: Double) -> String {
        if d == 0 && d.sign == .minus { return "-0" }
        if d.isFinite, d == d.rounded(.towardZero), abs(d) < 9.2e18 { return String(Int64(d)) }
        return javaDoubleString(d)
    }

    /// `JSONStringer` quoting: escapes quotes, backslashes, slashes and control characters.
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"", "\\", "/": out += "\\"; out.unicodeScalars.append(c)
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{0C}": out += "\\f"
            default:
                if c.value <= 0x1F {
                    out += "\\u" + String(String(c.value, radix: 16).padStart(4, "0"))
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        out += "\""
    }

    /// `URLEncoder.encode(s, "UTF-8")`: letters, digits and `.-*_` as they are, spaces as '+', the rest %XX.
    static func formEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += "%" + String(byte, radix: 16, uppercase: true).padStart(2, "0")
            }
        }
        return out
    }
}
