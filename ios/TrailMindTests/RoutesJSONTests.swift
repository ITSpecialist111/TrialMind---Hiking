import XCTest
@testable import TrailMind

final class RoutesJSONTests: XCTestCase {
    func testParsesValuesKeepingMemberOrder() throws {
        let v = try RoutesJSON.parse(#"{"b": 1, "a": [true, false, null, "x"], "c": {"d": -2.5e3}, "b": 3}"#)
        XCTAssertEqual(v.objectValue?.keys, ["b", "a", "c"])
        XCTAssertEqual(v.optLong("b"), 3)
        XCTAssertEqual(v.optJSONArray("a"), [.bool(true), .bool(false), .null, .string("x")])
        XCTAssertEqual(try v.getJSONObject("c").getDouble("d"), -2500.0)
        XCTAssertEqual(try RoutesJSON.parse("42"), .number("42"))
        XCTAssertThrowsError(try RoutesJSON.parse(#"{"a": 1} x"#))
        XCTAssertThrowsError(try RoutesJSON.parse(#"{"a": nope}"#))
    }

    func testConvertsValuesAsAndroidOrgJsonDoes() throws {
        let v = try RoutesJSON.parse(#"{"n": null, "i": 42, "d": 1.5, "s": "2.75", "t": "TRUE", "bad": "x", "big": 1e3, "neg": -7.9}"#)
        XCTAssertEqual(v.optString("missing"), "")
        XCTAssertEqual(v.optString("missing", "fallback"), "fallback")
        XCTAssertEqual(v.optString("n"), "null")
        XCTAssertEqual(v.optString("i"), "42")
        XCTAssertEqual(v.optString("d"), "1.5")
        XCTAssertEqual(v.optString("big"), "1000.0")
        XCTAssertEqual(v.optDouble("s"), 2.75)
        XCTAssertTrue(v.optDouble("bad").isNaN)
        XCTAssertTrue(v.optDouble("n").isNaN)
        XCTAssertEqual(v.optDouble("n", 0.0), 0.0)
        XCTAssertEqual(try v.getLong("d"), 1)
        XCTAssertEqual(try v.getLong("neg"), -7)
        XCTAssertEqual(try v.getLong("s"), 2)
        XCTAssertEqual(v.optLong("bad"), 0)
        XCTAssertTrue(v.optBoolean("t"))
        XCTAssertFalse(v.optBoolean("bad"))
        XCTAssertThrowsError(try v.getLong("missing")) { XCTAssertEqual(($0 as? RoutesJSON.JSONError)?.message, "No value for missing") }
        XCTAssertThrowsError(try v.getDouble("n"))
        XCTAssertNil(v.optJSONArray("i"))
        XCTAssertThrowsError(try v.getJSONObject("i"))
        let a = try XCTUnwrap(try RoutesJSON.parse(#"[1, null, "3.5", [2]]"#).arrayValue)
        XCTAssertEqual(RoutesJSON.optDouble(a, 2), 3.5)
        XCTAssertTrue(RoutesJSON.optDouble(a, 9).isNaN)
        XCTAssertTrue(RoutesJSON.isNull(a, 1))
        XCTAssertTrue(RoutesJSON.isNull(a, 9))
        XCTAssertEqual(try RoutesJSON.getJSONArray(a, 3), [.number("2")])
        XCTAssertThrowsError(try RoutesJSON.getDouble(a, 1))
    }

    func testWritesDoublesAsJavaDoes() {
        XCTAssertEqual(RoutesJSON.javaDoubleString(54.4521), "54.4521")
        XCTAssertEqual(RoutesJSON.javaDoubleString(-3.05), "-3.05")
        XCTAssertEqual(RoutesJSON.javaDoubleString(100.0), "100.0")
        XCTAssertEqual(RoutesJSON.javaDoubleString(0.001), "0.001")
        XCTAssertEqual(RoutesJSON.javaDoubleString(-0.0001), "-1.0E-4")
        XCTAssertEqual(RoutesJSON.javaDoubleString(1.0E7), "1.0E7")
        XCTAssertEqual(RoutesJSON.javaDoubleString(1234567.0), "1234567.0")
        XCTAssertEqual(RoutesJSON.javaDoubleString(1.5e20), "1.5E20")
        XCTAssertEqual(RoutesJSON.javaDoubleString(0.0), "0.0")
        XCTAssertEqual(RoutesJSON.javaDoubleString(-0.0), "-0.0")
        XCTAssertEqual(RoutesJSON.javaDoubleString(.nan), "NaN")
        XCTAssertEqual(RoutesJSON.numberText(54.0), "54")
        XCTAssertEqual(RoutesJSON.numberText(2.5), "2.5")
    }

    func testSerialisesAsOrgJsonDoes() {
        let v = RoutesJSON.Value.object(RoutesJSON.Object([
            ("url", .string("a/b \"c\"\n")), ("n", .double(3.0)), ("x", .double(0.5)), ("l", .long(-12)), ("e", .array([.null, .bool(false)])),
        ]))
        XCTAssertEqual(v.serialized(), #"{"url":"a\/b \"c\"\n","n":3,"x":0.5,"l":-12,"e":[null,false]}"#)
        XCTAssertEqual(try RoutesJSON.parse(v.serialized()), v)
    }

    func testFormEncodingMatchesURLEncoder() {
        XCTAssertEqual(RoutesJSON.formEncode("Offa's Dyke"), "Offa%27s+Dyke")
        XCTAssertEqual(RoutesJSON.formEncode("Café ~ 100%"), "Caf%C3%A9+%7E+100%25")
        XCTAssertEqual(RoutesJSON.formEncode("a*b-c_d.e"), "a*b-c_d.e")
    }

    func testReaderStopsAtTheEndOfACutReply() throws {
        var reader = RoutesJSON.Reader(Array(#"{"a": [1, 2"#.utf8), truncated: true)
        try reader.beginObject()
        var first = true
        XCTAssertTrue(try reader.hasNext(first: &first, closing: UInt8(ascii: "}")))
        XCTAssertEqual(try reader.nextName(), "a")
        try reader.beginArray()
        var firstItem = true
        XCTAssertTrue(try reader.hasNext(first: &firstItem, closing: UInt8(ascii: "]")))
        XCTAssertEqual(try reader.value(), .number("1"))
        XCTAssertTrue(try reader.hasNext(first: &firstItem, closing: UInt8(ascii: "]")))
        XCTAssertThrowsError(try reader.value()) { XCTAssertTrue($0 is RoutesJSON.EndOfInput) }
        XCTAssertThrowsError(try RoutesJSON.parse(#"{"a": "#)) { XCTAssertTrue($0 is RoutesJSON.EndOfInput) }
    }

    func testReadsEscapes() throws {
        XCTAssertEqual(try RoutesJSON.parse(#""caf\u00e9 \ud83c\udfd4 \/ \t""#), .string("café \u{1F3D4} / \t"))
        XCTAssertThrowsError(try RoutesJSON.parse(#""\x""#))
    }
}
