import XCTest
@testable import TrailMind

final class GpxTests: XCTestCase {
    private let sample = """
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
        """

    func testParsesTracksWaypointsAndMetadata() throws {
        let doc = try GpxParser.parse(sample)
        XCTAssertEqual(doc.bestName(), "Helvellyn via Striding Edge")
        XCTAssertEqual(doc.waypoints.count, 1)
        XCTAssertEqual(doc.waypoints[0].name, "Summit")
        XCTAssertEqual(doc.waypoints[0].ele, 950.0)
        XCTAssertEqual(doc.tracks[0].segments.count, 2)
        let line = doc.primaryLine()
        XCTAssertEqual(line.count, 3)
        XCTAssertEqual(line[1].ele, 160.5)
        XCTAssertEqual(line[0].timeMs, 1746090000000)
        XCTAssertEqual(line[2].timeMs, 1746090000000 + 4 * 60_000 - 3_600_000)
    }

    func testPrefersPlannedRouteOverTrack() throws {
        let gpx = """
            <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
                <rte><name>Plan</name>
                  <rtept lat="1" lon="1"><name>Start</name></rtept>
                  <rtept lat="1.001" lon="1.001"/>
                </rte>
                <trk><trkseg><trkpt lat="2" lon="2"/><trkpt lat="2.1" lon="2.1"/><trkpt lat="2.2" lon="2.2"/></trkseg></trk>
            </gpx>
            """
        let doc = try GpxParser.parse(gpx)
        XCTAssertEqual(doc.primaryLine().count, 2)
        XCTAssertEqual(doc.primaryLine()[0].lat, 1.0)
        XCTAssertEqual(doc.waypoints.map { $0.name }, ["Start"])
    }

    func testGpx10WithoutNamespaceAndPrefixedElements() throws {
        let gpx = """
            <g:gpx version="1.0" xmlns:g="http://www.topografix.com/GPX/1/0"><g:name>Old</g:name>
                <g:trk><g:trkseg><g:trkpt lat="3" lon="4"><g:ele>5</g:ele></g:trkpt></g:trkseg></g:trk></g:gpx>
            """
        let doc = try GpxParser.parse(gpx)
        XCTAssertEqual(doc.bestName(), "Old")
        let line = doc.primaryLine()
        XCTAssertEqual(line.count, 1)
        XCTAssertEqual(line.first?.ele, 5.0)
    }

    func testRejectsNonGpxAndDoctype() {
        XCTAssertThrowsError(try GpxParser.parse("<kml></kml>")) { XCTAssertTrue($0 is GpxParseError, "\($0)") }
        XCTAssertThrowsError(try GpxParser.parse("not xml at all")) { XCTAssertTrue($0 is GpxParseError, "\($0)") }
        let xxe = """
            <?xml version="1.0"?><!DOCTYPE gpx [<!ENTITY x SYSTEM "file:///etc/passwd">]>
                <gpx><wpt lat="1" lon="1"><name>&x;</name></wpt></gpx>
            """
        // Either rejected outright, or parsed without resolving the external entity.
        if let doc = try? GpxParser.parse(xxe) {
            XCTAssertTrue(doc.waypoints.allSatisfy { !$0.name.contains("root:") })
        }
    }

    func testSkipsInvalidCoordinates() throws {
        let doc = try GpxParser.parse(#"<gpx><trk><trkseg><trkpt lat="95" lon="1"/><trkpt lat="x" lon="1"/><trkpt lat="1" lon="1"/></trkseg></trk></gpx>"#)
        XCTAssertEqual(doc.primaryLine().count, 1)
    }

    func testWriterRoundTripsAndEscapes() throws {
        let pts = [
            TrackPoint(lat: 54.1234567, lon: -3.7654321, ele: 123.4, timeMs: 1_700_000_000_000),
            TrackPoint(lat: 54.2, lon: -3.8, ele: nil, timeMs: 1_700_000_060_000),
        ]
        let xml = GpxWriter.trackToString("Tom & Jerry's <walk>", [pts], [Waypoint(lat: 54.0, lon: -3.0, name: "Café \"stop\"")])
        XCTAssertTrue(xml.contains("Tom &amp; Jerry&apos;s &lt;walk&gt;"))
        XCTAssertTrue(xml.contains("<time>2023-11-14T22:13:20Z</time>"))
        let doc = try GpxParser.parse(xml)
        XCTAssertEqual(doc.bestName(), "Tom & Jerry's <walk>")
        XCTAssertEqual(doc.primaryLine().count, 2)
        XCTAssertEqual(doc.primaryLine()[0].lat, 54.1234567, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(doc.primaryLine()[0].ele), 123.4, accuracy: 1e-9)
        XCTAssertEqual(doc.primaryLine()[1].timeMs, 1_700_000_060_000)
        XCTAssertEqual(doc.waypoints.count, 1)
        XCTAssertEqual(doc.waypoints.first?.name, "Café \"stop\"")
    }

    func testRouteWriterRoundTrip() throws {
        var sw = ""
        GpxWriter.writeRoute(&sw, "R", [TrackPoint(lat: 1.0, lon: 2.0, ele: 3.0), TrackPoint(lat: 1.1, lon: 2.1)])
        let doc = try GpxParser.parse(sw)
        XCTAssertEqual(doc.routes.count, 1)
        XCTAssertEqual(doc.routes.first?.points.count, 2)
    }
}
