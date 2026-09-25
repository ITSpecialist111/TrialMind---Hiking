package com.trailmind.core

import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import com.trailmind.core.gpx.GpxParseException
import com.trailmind.core.gpx.GpxParser
import com.trailmind.core.gpx.GpxWriter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class GpxTest {
    private val sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Helvellyn via Striding Edge</name></metadata>
          <wpt lat="54.5271" lon="-3.0164"><ele>950</ele><name>Summit</name></wpt>
          <trk><name>Track A</name><trkseg>
            <trkpt lat="54.5400" lon="-2.9700"><ele>150.0</ele><time>2025-05-01T09:00:00Z</time></trkpt>
            <trkpt lat="54.5410" lon="-2.9720"><ele>160.5</ele><time>2025-05-01T09:02:00Z</time></trkpt>
          </trkseg><trkseg>
            <trkpt lat="54.5420" lon="-2.9740"><ele>175</ele><time>2025-05-01T09:04:00+01:00</time></trkpt>
          </trkseg></trk>
        </gpx>
    """.trimIndent()

    @Test
    fun parsesTracksWaypointsAndMetadata() {
        val doc = GpxParser.parse(sample)
        assertEquals("Helvellyn via Striding Edge", doc.bestName())
        assertEquals(1, doc.waypoints.size)
        assertEquals("Summit", doc.waypoints[0].name)
        assertEquals(950.0, doc.waypoints[0].ele)
        assertEquals(2, doc.tracks[0].segments.size)
        val line = doc.primaryLine()
        assertEquals(3, line.size)
        assertEquals(160.5, line[1].ele)
        assertEquals(1746090000000L, line[0].timeMs)
        assertEquals(1746090000000L + 4 * 60_000 - 3_600_000, line[2].timeMs)
    }

    @Test
    fun prefersPlannedRouteOverTrack() {
        val gpx = """<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
            <rte><name>Plan</name>
              <rtept lat="1" lon="1"><name>Start</name></rtept>
              <rtept lat="1.001" lon="1.001"/>
            </rte>
            <trk><trkseg><trkpt lat="2" lon="2"/><trkpt lat="2.1" lon="2.1"/><trkpt lat="2.2" lon="2.2"/></trkseg></trk>
        </gpx>"""
        val doc = GpxParser.parse(gpx)
        assertEquals(2, doc.primaryLine().size)
        assertEquals(1.0, doc.primaryLine()[0].lat)
        assertEquals(listOf("Start"), doc.waypoints.map { it.name })
    }

    @Test
    fun gpx10WithoutNamespaceAndPrefixedElements() {
        val gpx = """<g:gpx version="1.0" xmlns:g="http://www.topografix.com/GPX/1/0"><g:name>Old</g:name>
            <g:trk><g:trkseg><g:trkpt lat="3" lon="4"><g:ele>5</g:ele></g:trkpt></g:trkseg></g:trk></g:gpx>"""
        val doc = GpxParser.parse(gpx)
        assertEquals("Old", doc.bestName())
        assertEquals(5.0, doc.primaryLine().single().ele)
    }

    @Test
    fun rejectsNonGpxAndDoctype() {
        assertFailsWith<GpxParseException> { GpxParser.parse("<kml></kml>") }
        assertFailsWith<GpxParseException> { GpxParser.parse("not xml at all") }
        val xxe = """<?xml version="1.0"?><!DOCTYPE gpx [<!ENTITY x SYSTEM "file:///etc/passwd">]>
            <gpx><wpt lat="1" lon="1"><name>&x;</name></wpt></gpx>"""
        val result = runCatching { GpxParser.parse(xxe) }
        // Either rejected outright, or parsed without resolving the external entity.
        result.onSuccess { doc -> assertTrue(doc.waypoints.none { it.name.contains("root:") }) }
    }

    @Test
    fun skipsInvalidCoordinates() {
        val doc = GpxParser.parse("""<gpx><trk><trkseg><trkpt lat="95" lon="1"/><trkpt lat="x" lon="1"/><trkpt lat="1" lon="1"/></trkseg></trk></gpx>""")
        assertEquals(1, doc.primaryLine().size)
    }

    @Test
    fun writerRoundTripsAndEscapes() {
        val pts = listOf(
            TrackPoint(54.1234567, -3.7654321, 123.4, 1_700_000_000_000),
            TrackPoint(54.2, -3.8, null, 1_700_000_060_000),
        )
        val xml = GpxWriter.trackToString("Tom & Jerry's <walk>", listOf(pts), listOf(Waypoint(54.0, -3.0, "Café \"stop\"")))
        assertTrue(xml.contains("Tom &amp; Jerry&apos;s &lt;walk&gt;"))
        assertTrue(xml.contains("<time>2023-11-14T22:13:20Z</time>"))
        val doc = GpxParser.parse(xml)
        assertEquals("Tom & Jerry's <walk>", doc.bestName())
        assertEquals(2, doc.primaryLine().size)
        assertEquals(54.1234567, doc.primaryLine()[0].lat, 1e-9)
        assertEquals(123.4, doc.primaryLine()[0].ele!!, 1e-9)
        assertEquals(1_700_000_060_000, doc.primaryLine()[1].timeMs)
        assertEquals("Café \"stop\"", doc.waypoints.single().name)
    }

    @Test
    fun routeWriterRoundTrip() {
        val sw = java.io.StringWriter()
        GpxWriter.writeRoute(sw, "R", listOf(TrackPoint(1.0, 2.0, 3.0), TrackPoint(1.1, 2.1)))
        val doc = GpxParser.parse(sw.toString())
        assertEquals(2, doc.routes.single().points.size)
    }
}
