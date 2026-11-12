import Foundation

/// Writes GPX 1.1 accepted by Strava, OS Maps, Komoot, Garmin etc.
enum GpxWriter {
    static let creator = "TrailMind"

    static func writeTrack<Out: TextOutputStream>(
        _ out: inout Out,
        _ name: String,
        _ segments: [[TrackPoint]],
        waypoints: [Waypoint] = [],
        description: String? = nil,
        activityType: String? = "hiking"
    ) {
        header(&out, name, segments.first?.first?.timeMs)
        for w in waypoints { writeWpt(&out, w) }
        out.write("  <trk>\n    <name>\(esc(name))</name>\n")
        if let d = description, !d.isBlank { out.write("    <desc>\(esc(d))</desc>\n") }
        if let type = activityType, !type.isBlank { out.write("    <type>\(esc(type))</type>\n") }
        for seg in segments {
            if seg.isEmpty { continue }
            out.write("    <trkseg>\n")
            for p in seg {
                out.write("      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">")
                if let ele = p.ele { out.write("<ele>\(num(ele, 1))</ele>") }
                if let time = p.timeMs { out.write("<time>\(CivilDate.isoInstant(time))</time>") }
                out.write("</trkpt>\n")
            }
            out.write("    </trkseg>\n")
        }
        out.write("  </trk>\n</gpx>\n")
    }

    static func writeRoute<Out: TextOutputStream>(_ out: inout Out, _ name: String, _ points: [TrackPoint], waypoints: [Waypoint] = []) {
        header(&out, name, nil)
        for w in waypoints { writeWpt(&out, w) }
        out.write("  <rte>\n    <name>\(esc(name))</name>\n")
        for p in points {
            out.write("    <rtept lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">")
            if let ele = p.ele { out.write("<ele>\(num(ele, 1))</ele>") }
            out.write("</rtept>\n")
        }
        out.write("  </rte>\n</gpx>\n")
    }

    static func trackToString(_ name: String, _ segments: [[TrackPoint]], _ waypoints: [Waypoint] = []) -> String {
        var sw = ""
        writeTrack(&sw, name, segments, waypoints: waypoints)
        return sw
    }

    private static func header<Out: TextOutputStream>(_ out: inout Out, _ name: String, _ timeMs: Int64?) {
        out.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.write(
            "<gpx version=\"1.1\" creator=\"\(creator)\" xmlns=\"http://www.topografix.com/GPX/1/1\" " +
                "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " +
                "xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        )
        out.write("  <metadata>\n    <name>\(esc(name))</name>\n")
        if let time = timeMs { out.write("    <time>\(CivilDate.isoInstant(time))</time>\n") }
        out.write("  </metadata>\n")
    }

    private static func writeWpt<Out: TextOutputStream>(_ out: inout Out, _ w: Waypoint) {
        out.write("  <wpt lat=\"\(coord(w.lat))\" lon=\"\(coord(w.lon))\">")
        if let ele = w.ele { out.write("<ele>\(num(ele, 1))</ele>") }
        out.write("<name>\(esc(w.name))</name>")
        if let d = w.description { out.write("<desc>\(esc(d))</desc>") }
        out.write("</wpt>\n")
    }

    private static func coord(_ v: Double) -> String { num(v, 7) }

    private static func num(_ v: Double, _ decimals: Int) -> String {
        // Java's formatter spells these out; C's printf would write "nan" and "inf".
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        return fmt("%.\(decimals)f", v)
    }

    static func esc(_ s: String) -> String {
        var sb = ""
        sb.reserveCapacity(s.utf8.count + 8)
        for c in s.unicodeScalars {
            switch c {
            case "&": sb += "&amp;"
            case "<": sb += "&lt;"
            case ">": sb += "&gt;"
            case "\"": sb += "&quot;"
            case "'": sb += "&apos;"
            default:
                if c.value < 0x20 && c != "\n" && c != "\t" && c != "\r" { continue } // invalid in XML 1.0
                sb.unicodeScalars.append(c)
            }
        }
        return sb
    }
}
