import XCTest
@testable import TrailMind

/// what3words look-ups from Search: the request and the checks on the answer (data/What3words.kt).
final class ThreeWordsSearchTests: XCTestCase {
    private let body = """
        {"country":"GB","square":{"southwest":{"lng":-0.195543,"lat":51.520833},"northeast":{"lng":-0.195499,"lat":51.52086}},
        "nearestPlace":"Bayswater, London","coordinates":{"lng":-0.195521,"lat":51.520847},"words":"filled.count.soap",
        "language":"en","map":"https://w3w.co/filled.count.soap"}
        """

    private func message(_ block: () throws -> Any) -> String? {
        do {
            _ = try block()
            return nil
        } catch {
            return (error as? ThreeWordsSearch.Failure)?.message
        }
    }

    func testBuildsTheRequestFromNormalisedWords() throws {
        let request = try ThreeWordsSearch.requestURL("  ///Filled.Count.Soap ")
        XCTAssertEqual(request.words, "filled.count.soap")
        XCTAssertEqual(request.url, "https://api.what3words.com/v3/convert-to-coordinates?words=filled.count.soap")
        XCTAssertEqual(message { try ThreeWordsSearch.requestURL("filled count soap") }, ThreeWordsSearch.badInput)
        XCTAssertEqual(message { try ThreeWordsSearch.requestURL("///two.words") }, ThreeWordsSearch.badInput)
    }

    func testReadsAConversion() throws {
        let address = try ThreeWordsSearch.parse(body, requested: "filled.count.soap")
        XCTAssertEqual(address.words, "filled.count.soap")
        XCTAssertEqual(address.position, LatLon(51.520847, -0.195521))
        XCTAssertEqual(address.nearby, "Bayswater, London")
        XCTAssertTrue(address.contains(address.position))
        XCTAssertFalse(address.contains(LatLon(51.52086, -0.195521)))
        let place = ThreeWordsSearch.place(address)
        XCTAssertEqual(place.name, "///filled.count.soap")
        XCTAssertEqual(place.type, "what3words")
        XCTAssertEqual(place.area, "Bayswater, London")
        XCTAssertEqual(place.zoom, 18.0)
        XCTAssertEqual(place.grid, OsGrid.fromWgs84(address.position)?.format(10))
        XCTAssertTrue(place.grid?.hasPrefix("TQ ") == true)
    }

    func testRefusesAnswersThatDoNotFit() {
        XCTAssertEqual(message { try ThreeWordsSearch.parse(self.body, requested: "index.home.raft") }, ThreeWordsSearch.mismatch)
        XCTAssertEqual(message { try ThreeWordsSearch.parse(#"{"error":{"code":"BadWords","message":"Invalid"}}"#) },
                       "what3words: conversion failed. Check the address and your API plan.")
        XCTAssertEqual(message { try ThreeWordsSearch.parse(self.body.replacingOccurrences(of: #""lat":51.520847"#, with: #""lat":95.0"#)) },
                       "what3words: invalid coordinates in response.")
        XCTAssertEqual(message { try ThreeWordsSearch.parse(self.body.replacingOccurrences(of: #""lng":-0.195521"#, with: #""lng":-0.1"#)) },
                       "what3words: invalid square in response.")
        XCTAssertEqual(message { try ThreeWordsSearch.parse(self.body.replacingOccurrences(of: #""words":"filled.count.soap""#, with: #""words":"two.words""#)) },
                       "what3words: invalid address in response.")
        XCTAssertEqual(message { try ThreeWordsSearch.parse("Bad gateway") }, "what3words: unreadable service response.")
        XCTAssertEqual(message { try ThreeWordsSearch.parse(#"{"words":"filled.count.soap","coordinates":{"lat":51.5,"lng":-0.19}}"#) },
                       "what3words: unreadable service response.")
    }

    func testExplainsRefusals() {
        XCTAssertEqual(ThreeWordsSearch.httpError(404),
                       "what3words: address not found. Check all three words; spelling changes can point to a different country.")
        XCTAssertEqual(ThreeWordsSearch.httpError(402), "what3words: check your API key, plan and conversion permissions in Settings.")
        XCTAssertEqual(ThreeWordsSearch.httpError(429), "what3words: request limit reached. Try again later.")
        XCTAssertEqual(ThreeWordsSearch.httpError(503),
                       "what3words: service returned HTTP 503. Use coordinates or a grid reference instead.")
    }
}
