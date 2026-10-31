import XCTest
@testable import TrailMind

/// Port of core/src/test/kotlin/com/trailmind/core/SosTextTest.kt. Lengths are UTF-16 units, as Kotlin's `length`.
final class SosTextTests: XCTestCase {
    private let parkend = LatLon(51.7785, -2.5360)

    func testContactTextFitsOneSmsWithGridLinkHeightAndBattery() {
        let text = SosText.contact("Possible fall, no response", location: parkend, altitudeM: 170, time: "14:32", batteryPercent: 62)
        XCTAssertTrue(text.utf16.count <= SosText.maxChars, text)
        XCTAssertTrue(SosText.isGsm7(text), text)
        XCTAssertTrue(text.hasPrefix("SOS from TrailMind: Possible fall, no response at 14:32."), text)
        XCTAssertTrue(text.contains("Grid SO "), text)
        XCTAssertTrue(text.contains("openstreetmap.org/?mlat=51.77850&mlon=-2.53600"), text)
        XCTAssertTrue(text.hasSuffix(" 170 m. Battery 62%."), text)
    }

    func testLongOrForeignTextStillFitsOneGsmSms() {
        let text = SosText.contact(
            String(repeating: "Fell on the scree – ankle hurts, 3°C and windy ", count: 4),
            location: parkend, altitudeM: 850, time: "2:32\u{202F}PM", batteryPercent: 7
        )
        XCTAssertTrue(text.utf16.count <= SosText.maxChars, text)
        XCTAssertTrue(SosText.isGsm7(text), text)
        XCTAssertTrue(text.contains("51.77850,-2.53600") || text.contains("mlat=51.77850"), text)
    }

    func testNoFixSaysSoAndSkipsUnknownBattery() {
        let text = SosText.contact("I need help", location: nil, altitudeM: nil, time: "09:05", batteryPercent: -1)
        XCTAssertEqual("SOS from TrailMind: I need help at 09:05. No GPS fix.", text)
    }

    func testEmergencyTextNamesServiceThenWhatAndWhere() {
        let text = SosText.emergency("Hiker fallen, injured", location: parkend, time: "14:32")
        XCTAssertTrue(text.hasPrefix("Police, mountain rescue. Hiker fallen, injured. Grid SO "), text)
        XCTAssertTrue(text.contains("lat 51.77850 lon -2.53600"), text)
        XCTAssertTrue(SosText.isGsm7(text), text)
    }

    func testEmergencyServiceNumbersAreRecognisedButContactsAreNot() {
        for number in ["999", " 9 9 9 ", "112", "+44 999", "0999", "911", "\u{FF19}\u{FF19}\u{FF19}", "\u{0669}\u{0669}\u{0669}"] {
            XCTAssertTrue(SosText.isEmergencyNumber(number), number)
        }
        for number in ["07700 900999", "+44 7700 900112", "5554", "01594 999111", ""] {
            XCTAssertFalse(SosText.isEmergencyNumber(number), number)
        }
    }
}
