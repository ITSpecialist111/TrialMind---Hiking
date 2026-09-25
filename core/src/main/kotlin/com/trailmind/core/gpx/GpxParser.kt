package com.trailmind.core.gpx

import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler
import java.io.InputStream
import java.io.StringReader
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import javax.xml.parsers.SAXParserFactory

/**
 * Streaming GPX 1.0/1.1 parser (tracks, routes, waypoints). Uses SAX so it works identically on
 * Android and the JVM, and disables DTDs/external entities to avoid XXE.
 */
object GpxParser {
    const val MAX_POINTS = 500_000

    fun parse(input: InputStream): GpxDocument {
        val handler = Handler()
        try {
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = true
            trySetFeature(factory, "http://apache.org/xml/features/disallow-doctype-decl", true)
            trySetFeature(factory, "http://xml.org/sax/features/external-general-entities", false)
            trySetFeature(factory, "http://xml.org/sax/features/external-parameter-entities", false)
            val parser = factory.newSAXParser()
            val reader = parser.xmlReader
            reader.contentHandler = handler
            reader.errorHandler = handler
            reader.entityResolver = org.xml.sax.EntityResolver { _, _ -> InputSource(StringReader("")) }
            reader.parse(InputSource(input))
        } catch (e: GpxParseException) {
            throw e
        } catch (e: SAXException) {
            throw GpxParseException("Not a valid GPX file: ${e.message}", e)
        } catch (e: Exception) {
            throw GpxParseException("Could not read GPX: ${e.message}", e)
        }
        if (!handler.sawGpxRoot) throw GpxParseException("File is XML but not GPX (no <gpx> root element)")
        return handler.build()
    }

    fun parse(text: String): GpxDocument = parse(text.byteInputStream(Charsets.UTF_8))

    private fun trySetFeature(f: SAXParserFactory, name: String, value: Boolean) {
        try {
            f.setFeature(name, value)
        } catch (_: Exception) {
            // Not all parsers (e.g. older Android Expat) support every feature.
        }
    }

    fun parseTime(text: String): Long? {
        val t = text.trim()
        if (t.isEmpty()) return null
        return runCatching { Instant.parse(t).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(t).toInstant().toEpochMilli() }.getOrNull()
            ?: runCatching { LocalDateTime.parse(t).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
    }

    private class Handler : DefaultHandler() {
        var sawGpxRoot = false
        private val path = ArrayList<String>()
        private val text = StringBuilder()
        private var docName: String? = null
        private val tracks = ArrayList<GpxTrack>()
        private val routes = ArrayList<GpxRoute>()
        private val waypoints = ArrayList<Waypoint>()
        private var pointCount = 0

        private var trkName: String? = null
        private var trkSegments: ArrayList<List<TrackPoint>>? = null
        private var segment: ArrayList<TrackPoint>? = null
        private var rteName: String? = null
        private var rtePoints: ArrayList<TrackPoint>? = null

        private var ptLat = Double.NaN
        private var ptLon = Double.NaN
        private var ptEle: Double? = null
        private var ptTime: Long? = null
        private var ptName: String? = null
        private var ptDesc: String? = null

        fun build() = GpxDocument(docName, tracks, routes, waypoints)

        private fun local(localName: String?, qName: String?): String =
            (localName?.takeIf { it.isNotEmpty() } ?: qName?.substringAfter(':') ?: "").lowercase()

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes) {
            val name = local(localName, qName)
            if (path.isEmpty() && name == "gpx") sawGpxRoot = true
            path.add(name)
            text.setLength(0)
            when (name) {
                "trk" -> { trkName = null; trkSegments = ArrayList() }
                "trkseg" -> segment = ArrayList()
                "rte" -> { rteName = null; rtePoints = ArrayList() }
                "trkpt", "rtept", "wpt" -> {
                    ptLat = attributes.getValue("lat")?.trim()?.toDoubleOrNull() ?: Double.NaN
                    ptLon = attributes.getValue("lon")?.trim()?.toDoubleOrNull() ?: Double.NaN
                    ptEle = null; ptTime = null; ptName = null; ptDesc = null
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (text.length < 10_000) text.appendRange(ch, start, start + length)
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            val name = local(localName, qName)
            val parent = if (path.size >= 2) path[path.size - 2] else ""
            val value = text.toString().trim()
            when (name) {
                "ele" -> if (parent in POINT_TAGS) ptEle = value.toDoubleOrNull()
                "time" -> if (parent in POINT_TAGS) ptTime = parseTime(value)
                "name" -> when (parent) {
                    in POINT_TAGS -> ptName = value
                    "trk" -> trkName = value
                    "rte" -> rteName = value
                    "metadata" -> if (docName == null) docName = value
                    "gpx" -> if (docName == null) docName = value // GPX 1.0
                }
                "desc", "cmt" -> if (parent in POINT_TAGS && ptDesc == null) ptDesc = value
                "trkpt", "rtept", "wpt" -> finishPoint(name)
                "trkseg" -> { segment?.let { if (it.isNotEmpty()) trkSegments?.add(it) }; segment = null }
                "trk" -> { trkSegments?.let { tracks.add(GpxTrack(trkName, it)) }; trkSegments = null }
                "rte" -> { rtePoints?.let { routes.add(GpxRoute(rteName, it)) }; rtePoints = null }
            }
            if (path.isNotEmpty()) path.removeAt(path.size - 1)
            text.setLength(0)
        }

        private fun finishPoint(tag: String) {
            if (ptLat.isNaN() || ptLon.isNaN() || ptLat !in -90.0..90.0 || ptLon !in -180.0..180.0) return
            if (++pointCount > MAX_POINTS) throw GpxParseException("GPX has more than $MAX_POINTS points")
            when (tag) {
                "trkpt" -> (segment ?: ArrayList<TrackPoint>().also { segment = it })
                    .add(TrackPoint(ptLat, ptLon, ptEle, ptTime))
                "rtept" -> {
                    rtePoints?.add(TrackPoint(ptLat, ptLon, ptEle, ptTime))
                    val n = ptName
                    if (!n.isNullOrBlank()) waypoints.add(Waypoint(ptLat, ptLon, n, ptEle, ptDesc))
                }
                "wpt" -> waypoints.add(Waypoint(ptLat, ptLon, ptName?.ifBlank { null } ?: "Waypoint", ptEle, ptDesc))
            }
        }

        companion object {
            val POINT_TAGS = setOf("trkpt", "rtept", "wpt")
        }
    }
}
