import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Streaming GPX 1.0/1.1 parser (tracks, routes, waypoints). Uses Foundation's SAX-style `XMLParser` so it works
/// identically on iOS and Linux, and refuses DTDs and external entities to avoid XXE.
enum GpxParser {
    static let maxPoints = 500_000

    static func parse(_ data: Data) throws -> GpxDocument {
        // As the Kotlin parser's disallow-doctype-decl feature does: no DTD, so no external or recursive entities.
        if declaresDoctype(data) { throw GpxParseError("Not a valid GPX file: DOCTYPE is disallowed") }
        let handler = Handler()
        // A stream, so libxml2 gets the file in chunks: given more than 10 MB in one go it stops ("huge input lookup").
        let parser = XMLParser(stream: InputStream(data: data))
        // Prefixes are stripped by hand, as the Kotlin handler falls back to doing with qualified names.
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = handler
        let ok = parser.parse()
        if let failure = handler.failure { throw failure }
        if !ok || handler.xmlError != nil {
            let reason = (handler.xmlError ?? parser.parserError)?.localizedDescription ?? "unreadable XML"
            throw GpxParseError("Not a valid GPX file: \(reason) (line \(parser.lineNumber))")
        }
        if !handler.sawGpxRoot { throw GpxParseError("File is XML but not GPX (no <gpx> root element)") }
        return handler.build()
    }

    static func parse(_ text: String) throws -> GpxDocument { try parse(Data(text.utf8)) }

    /// Reads and parses a GPX file (the Kotlin parser's `InputStream` overload).
    static func parse(contentsOf url: URL) throws -> GpxDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw GpxParseError("Could not read GPX: \(error.localizedDescription)")
        }
        return try parse(data)
    }

    /// An ISO-8601 time as epoch millis, accepting what `Instant.parse`, then `OffsetDateTime.parse`, then
    /// `LocalDateTime.parse` (taken as UTC) accept: `2025-05-01T09:00:00Z`, `...09:00:00.5+01:00`, `...09:00`.
    static func parseTime(_ text: String) -> Int64? {
        var t = trim(text)
        if t.isEmpty { return nil }
        return t.withUTF8 { parseIsoTime($0) }
    }

    private static func parseIsoTime(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
        var i = 0
        func digits(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var v = 0
            for k in i..<(i + count) {
                guard b[k] >= 0x30 && b[k] <= 0x39 else { return nil }
                v = v * 10 + Int(b[k] - 0x30)
            }
            i += count
            return v
        }
        func take(_ c: UInt8) -> Bool {
            guard i < b.count && b[i] == c else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), take(0x2D), let month = digits(2), take(0x2D), let day = digits(2),
              take(0x54) || take(0x74), var hour = digits(2), take(0x3A), let minute = digits(2) else { return nil }
        var second = 0
        var nanos = 0
        var hasSeconds = false
        if take(0x3A) {
            guard let s = digits(2) else { return nil }
            second = s
            hasSeconds = true
            if take(0x2E) {
                var count = 0
                while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 && count < 9 {
                    nanos = nanos * 10 + Int(b[i] - 0x30)
                    count += 1
                    i += 1
                }
                for _ in count..<9 { nanos *= 10 }
            }
        }
        var offsetS = 0
        var hasOffset = true
        if take(0x5A) || take(0x7A) {
            // Z: UTC.
        } else if i < b.count && (b[i] == 0x2B || b[i] == 0x2D) {
            let sign = b[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = digits(2), take(0x3A), let om = digits(2), oh <= 18, om <= 59 else { return nil }
            var os = 0
            if take(0x3A) {
                guard let s = digits(2), s <= 59 else { return nil }
                os = s
            }
            offsetS = sign * (oh * 3600 + om * 60 + os)
            guard abs(offsetS) <= 18 * 3600 else { return nil }
        } else {
            hasOffset = false
        }
        guard i == b.count else { return nil }
        // Instant.parse (seconds and an offset) also reads 24:00:00 as the next midnight and a leap second as :59.
        var nextDay: Int64 = 0
        if hasSeconds && hasOffset {
            if hour == 24 && minute == 0 && second == 0 && nanos == 0 {
                hour = 0
                nextDay = 1
            } else if hour == 23 && minute == 59 && second == 60 {
                second = 59
            }
        }
        guard (1...12).contains(month), day >= 1, day <= CivilDate.lengthOfMonth(Int64(year), month),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        let seconds = (CivilDate.epochDay(Int64(year), month, day) + nextDay) * 86_400 +
            Int64(hour * 3600 + minute * 60 + second) - Int64(offsetS)
        return seconds * 1000 + Int64(nanos / 1_000_000)
    }

    /// Whether the prolog (before the root element) declares a DOCTYPE. Looks at the markup as ASCII, so it works for
    /// UTF-8 and the other ASCII-compatible encodings, and for UTF-16.
    private static func declaresDoctype(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(64 * 1024))
        var text = head
        if head.count >= 2 {
            let bigEndian = (head[0] == 0xFE && head[1] == 0xFF) || (head[0] == 0x00 && head[1] == 0x3C)
            let littleEndian = (head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0x3C && head[1] == 0x00)
            if bigEndian || littleEndian {
                let units = stride(from: 0, to: head.count - 1, by: 2).map { k -> UInt16 in
                    bigEndian ? UInt16(head[k]) << 8 | UInt16(head[k + 1]) : UInt16(head[k + 1]) << 8 | UInt16(head[k])
                }
                text = Array(String(decoding: units, as: UTF16.self).utf8)
            }
        }
        var i = text.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        func at(_ s: String) -> Bool { text[i...].starts(with: s.utf8) }
        func skip(past s: String) -> Bool {
            let pattern = Array(s.utf8)
            var k = i
            while k + pattern.count <= text.count {
                if text[k..<(k + pattern.count)].elementsEqual(pattern) {
                    i = k + pattern.count
                    return true
                }
                k += 1
            }
            return false
        }
        while i < text.count {
            let c = text[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
            } else if at("<?") {
                guard skip(past: "?>") else { return false }
            } else if at("<!--") {
                guard skip(past: "-->") else { return false }
            } else {
                return at("<!DOCTYPE")
            }
        }
        return false
    }

    /// Kotlin's `Char.isWhitespace()`: Unicode space, line and paragraph separators, and the ASCII controls Java
    /// counts as white space.
    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if v < 0x80 { return v == 0x20 || (v >= 0x09 && v <= 0x0D) || (v >= 0x1C && v <= 0x1F) }
        switch c.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Kotlin's `String.trim()`.
    fileprivate static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        var lo = scalars.startIndex
        var hi = scalars.endIndex
        while lo < hi && isWhitespace(scalars[lo]) { lo = scalars.index(after: lo) }
        while hi > lo {
            let before = scalars.index(before: hi)
            if !isWhitespace(scalars[before]) { break }
            hi = before
        }
        return lo == scalars.startIndex && hi == scalars.endIndex ? s : String(scalars[lo..<hi])
    }

    /// Kotlin's `String.toDoubleOrNull()`: Java's floating-point syntax (so `1.5f`, `NaN` and `Infinity` but not `nan`,
    /// `inf` or `1,5`), allowing leading and trailing spaces and control characters.
    fileprivate static func toDoubleOrNull(_ s: String) -> Double? {
        var s = s
        return s.withUTF8 { javaDouble($0) }
    }

    private static func javaDouble(_ b: UnsafeBufferPointer<UInt8>) -> Double? {
        var lo = 0
        var hi = b.count
        while lo < hi && b[lo] <= 0x20 { lo += 1 }
        while hi > lo && b[hi - 1] <= 0x20 { hi -= 1 }
        var i = lo
        if i < hi && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
        func isWord(_ word: StaticString) -> Bool {
            word.utf8CodeUnitCount == hi - i &&
                word.withUTF8Buffer { w in (0..<w.count).allSatisfy { b[i + $0] == w[$0] } }
        }
        let negative = i > lo && b[lo] == 0x2D
        if isWord("NaN") { return .nan }
        if isWord("Infinity") { return negative ? -.infinity : .infinity }
        var end = hi
        // A float or double suffix: f, F, d or D.
        if end > i && (b[end - 1] | 0x20 == 0x66 || b[end - 1] | 0x20 == 0x64) { end -= 1 }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c | 0x20 >= 0x61 && c | 0x20 <= 0x66) }
        func count(_ test: (UInt8) -> Bool) -> Int {
            let start = i
            while i < end && test(b[i]) { i += 1 }
            return i - start
        }
        func exponent(_ marker: UInt8, required: Bool) -> Bool {
            guard i < end && b[i] | 0x20 == marker else { return !required }
            i += 1
            if i < end && (b[i] == 0x2B || b[i] == 0x2D) { i += 1 }
            return count(isDigit) > 0
        }
        if end - i >= 2 && b[i] == 0x30 && b[i + 1] | 0x20 == 0x78 {
            i += 2
            let whole = count(isHex)
            var fraction = 0
            if i < end && b[i] == 0x2E {
                i += 1
                fraction = count(isHex)
            }
            guard whole + fraction > 0, exponent(0x70, required: true) else { return nil }
        } else {
            let whole = count(isDigit)
            var fraction = 0
            var point = false
            if i < end && b[i] == 0x2E {
                point = true
                i += 1
                fraction = count(isDigit)
            }
            guard whole > 0 || (point && fraction > 0), exponent(0x65, required: false) else { return nil }
        }
        guard i == end else { return nil }
        return Double(String(decoding: UnsafeBufferPointer(rebasing: b[lo..<end]), as: UTF8.self))
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var sawGpxRoot = false
        var failure: GpxParseError?
        /// The first error the XML parser reported, other than libxml2's warnings. Linux's FoundationXML parses in
        /// recovery mode and can report success after one; the Kotlin (SAX) parser stops there.
        var xmlError: Error?
        private static let warningCodes: Set<Int> = [27, 93, 97, 98, 99, 100, 102, 106, 107]
        private var path: [String] = []
        private var text = ""
        private var textLength = 0
        private var docName: String?
        private var tracks: [GpxTrack] = []
        private var routes: [GpxRoute] = []
        private var waypoints: [Waypoint] = []
        private var pointCount = 0

        private var trkName: String?
        private var trkSegments: [[TrackPoint]]?
        private var segment: [TrackPoint]?
        private var rteName: String?
        private var rtePoints: [TrackPoint]?

        private var ptLat = Double.nan
        private var ptLon = Double.nan
        private var ptEle: Double?
        private var ptTime: Int64?
        private var ptName: String?
        private var ptDesc: String?

        private static let pointTags: Set<String> = ["trkpt", "rtept", "wpt"]

        func build() -> GpxDocument { GpxDocument(name: docName, tracks: tracks, routes: routes, waypoints: waypoints) }

        /// The element's local name, lower case: `g:TrkPt` is `trkpt`.
        private static func local(_ qName: String) -> String {
            if qName.utf8.allSatisfy({ ($0 < 0x41 || $0 > 0x5A) && $0 != 0x3A && $0 < 0x80 }) { return qName }
            guard let colon = qName.firstIndex(of: ":") else { return qName.lowercased() }
            return String(qName[qName.index(after: colon)...]).lowercased()
        }

        private static func coordinate(_ value: String?) -> Double {
            value.flatMap { GpxParser.toDoubleOrNull(GpxParser.trim($0)) } ?? .nan
        }

        private func clearText() {
            text = ""
            textLength = 0
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if failure != nil || xmlError != nil { return }
            let name = Self.local(elementName)
            if path.isEmpty && name == "gpx" { sawGpxRoot = true }
            path.append(name)
            clearText()
            switch name {
            case "trk":
                trkName = nil
                trkSegments = []
            case "trkseg":
                segment = []
            case "rte":
                rteName = nil
                rtePoints = []
            case "trkpt", "rtept", "wpt":
                ptLat = Self.coordinate(attributeDict["lat"])
                ptLon = Self.coordinate(attributeDict["lon"])
                ptEle = nil
                ptTime = nil
                ptName = nil
                ptDesc = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { append(String(decoding: CDATABlock, as: UTF8.self)) }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if failure != nil || xmlError != nil || Self.warningCodes.contains((parseError as NSError).code) { return }
            xmlError = parseError
            parser.abortParsing()
        }

        private func append(_ string: String) {
            // Caps runaway text, as the Kotlin handler does (it counts UTF-16 units).
            if textLength < 10_000 {
                text += string
                textLength += string.utf16.count
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if failure != nil || xmlError != nil { return }
            let name = Self.local(elementName)
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            let value = GpxParser.trim(text)
            let inPoint = Self.pointTags.contains(parent)
            switch name {
            case "ele":
                if inPoint { ptEle = GpxParser.toDoubleOrNull(value) }
            case "time":
                if inPoint { ptTime = GpxParser.parseTime(value) }
            case "name":
                if inPoint {
                    ptName = value
                } else if parent == "trk" {
                    trkName = value
                } else if parent == "rte" {
                    rteName = value
                } else if parent == "metadata" || parent == "gpx" { // gpx: GPX 1.0
                    if docName == nil { docName = value }
                }
            case "desc", "cmt":
                if inPoint && ptDesc == nil { ptDesc = value }
            case "trkpt", "rtept", "wpt":
                finishPoint(name, parser)
            case "trkseg":
                if let s = segment, !s.isEmpty { trkSegments?.append(s) }
                segment = nil
            case "trk":
                if let segments = trkSegments { tracks.append(GpxTrack(name: trkName, segments: segments)) }
                trkSegments = nil
            case "rte":
                if let points = rtePoints { routes.append(GpxRoute(name: rteName, points: points)) }
                rtePoints = nil
            default:
                break
            }
            if !path.isEmpty { path.removeLast() }
            clearText()
        }

        private func finishPoint(_ tag: String, _ parser: XMLParser) {
            if ptLat.isNaN || ptLon.isNaN || !(-90.0...90.0).contains(ptLat) || !(-180.0...180.0).contains(ptLon) { return }
            pointCount += 1
            if pointCount > GpxParser.maxPoints {
                failure = GpxParseError("GPX has more than \(GpxParser.maxPoints) points")
                parser.abortParsing()
                return
            }
            switch tag {
            case "trkpt":
                if segment == nil { segment = [] }
                segment?.append(TrackPoint(lat: ptLat, lon: ptLon, ele: ptEle, timeMs: ptTime))
            case "rtept":
                rtePoints?.append(TrackPoint(lat: ptLat, lon: ptLon, ele: ptEle, timeMs: ptTime))
                if let n = ptName, !n.isBlank {
                    waypoints.append(Waypoint(lat: ptLat, lon: ptLon, name: n, ele: ptEle, description: ptDesc))
                }
            case "wpt":
                let n = ptName.flatMap { $0.isBlank ? nil : $0 } ?? "Waypoint"
                waypoints.append(Waypoint(lat: ptLat, lon: ptLon, name: n, ele: ptEle, description: ptDesc))
            default:
                break
            }
        }
    }
}
