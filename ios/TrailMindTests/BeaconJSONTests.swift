import XCTest
@testable import TrailMind

final class BeaconJSONTests: XCTestCase {
    private func object(_ s: String) throws -> [String: Any] { try BeaconJSON.object(Data(s.utf8)) }

    func testNumbersAreReadLikeOrgJson() throws {
        let o = try object(#"{"int":1761900000,"big":1761900000123,"frac":1.9,"neg":-1.9,"text":" 42.7 ","word":"abc","yes":true,"none":null}"#)
        XCTAssertEqual(1_761_900_000, BeaconJSON.optLong(o, "int"))
        XCTAssertEqual(1_761_900_000_123, BeaconJSON.optLong(o, "big"))
        XCTAssertEqual(1, BeaconJSON.optLong(o, "frac"))
        XCTAssertEqual(-1, BeaconJSON.optLong(o, "neg"))
        XCTAssertEqual(42, BeaconJSON.optLong(o, "text"))
        XCTAssertEqual(7, BeaconJSON.optLong(o, "word", 7))
        XCTAssertEqual(7, BeaconJSON.optLong(o, "yes", 7))
        XCTAssertEqual(7, BeaconJSON.optLong(o, "none", 7))
        XCTAssertEqual(7, BeaconJSON.optLong(o, "missing", 7))
        XCTAssertEqual(42.7, BeaconJSON.double(o["text"]))
        XCTAssertEqual(1.9, BeaconJSON.double(o["frac"]))
        XCTAssertNil(BeaconJSON.double(o["yes"]))
        XCTAssertThrowsError(try BeaconJSON.getLong(o, "none"))
        XCTAssertThrowsError(try BeaconJSON.getLong(o, "word"))
    }

    func testTextIsReadLikeOrgJson() throws {
        let o = try object(#"{"s":"Graham","n":123,"f":1.5,"null":null,"t":true,"blank":""}"#)
        XCTAssertEqual("Graham", BeaconJSON.optString(o, "s"))
        XCTAssertEqual("123", BeaconJSON.optString(o, "n"))
        XCTAssertEqual("1.5", BeaconJSON.optString(o, "f"))
        XCTAssertEqual("true", BeaconJSON.optString(o, "t"))
        // org.json reads an explicit null as the text "null"; callers check isNull first where it matters.
        XCTAssertEqual("null", BeaconJSON.optString(o, "null"))
        XCTAssertEqual("", BeaconJSON.optString(o, "missing"))
        XCTAssertTrue(BeaconJSON.isNull(o["null"]))
        XCTAssertTrue(BeaconJSON.isNull(o["missing"]))
        XCTAssertFalse(BeaconJSON.isNull(o["blank"]))
        XCTAssertThrowsError(try BeaconJSON.getString(o, "null"))
        XCTAssertEqual("123", try BeaconJSON.getString(o, "n"))
    }

    func testBooleansAreReadLikeOrgJson() throws {
        let o = try object(#"{"t":true,"f":false,"text":"TRUE","one":1}"#)
        XCTAssertTrue(BeaconJSON.optBoolean(o, "t"))
        XCTAssertFalse(BeaconJSON.optBoolean(o, "f", true))
        XCTAssertTrue(BeaconJSON.optBoolean(o, "text"))
        XCTAssertFalse(BeaconJSON.optBoolean(o, "one"))
        XCTAssertTrue(BeaconJSON.optBoolean(o, "missing", true))
    }

    func testOnlyAnObjectIsAnObject() {
        XCTAssertNil(BeaconJSON.optObject(Data("[1]".utf8)))
        XCTAssertNil(BeaconJSON.optObject(Data("\"text\"".utf8)))
        XCTAssertNil(BeaconJSON.optObject(Data()))
        XCTAssertNil(BeaconJSON.optObject(Data("{\"a\":".utf8)))
        XCTAssertNotNil(BeaconJSON.optObject(Data("{}".utf8)))
    }

    func testDoublesAreWrittenLikeJava() {
        XCTAssertEqual("54.46", BeaconJSON.javaDouble(54.46))
        XCTAssertEqual("-3.0", BeaconJSON.javaDouble(-3.0))
        XCTAssertEqual("100.0", BeaconJSON.javaDouble(100))
        XCTAssertEqual("0.001", BeaconJSON.javaDouble(0.001))
        XCTAssertEqual("9.99E-4", BeaconJSON.javaDouble(0.000999))
        XCTAssertEqual("5.0E-4", BeaconJSON.javaDouble(0.0005))
        XCTAssertEqual("-1.2E-5", BeaconJSON.javaDouble(-0.000012))
        XCTAssertEqual("9999999.5", BeaconJSON.javaDouble(9_999_999.5))
        XCTAssertEqual("1.0E7", BeaconJSON.javaDouble(10_000_000))
        XCTAssertEqual("1.23456789E7", BeaconJSON.javaDouble(12_345_678.9))
        XCTAssertEqual("1.0E16", BeaconJSON.javaDouble(1e16))
        XCTAssertEqual("0.1", BeaconJSON.javaDouble(0.1))
        XCTAssertEqual("0.0", BeaconJSON.javaDouble(0))
        XCTAssertEqual("-0.0", BeaconJSON.javaDouble(-0.0))
        XCTAssertEqual("NaN", BeaconJSON.javaDouble(.nan))
        XCTAssertEqual("-Infinity", BeaconJSON.javaDouble(-.infinity))
    }
}
