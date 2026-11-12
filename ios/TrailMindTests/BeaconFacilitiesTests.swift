import XCTest
@testable import TrailMind

final class BeaconFacilitiesTests: XCTestCase {
    private let file = """
        {"fetchedMs":1761900000000,"partial":true,"items":[
         {"category":"PARKING","lat":54.4521,"lon":-3.0911,"name":"Seathwaite","ele":"","openingHours":"","fee":"yes","access":"","website":"","alongM":20.0,"offM":35.5},
         {"category":"TOILETS","lat":54.46,"lon":-3.1,"name":"","ele":"","openingHours":"24/7","fee":"","access":"","website":"","alongM":120,"offM":10}]}
        """

    func testTheSavedFacilitiesAreReadForTheBriefing() throws {
        let saved = try XCTUnwrap(BeaconFacilities.parse(Data(file.utf8)))
        XCTAssertEqual(1_761_900_000_000, saved.fetchedMs)
        XCTAssertTrue(saved.partial)
        XCTAssertEqual(2, saved.items.count)
        XCTAssertEqual(Facility(category: .parking, position: LatLon(54.4521, -3.0911), name: "Seathwaite", fee: "yes", alongM: 20, offM: 35.5),
                       saved.items[0])
        XCTAssertEqual(.toilets, saved.items[1].category)
        XCTAssertEqual("24/7", saved.items[1].openingHours)
        XCTAssertEqual(120, saved.items[1].alongM)
    }

    func testPartialDefaultsToFalseAndOptionalTextToBlank() throws {
        let saved = try XCTUnwrap(BeaconFacilities.parse(Data(#"{"fetchedMs":1,"items":[{"category":"WATER","lat":1,"lon":2,"alongM":0,"offM":0}]}"#.utf8)))
        XCTAssertFalse(saved.partial)
        XCTAssertEqual("", saved.items[0].name)
        XCTAssertEqual(0, BeaconFacilities.parse(Data(#"{"fetchedMs":1,"items":[]}"#.utf8))?.items.count)
    }

    func testADamagedFileIsIgnored() {
        XCTAssertNil(BeaconFacilities.parse(Data(#"{"fetchedMs":1,"items":[{"category":"CASTLE","lat":1,"lon":2,"alongM":0,"offM":0}]}"#.utf8)))
        XCTAssertNil(BeaconFacilities.parse(Data(#"{"fetchedMs":1,"items":[{"category":"WATER","lat":1,"alongM":0,"offM":0}]}"#.utf8)))
        XCTAssertNil(BeaconFacilities.parse(Data(#"{"items":[]}"#.utf8)))
        XCTAssertNil(BeaconFacilities.parse(Data(#"{"fetchedMs":1}"#.utf8)))
        XCTAssertNil(BeaconFacilities.parse(Data(file.utf8).prefix(40)))
    }
}
