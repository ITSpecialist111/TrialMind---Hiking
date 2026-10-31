import XCTest
@testable import TrailMind

/// Swift-only checks that GpxParser/GpxWriter behave as the Kotlin ones (JVM SAX and java.time) do, where Foundation's
/// XMLParser and Swift's number parsing would otherwise differ. Expected values come from running the Kotlin code.
final class GpxParityTests: XCTestCase {
    func testRejectsMalformedXmlAsTheJvmParserDoes() {
        // FoundationXML on Linux parses in libxml2's recovery mode and would accept all of these.
        for text in ["<gpx>", "<gpx><trk></gpx>", "<g:gpx/>", "<gpx/><gpx/>", "<gpx>&undefined;</gpx>",
                     "<gpx><wpt lat=\"1\" lon=\"1\"><name>a</name></wpt></gpx>trailing", "<gpx><wpt lat=1 lon=\"1\"/></gpx>"] {
            XCTAssertThrowsError(try GpxParser.parse(text), text)
        }
        // libxml2 only warns about these, and Java accepts them.
        for text in ["<?xml version=\"1.1\"?><gpx><wpt lat=\"1\" lon=\"1\"/></gpx>",
                     "<gpx xmlns=\"GPX\" xml:lang=\"bad value!\"><wpt lat=\"1\" lon=\"1\"/></gpx>"] {
            XCTAssertEqual((try? GpxParser.parse(text))?.waypoints.count, 1, text)
        }
    }

    func testRefusesDoctypesButNotACommentedOne() {
        XCTAssertThrowsError(try GpxParser.parse("<?xml version=\"1.0\"?>\n<!-- c --><!DOCTYPE gpx [<!ENTITY a \"b\">]><gpx/>"))
        var utf16 = Data([0xFF, 0xFE])
        for unit in "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE gpx><gpx/>".utf16 {
            utf16.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
        }
        XCTAssertThrowsError(try GpxParser.parse(utf16))
        XCTAssertEqual((try? GpxParser.parse("<?xml version=\"1.0\"?><!-- <!DOCTYPE x> --><gpx><wpt lat=\"1\" lon=\"1\"/></gpx>"))?.waypoints.count, 1)
    }

    func testFilesOverTenMegabytesParse() throws {
        // libxml2 stops on more than 10 MB pushed at once, so the parser must feed it in chunks.
        let padding = "<!--" + String(repeating: "x", count: 1000) + "-->"
        var text = "<gpx><trk><trkseg>"
        for i in 0..<11_000 { text += "<trkpt lat=\"\(50.0 + Double(i) * 1e-5)\" lon=\"-2\"/>" + padding }
        text += "</trkseg></trk></gpx>"
        XCTAssertGreaterThan(text.utf8.count, 11_000_000)
        XCTAssertEqual(try GpxParser.parse(text).primaryLine().count, 11_000)
    }

    func testNumbersReadAsKotlinToDoubleOrNull() throws {
        let values = ["1e3", "0x1p3", "inf", "Infinity", "+5", "5.", ".5", "1,5", "-0", "nan", "  42  ", "12.5f", "-.5e1"]
        let points = values.enumerated().map { i, v in "<trkpt lat=\"1\" lon=\"\(Double(i) / 1000)\"><ele>\(v)</ele></trkpt>" }
        let line = try GpxParser.parse("<gpx><trk><trkseg>" + points.joined() + "</trkseg></trk></gpx>").primaryLine()
        let expected: [Double?] = [1000.0, 8.0, nil, .infinity, 5.0, 5.0, 0.5, nil, -0.0, nil, 42.0, 12.5, -5.0]
        XCTAssertEqual(line.map { $0.ele }, expected)
        let coords = try GpxParser.parse("<gpx><wpt lat=\"0x1p-2\" lon=\"1.011d\"/><wpt lat=\"1\" lon=\"180.0000001\"/></gpx>").waypoints
        XCTAssertEqual(coords.map { $0.latLon() }, [LatLon(0.25, 1.011)])
    }

    func testTimesReadAsJavaTimeDoes() {
        let expected: [(String, Int64?)] = [
            ("2025-05-01T09:00Z", 1746090000000), ("2025-05-01T09:00:00.123456789Z", 1746090000123),
            ("2025-05-01t09:00:00z", 1746090000000), ("2025-02-30T00:00:00Z", nil), ("2024-02-29T12:00:00Z", 1709208000000),
            ("2025-05-01T09:00:00", 1746090000000), ("2025-05-01T09:00:00+0100", nil), ("2025-05-01T09:00:00-05:30", 1746109800000),
            ("2025-05-01T09:00:00+01:00:30", 1746086370000), ("2025-05-01 09:00:00Z", nil), ("2025-05-01T24:00:00Z", 1746144000000),
            ("2025-05-01T23:59:60Z", 1746143999000), ("2025-05-01T09:00:00.Z", 1746090000000), ("  2025-05-01T09:00:00Z  ", 1746090000000),
            ("1969-12-31T23:59:59.999Z", -1), ("2025-05-01T09:00:00.1234567891Z", nil), ("2025-05-01T09:00:60Z", nil),
            ("2025-05-01T09:00:00+19:00", nil), ("2025-05-01T09:00+01:00", 1746086400000), ("2025-05-01T09:00:00GMT", nil),
        ]
        for (text, ms) in expected { XCTAssertEqual(GpxParser.parseTime(text), ms, text) }
    }

    func testInstantsWrittenAsJavaTimeDoes() {
        let expected: [(Int64, String)] = [
            (0, "1970-01-01T00:00:00Z"), (-1, "1969-12-31T23:59:59.999Z"), (-1500, "1969-12-31T23:59:58.500Z"),
            (951_782_400_000, "2000-02-29T00:00:00Z"), (-62_135_596_800_000, "0001-01-01T00:00:00Z"),
            (253_402_300_799_999, "9999-12-31T23:59:59.999Z"), (4_102_444_800_001, "2100-01-01T00:00:00.001Z"),
            (253_402_300_800_000, "+10000-01-01T00:00:00Z"),
        ]
        for (ms, text) in expected { XCTAssertEqual(CivilDate.isoInstant(ms), text) }
        XCTAssertEqual(CivilDate.epochDay(1600, 3, 1), -135080)
        XCTAssertEqual(CivilDate.epochDay(2026, 10, 25), 20751)
    }
}
