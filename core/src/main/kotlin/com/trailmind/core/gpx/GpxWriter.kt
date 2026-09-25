package com.trailmind.core.gpx

import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import java.io.Writer
import java.time.Instant
import java.util.Locale

/** Writes GPX 1.1 accepted by Strava, OS Maps, Komoot, Garmin etc. */
object GpxWriter {
    const val CREATOR = "TrailMind"

    fun writeTrack(
        out: Writer,
        name: String,
        segments: List<List<TrackPoint>>,
        waypoints: List<Waypoint> = emptyList(),
        description: String? = null,
        activityType: String? = "hiking",
    ) {
        header(out, name, segments.firstOrNull()?.firstOrNull()?.timeMs)
        waypoints.forEach { writeWpt(out, it) }
        out.write("  <trk>\n    <name>${esc(name)}</name>\n")
        if (!description.isNullOrBlank()) out.write("    <desc>${esc(description)}</desc>\n")
        if (!activityType.isNullOrBlank()) out.write("    <type>${esc(activityType)}</type>\n")
        for (seg in segments) {
            if (seg.isEmpty()) continue
            out.write("    <trkseg>\n")
            for (p in seg) {
                out.write("      <trkpt lat=\"${coord(p.lat)}\" lon=\"${coord(p.lon)}\">")
                p.ele?.let { out.write("<ele>${num(it, 1)}</ele>") }
                p.timeMs?.let { out.write("<time>${Instant.ofEpochMilli(it)}</time>") }
                out.write("</trkpt>\n")
            }
            out.write("    </trkseg>\n")
        }
        out.write("  </trk>\n</gpx>\n")
        out.flush()
    }

    fun writeRoute(out: Writer, name: String, points: List<TrackPoint>, waypoints: List<Waypoint> = emptyList()) {
        header(out, name, null)
        waypoints.forEach { writeWpt(out, it) }
        out.write("  <rte>\n    <name>${esc(name)}</name>\n")
        for (p in points) {
            out.write("    <rtept lat=\"${coord(p.lat)}\" lon=\"${coord(p.lon)}\">")
            p.ele?.let { out.write("<ele>${num(it, 1)}</ele>") }
            out.write("</rtept>\n")
        }
        out.write("  </rte>\n</gpx>\n")
        out.flush()
    }

    fun trackToString(name: String, segments: List<List<TrackPoint>>, waypoints: List<Waypoint> = emptyList()): String {
        val sw = java.io.StringWriter()
        writeTrack(sw, name, segments, waypoints)
        return sw.toString()
    }

    private fun header(out: Writer, name: String, timeMs: Long?) {
        out.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.write(
            "<gpx version=\"1.1\" creator=\"$CREATOR\" xmlns=\"http://www.topografix.com/GPX/1/1\" " +
                "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " +
                "xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n",
        )
        out.write("  <metadata>\n    <name>${esc(name)}</name>\n")
        timeMs?.let { out.write("    <time>${Instant.ofEpochMilli(it)}</time>\n") }
        out.write("  </metadata>\n")
    }

    private fun writeWpt(out: Writer, w: Waypoint) {
        out.write("  <wpt lat=\"${coord(w.lat)}\" lon=\"${coord(w.lon)}\">")
        w.ele?.let { out.write("<ele>${num(it, 1)}</ele>") }
        out.write("<name>${esc(w.name)}</name>")
        w.description?.let { out.write("<desc>${esc(it)}</desc>") }
        out.write("</wpt>\n")
    }

    private fun coord(v: Double) = num(v, 7)

    private fun num(v: Double, decimals: Int) = String.format(Locale.ROOT, "%.${decimals}f", v)

    fun esc(s: String): String {
        val sb = StringBuilder(s.length + 8)
        for (c in s) {
            when {
                c == '&' -> sb.append("&amp;")
                c == '<' -> sb.append("&lt;")
                c == '>' -> sb.append("&gt;")
                c == '"' -> sb.append("&quot;")
                c == '\'' -> sb.append("&apos;")
                c.code < 0x20 && c != '\n' && c != '\t' && c != '\r' -> Unit // invalid in XML 1.0
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
