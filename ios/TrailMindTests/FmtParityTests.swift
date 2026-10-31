import XCTest
@testable import TrailMind

/// `fmt` must print what Java's String.format(Locale.ROOT, ...) prints on Android.
final class FmtParityTests: XCTestCase {
    func testHalfUpOnShortestDecimalLikeJava() {
        XCTAssertEqual(fmt("%.1f", 123.25), "123.3")
        XCTAssertEqual(fmt("%.2f", 1.005), "1.01")
        XCTAssertEqual(fmt("%.5f", 51.778505), "51.77851")
        XCTAssertEqual(fmt("%.0f", 0.5), "1")
        XCTAssertEqual(fmt("%.0f", 2.5), "3")
        XCTAssertEqual(fmt("%.1f", -0.05), "-0.1")
        XCTAssertEqual(fmt("%.1f", 0.04), "0.0")
        XCTAssertEqual(fmt("%.1f", 99.95), "100.0")
        XCTAssertEqual(fmt("%.3f", 1e-7), "0.000")
        XCTAssertEqual(fmt("%.2f", 1.5e20), "150000000000000000000.00")
    }

    func testOtherConversionsAndText() {
        XCTAssertEqual(fmt("%.2f km", 12.344), "12.34 km")
        XCTAssertEqual(fmt("%d m", 42), "42 m")
        XCTAssertEqual(fmt("%02d:%02d", 7, 5), "07:05")
        XCTAssertEqual(fmt("%02x", 255), "ff")
        XCTAssertEqual(fmt("100%%"), "100%")
        XCTAssertEqual(fmt("%5.1f|%-5.1f|%05.1f", 1.25, 1.25, -1.25), "  1.3|1.3  |-01.3")
        XCTAssertEqual(fmt("%f", 1.5), "1.500000")
    }
}
