import Foundation

/// Rules that keep TrailMind a polite tile client. Several community tile servers explicitly forbid
/// bulk/offline downloading ("prefetching") in their usage policies, so area downloads are refused
/// for those hosts regardless of what the user configures.
enum TilePolicy {
    /// Hosts whose published usage policy forbids bulk downloading. Suffix match.
    static let bulkDownloadForbiddenHosts = [
        "tile.openstreetmap.org",
        "openstreetmap.org",
        "openstreetmap.fr",
        "opentopomap.org",
        "tile.thunderforest.com",
        "cyclosm",
        "arcgisonline.com",
        "google.com",
        "googleapis.com",
        "bing.com",
        "virtualearth.net",
        // MapTiler Cloud's terms: no batch or bulk downloading of tiles.
        "maptiler.com",
    ]

    static let maxTilesPerDownload = 25_000
    static let maxZoom = 20
    static let premiumCacheMs: Int64 = 24 * 3_600_000

    /// A download fetches a Premium tile again unless it has this long left, so renewing restarts the 24 hours.
    static let premiumReuseMinLeftMs: Int64 = 20 * 3_600_000

    // Times wrap on overflow as Kotlin's Long arithmetic does, rather than trapping.
    static func premiumCacheFresh(_ cachedAtMs: Int64, _ nowMs: Int64) -> Bool {
        let age = nowMs &- cachedAtMs
        return age >= 0 && age < premiumCacheMs
    }

    static func premiumReusable(_ cachedAtMs: Int64, _ nowMs: Int64) -> Bool {
        premiumCacheFresh(cachedAtMs, nowMs) && cachedAtMs &+ premiumCacheMs &- nowMs >= premiumReuseMinLeftMs
    }

    static func premiumPurgeDue(_ cachedAtMs: Int64, _ nowMs: Int64, _ aheadMs: Int64 = 0) -> Bool {
        !premiumCacheFresh(cachedAtMs, nowMs) || nowMs &- cachedAtMs >= premiumCacheMs &- aheadMs
    }

    static func openDataTile(_ tile: TileKey, _ premiumFromZoom: Int?) -> TileKey {
        precondition((0...maxZoom).contains(tile.z))
        let zoom = min(tile.z, premiumFromZoom.map { $0 - 1 } ?? tile.z)
        precondition(zoom >= 0)
        let difference = tile.z - zoom
        return TileKey(zoom, tile.x >> difference, tile.y >> difference)
    }

    /// The host `java.net.URI` finds in the template with its placeholders filled, lower-cased; nil where it finds none.
    static func hostOf(_ template: String) -> String? {
        // Both braces escaped: Android's ICU regex rejects a bare '}' (the JVM accepts it).
        let url = template.replacingOccurrences(of: "\\{-?[a-zA-Z]+\\}", with: "0", options: .regularExpression)
        return JavaUri.host(url)?.lowercased()
    }

    static func isBulkDownloadForbidden(_ template: String) -> Bool {
        guard let host = hostOf(template) else { return true }
        return bulkDownloadForbiddenHosts.contains { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }
    }

    /// Fills {z} {x} {y} {s} {key}; {-y} gives TMS rows. `subdomains` rotate deterministically.
    static func fillTemplate(_ template: String, _ tile: TileKey, _ key: String? = nil, subdomains: String = "abc") -> String {
        let letters = Array(subdomains.utf16)
        let s = letters.isEmpty ? "" : String(decoding: [letters[kMod(tile.x + tile.y, letters.count)]], as: UTF16.self)
        return template
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{-y}", with: String(tile.tmsY))
            .replacingOccurrences(of: "{y}", with: String(tile.y))
            .replacingOccurrences(of: "{s}", with: s)
            .replacingOccurrences(of: "{key}", with: key ?? "")
    }

    static func validateTemplate(_ template: String) -> String? {
        let t = trimmed(template)
        if !t.hasPrefix("https://") && !t.hasPrefix("http://") { return "URL must start with https://" }
        if !t.contains("{z}") || !t.contains("{x}") || !(t.contains("{y}") || t.contains("{-y}")) {
            return "URL must contain {z}, {x} and {y} (or {-y})"
        }
        if hostOf(t) == nil { return "URL host is not valid" }
        return nil
    }

    /// Kotlin's `trim()`: drops what `Char.isWhitespace()` calls whitespace from both ends.
    private static func trimmed(_ text: String) -> String {
        func isWhitespace(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x09...0x0D, 0x1C...0x1F: return true
            default:
                let category = c.properties.generalCategory
                return category == .spaceSeparator || category == .lineSeparator || category == .paragraphSeparator
            }
        }
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }
}

/// The part of `java.net.URI`'s parser (RFC 2396 with its RFC 2732 IPv6 additions) that decides the host: nil wherever
/// the JVM's URI would throw or would have no host, as for a registry-based authority such as one with an underscore.
private struct JavaUri {
    private let input: [UInt16]
    private var host: String?

    private init(_ text: String) { input = Array(text.utf16) }

    static func host(_ text: String) -> String? {
        var parser = JavaUri(text)
        do {
            try parser.parse()
            return parser.host
        } catch {
            return nil
        }
    }

    private struct Malformed: Error {}

    /// Which US-ASCII characters a component allows, as 128 bits; bit 0 (NUL never matches) allows escapes instead.
    private struct Mask {
        let low: UInt64
        let high: UInt64

        static func of(_ chars: String) -> Mask {
            var low: UInt64 = 0, high: UInt64 = 0
            for c in chars.utf16 {
                if c < 64 { low |= 1 << UInt64(c) } else if c < 128 { high |= 1 << UInt64(c - 64) }
            }
            return Mask(low: low, high: high)
        }

        static func range(_ first: Unicode.Scalar, _ last: Unicode.Scalar) -> Mask {
            of(String(String.UnicodeScalarView((first.value...last.value).compactMap(Unicode.Scalar.init))))
        }

        static func | (a: Mask, b: Mask) -> Mask { Mask(low: a.low | b.low, high: a.high | b.high) }

        var allowsEscapes: Bool { low & 1 != 0 }

        func matches(_ c: UInt16) -> Bool {
            if c == 0 { return false }
            if c < 64 { return low >> UInt64(c) & 1 != 0 }
            if c < 128 { return high >> UInt64(c - 64) & 1 != 0 }
            return false
        }
    }

    private static let digit = Mask.range("0", "9")
    private static let alpha = Mask.range("A", "Z") | Mask.range("a", "z")
    private static let alphanum = alpha | digit
    private static let hex = digit | Mask.range("A", "F") | Mask.range("a", "f")
    private static let unreserved = alphanum | Mask.of("-_.!~*'()")
    private static let reserved = Mask.of(";/?:@&=+$,[]")
    private static let escaped = Mask(low: 1, high: 0)
    private static let uric = reserved | unreserved | escaped
    private static let path = unreserved | escaped | Mask.of(":@&=+$,") | Mask.of(";/")
    private static let dash = Mask.of("-")
    private static let dot = Mask.of(".")
    private static let userInfo = unreserved | escaped | Mask.of(";:&=+$,")
    private static let regName = unreserved | escaped | Mask.of("$,;:@&=+")
    private static let server = userInfo | alphanum | dash | Mask.of(".:@[]")
    private static let serverPercent = server | Mask.of("%")
    private static let scheme = alpha | digit | Mask.of("+-.")
    private static let scopeId = alphanum | Mask.of("_.")

    private static func unit(_ c: Character) -> UInt16 { c.utf16.first! }

    private func at(_ start: Int, _ end: Int, _ c: Character) -> Bool { start < end && input[start] == JavaUri.unit(c) }

    private func atText(_ start: Int, _ end: Int, _ text: String) -> Bool {
        let units = Array(text.utf16)
        if units.count > end - start { return false }
        return Array(input[start..<start + units.count]) == units
    }

    private func scan(_ start: Int, _ end: Int, _ c: Character) -> Int { at(start, end, c) ? start + 1 : start }

    /// Up to the first character in `stop`, or -1 at one in `err` before it.
    private func scan(_ start: Int, _ end: Int, err: String, stop: String) -> Int {
        let errs = Set(err.utf16), stops = Set(stop.utf16)
        var p = start
        while p < end {
            if errs.contains(input[p]) { return -1 }
            if stops.contains(input[p]) { break }
            p += 1
        }
        return p
    }

    private func scan(_ start: Int, _ end: Int, stop: String) -> Int { scan(start, end, err: "", stop: stop) }

    private func scan(_ start: Int, _ end: Int, _ mask: Mask) throws -> Int {
        var p = start
        while p < end {
            let c = input[p]
            if mask.matches(c) {
                p += 1
                continue
            }
            if mask.allowsEscapes {
                let q = try scanEscape(p, end, c)
                if q > p {
                    p = q
                    continue
                }
            }
            break
        }
        return p
    }

    private func scanEscape(_ start: Int, _ end: Int, _ c: UInt16) throws -> Int {
        if c == JavaUri.unit("%") {
            if start + 3 <= end && JavaUri.hex.matches(input[start + 1]) && JavaUri.hex.matches(input[start + 2]) {
                return start + 3
            }
            throw Malformed()
        }
        // Visible characters beyond US-ASCII are allowed unescaped.
        if c > 128 && !JavaUri.isSpaceChar(c) && !JavaUri.isISOControl(c) { return start + 1 }
        return start
    }

    private static func isSpaceChar(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        let category = scalar.properties.generalCategory
        return category == .spaceSeparator || category == .lineSeparator || category == .paragraphSeparator
    }

    private static func isISOControl(_ c: UInt16) -> Bool { c <= 0x1F || (0x7F...0x9F).contains(c) }

    private func checkChars(_ start: Int, _ end: Int, _ mask: Mask) throws {
        if try scan(start, end, mask) < end { throw Malformed() }
    }

    private mutating func parse() throws {
        let n = input.count
        var p = scan(0, n, err: "/?#", stop: ":")
        if p >= 0 && at(p, n, ":") {
            if p == 0 { throw Malformed() }
            try checkChars(0, 1, JavaUri.alpha)
            try checkChars(1, p, JavaUri.scheme)
            p += 1
            if at(p, n, "/") {
                p = try parseHierarchical(p, n)
            } else {
                let q = scan(p, n, stop: "#")
                if q <= p { throw Malformed() }
                try checkChars(p, q, JavaUri.uric)
                p = q
            }
        } else {
            p = try parseHierarchical(0, n)
        }
        if at(p, n, "#") {
            try checkChars(p + 1, n, JavaUri.uric)
            p = n
        }
        if p < n { throw Malformed() }
    }

    private mutating func parseHierarchical(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        if at(p, n, "/") && at(p + 1, n, "/") {
            p += 2
            let q = scan(p, n, stop: "/?#")
            if q > p {
                p = try parseAuthority(p, q)
            } else if q >= n {
                throw Malformed()
            }
            // An empty authority is allowed before a path, query or fragment.
        }
        var q = scan(p, n, stop: "?#")
        try checkChars(p, q, JavaUri.path)
        p = q
        if at(p, n, "?") {
            p += 1
            q = scan(p, n, stop: "#")
            try checkChars(p, q, JavaUri.uric)
            p = q
        }
        return p
    }

    private mutating func parseAuthority(_ start: Int, _ n: Int) throws -> Int {
        let p = start
        var q = p
        var failure: Error?
        // As in the JDK, any authority not starting with ']' counts as holding an IPv6 literal here.
        let serverChars = try scan(p, n, scan(p, n, stop: "]") > p ? JavaUri.serverPercent : JavaUri.server) == n
        let regChars = try scan(p, n, JavaUri.regName) == n
        if regChars && !serverChars { return n }
        if serverChars {
            do {
                q = try parseServer(p, n)
                if q < n { throw Malformed() }
            } catch {
                host = nil
                failure = error
                q = p
            }
        }
        if q < n {
            if regChars { return n }
            throw failure ?? Malformed()
        }
        return n
    }

    private mutating func parseServer(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        var q = scan(p, n, err: "/?#", stop: "@")
        if q >= p && at(q, n, "@") {
            try checkChars(p, q, JavaUri.userInfo)
            p = q + 1
        }
        if at(p, n, "[") {
            p += 1
            q = scan(p, n, err: "/?#", stop: "]")
            if q > p && at(q, n, "]") {
                let r = scan(p, q, stop: "%")
                if r > p {
                    try parseIPv6Reference(p, r)
                    if r + 1 == q { throw Malformed() }
                    try checkChars(r + 1, q, JavaUri.scopeId)
                } else {
                    try parseIPv6Reference(p, q)
                }
                host = String(decoding: input[(p - 1)...(q)], as: UTF16.self)
                p = q + 1
            } else {
                throw Malformed()
            }
        } else {
            q = parseIPv4Address(p, n)
            if q <= p { q = try parseHostname(p, n) }
            p = q
        }
        if at(p, n, ":") {
            p += 1
            q = scan(p, n, stop: "/")
            if q > p {
                try checkChars(p, q, JavaUri.digit)
                if Int32(String(decoding: input[p..<q], as: UTF16.self)) == nil { throw Malformed() }
                p = q
            }
        }
        if p < n { throw Malformed() }
        return p
    }

    // Decimal digits whose value fits in a byte.
    private func scanByte(_ start: Int, _ n: Int) throws -> Int {
        let q = try scan(start, n, JavaUri.digit)
        if q <= start { return q }
        guard let value = Int32(String(decoding: input[start..<q], as: UTF16.self)) else { throw Malformed() }
        return value > 255 ? start : q
    }

    /// The end of the IPv4 address at `start` (all of the interval when `strict`), or -1 where there is none.
    private func scanIPv4Address(_ start: Int, _ n: Int, _ strict: Bool) throws -> Int {
        var p = start
        let m = try scan(p, n, JavaUri.digit | JavaUri.dot)
        if m <= p || (strict && m != n) { return -1 }
        for part in 0..<4 {
            if part > 0 {
                let q = scan(p, m, ".")
                if q <= p { throw Malformed() }
                p = q
            }
            let q = try scanByte(p, m)
            if q <= p { throw Malformed() }
            p = q
        }
        if p < m { throw Malformed() }
        return p
    }

    private func takeIPv4Address(_ start: Int, _ n: Int) throws -> Int {
        let p = try scanIPv4Address(start, n, true)
        if p <= start { throw Malformed() }
        return p
    }

    private mutating func parseIPv4Address(_ start: Int, _ n: Int) -> Int {
        guard var p = try? scanIPv4Address(start, n, false) else { return -1 }
        // Only a port may follow an address.
        if p > start && p < n && input[p] != JavaUri.unit(":") { p = -1 }
        if p > start { host = String(decoding: input[start..<p], as: UTF16.self) }
        return p
    }

    private mutating func parseHostname(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        var lastLabel = -1
        repeat {
            // domainlabel = alphanum [ *( alphanum | "-" ) alphanum ]
            var q = try scan(p, n, JavaUri.alphanum)
            if q <= p { break }
            lastLabel = p
            p = q
            q = try scan(p, n, JavaUri.alphanum | JavaUri.dash)
            if q > p {
                if input[q - 1] == JavaUri.unit("-") { throw Malformed() }
                p = q
            }
            q = scan(p, n, ".")
            if q <= p { break }
            p = q
        } while p < n
        if p < n && !at(p, n, ":") { throw Malformed() }
        if lastLabel < 0 { throw Malformed() }
        // In a fully qualified hostname the rightmost label starts with a letter.
        if lastLabel > start && !JavaUri.alpha.matches(input[lastLabel]) { throw Malformed() }
        host = String(decoding: input[start..<p], as: UTF16.self)
        return p
    }

    // IPv6 addresses as java.net.URI reads them (RFC 2373 with its ::12.34.56.78 forms).
    private func parseIPv6Reference(_ start: Int, _ n: Int) throws {
        var bytes = 0
        var p = start
        var compressedZeros = false
        let q = try scanHexSeq(p, n, &bytes)
        if q > p {
            p = q
            if atText(p, n, "::") {
                compressedZeros = true
                p = try scanHexPost(p + 2, n, &bytes)
            } else if at(p, n, ":") {
                p = try takeIPv4Address(p + 1, n)
                bytes += 4
            }
        } else if atText(p, n, "::") {
            compressedZeros = true
            p = try scanHexPost(p + 2, n, &bytes)
        }
        if p < n || bytes > 16 || (!compressedZeros && bytes < 16) || (compressedZeros && bytes == 16) { throw Malformed() }
    }

    private func scanHexPost(_ start: Int, _ n: Int, _ bytes: inout Int) throws -> Int {
        var p = start
        if p == n { return p }
        let q = try scanHexSeq(p, n, &bytes)
        if q > p {
            p = q
            if at(p, n, ":") {
                p = try takeIPv4Address(p + 1, n)
                bytes += 4
            }
        } else {
            p = try takeIPv4Address(p, n)
            bytes += 4
        }
        return p
    }

    private func scanHexSeq(_ start: Int, _ n: Int, _ bytes: inout Int) throws -> Int {
        var p = start
        var q = try scan(p, n, JavaUri.hex)
        if q <= p || at(q, n, ".") { return -1 }
        if q > p + 4 { throw Malformed() }
        bytes += 2
        p = q
        while p < n {
            if !at(p, n, ":") || at(p + 1, n, ":") { break }
            p += 1
            q = try scan(p, n, JavaUri.hex)
            if q <= p { throw Malformed() }
            if at(q, n, ".") {
                p -= 1
                break
            }
            if q > p + 4 { throw Malformed() }
            bytes += 2
            p = q
        }
        return p
    }
}
