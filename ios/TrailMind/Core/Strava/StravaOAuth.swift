import Foundation

/// The pieces of Strava's OAuth 2 sign-in that don't need a network or the phone: building the authorize link, reading
/// what Strava sends back to the app, and the form bodies for the token calls.
///
/// Strava has no PKCE, so swapping the code for tokens needs a client secret. TrailMind is a personal app: each user
/// registers their own free Strava API application and gives TrailMind its Client ID and secret, which stay on the
/// phone. Nothing is bundled.
enum StravaOAuth {
    static let authorizePath = "/oauth/mobile/authorize"
    static let tokenPath = "/oauth/token"
    static let deauthorizePath = "/oauth/deauthorize"

    /// Where Strava sends the user back to. Strava only checks the host against the application's Authorization
    /// Callback Domain, and always accepts `localhost`, so the user enters `localhost` there.
    static let redirectUri = "trailmind://localhost/strava"
    static let callbackDomain = "localhost"

    /// `read` to know who signed in, `activity:write` to post hikes. Nothing that reads their activities.
    static let scope = "read,activity:write"
    static let uploadScope = "activity:write"

    enum Redirect: Hashable {
        case granted(Granted)
        /// The user said no, or Strava refused (for example a wrong Client ID).
        case refused(reason: String)
        /// Not an answer to the sign-in this phone started.
        case invalid(reason: String)

        struct Granted: Hashable {
            var code: String
            var scopes: Set<String>

            var canUpload: Bool { scopes.contains(StravaOAuth.uploadScope) }
        }
    }

    /// The page the user signs in and approves on. Strava's own app opens for it when it's installed.
    static func authorizeUrl(_ base: String, _ clientId: String, _ state: String) -> String {
        trimEnd(base, "/") + authorizePath + "?" + form(
            ("client_id", trim(clientId)),
            ("redirect_uri", redirectUri),
            ("response_type", "code"),
            ("approval_prompt", "auto"),
            ("scope", scope),
            ("state", state)
        )
    }

    /// Whether `url` is Strava sending the user back, whatever it says.
    static func isRedirect(_ url: String) -> Bool {
        guard let u = JavaUri(url) else { return false }
        return equalsIgnoreCase(u.scheme, "trailmind") && equalsIgnoreCase(u.host, callbackDomain)
            && (u.path ?? "").unicodeScalars.starts(with: "/strava".unicodeScalars)
    }

    /// What Strava's redirect says. `expectedState` is the random value this phone sent; anything else is ignored.
    static func parseRedirect(_ url: String, _ expectedState: String?) -> Redirect {
        if !isRedirect(url) { return .invalid(reason: "Not a Strava sign-in link.") }
        guard let expectedState = expectedState, !expectedState.isEmpty else {
            return .invalid(reason: "No Strava sign-in is waiting. Start again with Connect with Strava.")
        }
        // Any app or web page can send this link, so a malformed one is just not an answer.
        guard let q = try? query(url) else { return .invalid(reason: "This isn't a sign-in answer from Strava.") }
        // Compared in full and without leaking where they differ, as the value is a one-time secret.
        if !constantTimeEquals(q["state"] ?? "", expectedState) {
            return .invalid(reason: "This sign-in isn't the one TrailMind started. Try Connect with Strava again.")
        }
        if let error = q["error"], !KotlinText.isBlank(error) {
            return .refused(reason: error == "access_denied" ? "You didn't allow TrailMind on Strava." : "Strava said: " + error + ".")
        }
        let code = q["code"] ?? ""
        if KotlinText.isBlank(code) { return .invalid(reason: "Strava didn't send a sign-in code.") }
        let scopes = Set(splitScopes(q["scope"] ?? "").map { trim($0) }.filter { !$0.isEmpty })
        return .granted(Redirect.Granted(code: code, scopes: scopes))
    }

    static func tokenRequestBody(_ clientId: String, _ clientSecret: String, _ code: String) -> String {
        form(("client_id", trim(clientId)), ("client_secret", trim(clientSecret)), ("code", code), ("grant_type", "authorization_code"))
    }

    static func refreshRequestBody(_ clientId: String, _ clientSecret: String, _ refreshToken: String) -> String {
        form(("client_id", trim(clientId)), ("client_secret", trim(clientSecret)), ("grant_type", "refresh_token"),
             ("refresh_token", refreshToken))
    }

    static func form(_ pairs: (String, String)...) -> String {
        pairs.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&")
    }

    /// `java.net.URLEncoder` in UTF-8: letters, digits and `.-*_` stay, a space becomes '+' and every other byte %XX.
    private static func enc(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            case UInt8(ascii: " "):
                out += "+"
            default:
                out += "%" + String(b, radix: 16, uppercase: true).padStart(2, "0")
            }
        }
        return out
    }

    private static func query(_ url: String) throws -> [String: String] {
        let raw = substringBefore(substringAfter(url, "?"), "#")
        if raw.isEmpty { return [:] }
        var out: [String: String] = [:]
        for part in raw.unicodeScalars.split(separator: "&").map({ String(Substring($0)) }) {
            let k = try percentDecode(substringBefore(part, "="), plusIsSpace: true)
            out[k] = try percentDecode(substringAfter(part, "="), plusIsSpace: true)
        }
        return out
    }

    private struct MalformedEscape: Error {}

    /// `java.net.URLDecoder` (`plusIsSpace`) or `URI.decode` in UTF-8: each run of %xy escapes is read as UTF-8, bad
    /// bytes becoming U+FFFD (Java writes one where an escaped surrogate gives three here: only garbage reads
    /// differently), and a malformed escape throws. A link has passed `isRedirect` before it gets here, so any escape is
    /// a plain hex pair, which is all this reads.
    fileprivate static func percentDecode(_ s: String, plusIsSpace: Bool) throws -> String {
        let c = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(c.count)
        var i = 0
        while i < c.count {
            if c[i] == 0x25 {
                var bytes: [UInt8] = []
                while i < c.count && c[i] == 0x25 {
                    guard i + 2 < c.count, let hi = hexValue(c[i + 1]), let lo = hexValue(c[i + 2]) else { throw MalformedEscape() }
                    bytes.append(hi << 4 | lo)
                    i += 3
                }
                out.append(contentsOf: String(decoding: bytes, as: UTF8.self).utf16)
            } else {
                out.append(plusIsSpace && c[i] == 0x2B ? 0x20 : c[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func hexValue(_ c: UInt16) -> UInt8? {
        switch c {
        case 0x30...0x39: return UInt8(c - 0x30)
        case 0x41...0x46: return UInt8(c - 0x41 + 10)
        case 0x61...0x66: return UInt8(c - 0x61 + 10)
        default: return nil
        }
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf16), y = Array(b.utf16)
        var diff = x.count ^ y.count
        for i in 0..<min(x.count, y.count) { diff |= Int(x[i] ^ y[i]) }
        return diff == 0
    }

    /// Kotlin's `equals(other, ignoreCase = true)`; the scheme and host it compares are ASCII.
    private static func equalsIgnoreCase(_ a: String?, _ b: String) -> Bool { a?.lowercased() == b.lowercased() }

    private static func trim(_ s: String) -> String { KotlinText.trim(s) }

    /// Kotlin's `trimEnd(char)`.
    private static func trimEnd(_ s: String, _ c: Unicode.Scalar) -> String {
        var scalars = s.unicodeScalars
        while scalars.last == c { scalars.removeLast() }
        return String(scalars)
    }

    /// Kotlin's `substringBefore`: up to the first `delimiter`, or all of `s`.
    private static func substringBefore(_ s: String, _ delimiter: Unicode.Scalar) -> String {
        guard let i = s.unicodeScalars.firstIndex(of: delimiter) else { return s }
        return String(Substring(s.unicodeScalars[..<i]))
    }

    /// Kotlin's `substringAfter(delimiter, "")`: after the first `delimiter`, or "".
    private static func substringAfter(_ s: String, _ delimiter: Unicode.Scalar) -> String {
        guard let i = s.unicodeScalars.firstIndex(of: delimiter) else { return "" }
        return String(Substring(s.unicodeScalars[s.unicodeScalars.index(after: i)...]))
    }
}

/// Kotlin's `split(',', ' ')`, keeping empty pieces.
private func splitScopes(_ s: String) -> [String] {
    s.unicodeScalars.split(omittingEmptySubsequences: false) { $0 == "," || $0 == " " }.map { String(Substring($0)) }
}

/// The short-lived access token and the refresh token that renews it, as Strava hands them out.
struct StravaTokens: Hashable, Codable {
    var accessToken: String
    var refreshToken: String
    /// Seconds since 1970. Access tokens last six hours.
    var expiresAtS: Int64
    var scope: String = ""

    /// True when the access token is about to lapse or has: Strava returns the same one while more than an hour is left.
    func needsRefresh(_ nowS: Int64, marginS: Int64 = 600) -> Bool { expiresAtS - nowS <= marginS }

    var canUpload: Bool { splitScopes(scope).contains { $0 == StravaOAuth.uploadScope } }
}

/// Who signed in, for showing "linked as".
struct StravaAthlete: Hashable, Codable {
    var id: Int64
    var username: String?
    var firstName: String?
    var lastName: String?

    /// "@username" when the athlete has one (many don't).
    var handle: String? { username.flatMap { KotlinText.isBlank($0) ? nil : "@" + $0 } }

    var fullName: String {
        [firstName, lastName].compactMap { $0.flatMap { KotlinText.isBlank($0) ? nil : $0 } }.joined(separator: " ")
    }

    /// What to show: the name, then the handle, or whichever Strava gave.
    var display: String {
        let shown = [fullName.isEmpty ? nil : fullName, handle].compactMap { $0 }.joined(separator: " · ")
        return shown.isEmpty ? "Strava athlete \(id)" : shown
    }
}

/// Builds a multipart/form-data body, which is how Strava takes an uploaded file.
final class StravaMultipart {
    let boundary: String
    private var out: [UInt8] = []

    init(_ boundary: String = "TrailMind" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")) {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    @discardableResult
    func field(_ name: String, _ value: String) -> StravaMultipart {
        out += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(name))\"\r\n\r\n".utf8
        out += value.utf8
        out += "\r\n".utf8
        return self
    }

    @discardableResult
    func file(_ name: String, _ fileName: String, _ mime: String, _ bytes: [UInt8]) -> StravaMultipart {
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(name))\"; filename=\"\(quote(fileName))\"\r\n"
        out += "\(head)Content-Type: \(mime)\r\n\r\n".utf8
        out += bytes
        out += "\r\n".utf8
        return self
    }

    func build() -> [UInt8] { out + Array("--\(boundary)--\r\n".utf8) }

    private func quote(_ s: String) -> String {
        var quoted = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            switch c {
            case "\"": quoted.append("'")
            case "\r", "\n": quoted.append(" ")
            default: quoted.append(c)
            }
        }
        return String(quoted)
    }
}

/// Reads a link as `java.net.URI` does (RFC 2396), so that a link is Strava's redirect exactly when it is on Android:
/// nil where `URI(link)` throws, else the scheme, the host of a server authority and the decoded path. Only host names
/// are read as hosts: an IPv4 or IPv6 address is never `localhost`, so a link with one comes out hostless or nil.
private struct JavaUri {
    private(set) var scheme: String?
    private(set) var host: String?
    private var rawPath: String?
    private let s: [UInt16]

    /// `getPath()`: the path with its escapes decoded; nil for an opaque link such as `trailmind:strava`.
    var path: String? { rawPath.map { (try? StravaOAuth.percentDecode($0, plusIsSpace: false)) ?? $0 } }

    init?(_ input: String) {
        s = Array(input.utf16)
        do { try parse() } catch { return nil }
    }

    private struct Malformed: Error {}

    /// The ASCII characters a part may hold; `escaped` also allows %xx escapes and visible non-ASCII characters.
    private struct Chars {
        let set: Set<UInt16>
        let escaped: Bool
        init(_ chars: String, escaped: Bool = false) {
            set = Set(chars.utf16)
            self.escaped = escaped
        }
    }

    private static let alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    private static let digits = "0123456789"
    private static let unreserved = alpha + digits + "-_.!~*'()"
    private static let alphaChars = Chars(alpha)
    private static let alphanumChars = Chars(alpha + digits)
    private static let alphanumDashChars = Chars(alpha + digits + "-")
    private static let digitChars = Chars(digits)
    private static let schemeChars = Chars(alpha + digits + "+-.")
    private static let uricChars = Chars(unreserved + ";/?:@&=+$,[]", escaped: true)
    private static let pathChars = Chars(unreserved + ":@&=+$,;/", escaped: true)
    private static let userInfoChars = Chars(unreserved + ";:&=+$,", escaped: true)
    private static let regNameChars = Chars(unreserved + "$,;:@&=+", escaped: true)
    private static let serverChars = Chars(unreserved + ";:&=+$,-.:@[]", escaped: true)
    /// java.net.URI checks a server authority against this, with a bare '%', unless the authority starts with ']'.
    private static let serverPercentChars = Chars(unreserved + ";:&=+$,-.:@[]%", escaped: true)
    private static let hexDigits = Set((digits + "ABCDEFabcdef").utf16)

    private mutating func parse() throws {
        let n = s.count
        var p = scan(0, n, err: "/?#", stop: ":")
        if p >= 0 && at(p, n, ":") {
            if p == 0 { throw Malformed() }
            try check(0, 1, JavaUri.alphaChars)
            try check(1, p, JavaUri.schemeChars)
            scheme = string(0, p)
            p += 1
            if at(p, n, "/") {
                p = try hierarchical(p, n)
            } else {
                let q = scan(p, n, stop: "#")
                if q <= p { throw Malformed() }
                try check(p, q, JavaUri.uricChars)
                p = q
            }
        } else {
            p = try hierarchical(0, n)
        }
        if at(p, n, "#") {
            try check(p + 1, n, JavaUri.uricChars)
            p = n
        }
        if p < n { throw Malformed() }
    }

    private mutating func hierarchical(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        if at(p, n, "/") && at(p + 1, n, "/") {
            p += 2
            let q = scan(p, n, stop: "/?#")
            if q > p {
                host = try authorityHost(p, q)
                p = q
            } else if q >= n {
                throw Malformed()
            }
        }
        var q = scan(p, n, stop: "?#")
        try check(p, q, JavaUri.pathChars)
        rawPath = string(p, q)
        p = q
        if at(p, n, "?") {
            p += 1
            q = scan(p, n, stop: "#")
            try check(p, q, JavaUri.uricChars)
            p = q
        }
        return p
    }

    /// The host of a server authority in [start, end), nil for a registry-based one; throws where java.net.URI does.
    private func authorityHost(_ start: Int, _ end: Int) throws -> String? {
        let serverSet = scan(start, end, stop: "]") > start ? JavaUri.serverPercentChars : JavaUri.serverChars
        let server = try scan(start, end, serverSet) == end
        let registry = try scan(start, end, JavaUri.regNameChars) == end
        if registry && !server { return nil }
        if server, let host = try? serverHost(start, end) { return host }
        if registry { return nil }
        throw Malformed()
    }

    /// `[userinfo@]hostname[:port]`.
    private func serverHost(_ start: Int, _ end: Int) throws -> String {
        var p = start
        let q = scan(p, end, err: "/?#", stop: "@")
        if q >= p && at(q, end, "@") {
            try check(p, q, JavaUri.userInfoChars)
            p = q + 1
        }
        let hostEnd = try hostname(p, end)
        let host = string(p, hostEnd)
        p = hostEnd
        if at(p, end, ":") {
            p += 1
            let q = try scan(p, end, JavaUri.digitChars)
            if q > p {
                guard Int32(string(p, q)) != nil else { throw Malformed() }
                p = q
            }
        }
        if p < end { throw Malformed() }
        return host
    }

    /// Labels of letters, digits and inner hyphens joined by dots, the last label starting with a letter.
    private func hostname(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        var last = -1
        repeat {
            var q = try scan(p, n, JavaUri.alphanumChars)
            if q <= p { break }
            last = p
            p = q
            q = try scan(p, n, JavaUri.alphanumDashChars)
            if q > p {
                if s[q - 1] == 0x2D { throw Malformed() }
                p = q
            }
            if !at(p, n, ".") { break }
            p += 1
        } while p < n
        if p < n && !at(p, n, ":") { throw Malformed() }
        if last < 0 { throw Malformed() }
        if last > start && !JavaUri.alphaChars.set.contains(s[last]) { throw Malformed() }
        return p
    }

    private func at(_ p: Int, _ end: Int, _ c: Unicode.Scalar) -> Bool { p < end && s[p] == UInt16(c.value) }

    private func string(_ start: Int, _ end: Int) -> String { String(decoding: s[start..<end], as: UTF16.self) }

    /// The index of the first `stop` character from `start`, or `end`; -1 if an `err` character comes first.
    private func scan(_ start: Int, _ end: Int, err: String = "", stop: String) -> Int {
        var p = start
        while p < end {
            if err.utf16.contains(s[p]) { return -1 }
            if stop.utf16.contains(s[p]) { break }
            p += 1
        }
        return p
    }

    /// Past the run of `chars` from `start`; where escapes are allowed, a malformed one throws.
    private func scan(_ start: Int, _ end: Int, _ chars: Chars) throws -> Int {
        var p = start
        while p < end {
            let c = s[p]
            if chars.set.contains(c) {
                p += 1
            } else if chars.escaped && c == 0x25 {
                guard p + 3 <= end, JavaUri.hexDigits.contains(s[p + 1]), JavaUri.hexDigits.contains(s[p + 2]) else {
                    throw Malformed()
                }
                p += 3
            } else if chars.escaped && JavaUri.isOther(c) {
                p += 1
            } else {
                break
            }
        }
        return p
    }

    private func check(_ start: Int, _ end: Int, _ chars: Chars) throws {
        if try scan(start, end, chars) < end { throw Malformed() }
    }

    /// Java's visible non-ASCII characters: past the C1 controls, and not a space or line or paragraph separator.
    private static func isOther(_ c: UInt16) -> Bool {
        guard c > 0x9F else { return false }
        guard let scalar = Unicode.Scalar(c) else { return true }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }
}
