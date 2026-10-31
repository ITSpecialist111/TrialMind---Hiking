import XCTest
@testable import TrailMind

/// Not a Kotlin test: inputs where Swift's own string handling differs from Kotlin's, with the answers the Kotlin core
/// gives on the JVM, so the port keeps matching Android there too.
final class CoreGeoParityTests: XCTestCase {
    func testRedirectLinksAreReadAsJavaNetUriReadsThem() {
        let expected: [(String, Bool)] = [
            ("trailmind://localhost:/strava", true),
            ("trailmind://user@localhost:8080/strava", true),
            ("trailmind://localhost:2147483647/strava", true),
            ("trailmind://localhost:2147483648/strava", false),
            ("trailmind://localhost/str%61va", true),
            ("trailmind://local%68ost/strava", false),
            ("trailmind://\u{FC}@localhost/strava", true),
            ("trailmind://localhost/strava?a=\u{E9}", true),
            ("trailmind://localhost/strava?x= y", false),
            ("trailmind://localhost/strava?x=%zz", false),
            ("trailmind://localhost/strava?q=%2", false),
            ("trailmind://localhost./strava", false),
            ("trailmind:strava", false),
            ("trailmind:///strava", false),
            ("trailmind://[::1]/strava", false),
            ("trailmind://localhost/strava#frag ment", false),
            ("trailmind://localhost/strava?q=[x]", true),
            ("trailmind://localhost/strava?q=\u{A0}", false),
            ("trailmind://localhost/strava?q=\u{2028}", false),
            ("trailmind://localhost/strava?q=\u{99}", false),
            ("trailmind://localhost/strava\\x", false),
            ("trailmind://localhost/stravaX", true),
            ("trailmind://localhost/Strava", false),
        ]
        for (url, isRedirect) in expected { XCTAssertEqual(isRedirect, StravaOAuth.isRedirect(url), url) }
    }

    func testRedirectQueriesAreDecodedAsUrlDecoderDecodesThem() {
        let base = "trailmind://localhost/strava?state=a1b2c3d4&"
        let expected: [(String, StravaOAuth.Redirect)] = [
            ("code=c+d&scope=read+activity:write", .granted(.init(code: "c d", scopes: ["read", "activity:write"]))),
            ("code=x#state=zz", .granted(.init(code: "x", scopes: []))),
            ("code=c&code=d", .granted(.init(code: "d", scopes: []))),
            ("code=%C3%A9&scope=,,read,,", .granted(.init(code: "\u{E9}", scopes: ["read"]))),
            ("error=%20&code=c", .granted(.init(code: "c", scopes: []))),
            ("error=%C2%85&code=c", .refused(reason: "Strava said: \u{85}.")),
        ]
        for (query, redirect) in expected { XCTAssertEqual(redirect, StravaOAuth.parseRedirect(base + query, "a1b2c3d4"), query) }
    }

    func testPlaceQueriesFollowKotlinCaseAndWhitespace() {
        XCTAssertTrue(PlaceQuery.looksLikeGrid("\u{17F}e90"))
        XCTAssertTrue(PlaceQuery.looksLikeGrid("\u{131}o 123"))
        XCTAssertFalse(PlaceQuery.looksLikeGrid("S\u{212A} 12"))
        XCTAssertFalse(PlaceQuery.looksLikeGrid("SO 12\u{85}"))
        XCTAssertTrue(PlaceQuery.looksLikeGrid("\u{1C}SO 12\u{1F}"))
        XCTAssertEqual(LatLon(-51.5, 2.1), PlaceQuery.coordinates("51.5\u{17F} 2.1"))
        XCTAssertNil(PlaceQuery.coordinates("51.5\u{212A} 2.1"))
        XCTAssertNil(PlaceQuery.coordinates("51.5 2.1\u{85}"))
        XCTAssertEqual(LatLon(51.5, 2.1), PlaceQuery.coordinates("\u{1C}51.5 2.1\u{1F}"))
        XCTAssertEqual(LatLon(51.5, 2.1), PlaceQuery.coordinates("51.5 2.1\u{2028}"))
    }

    func testThreeWordAddressesAreTrimmedAndLowerCasedAsInKotlin() {
        XCTAssertEqual("\u{3BF}\u{3B4}\u{3BF}\u{3C3}.\u{3BF}\u{3B4}\u{3BF}\u{3C3}.\u{3BF}\u{3B4}\u{3BF}\u{3C2}",
                       ThreeWordAddress.normalize("///\u{39F}\u{394}\u{39F}\u{3A3}.\u{39F}\u{394}\u{39F}\u{3A3}.\u{39F}\u{394}\u{39F}\u{3A3}"))
        XCTAssertEqual("\u{3B1}\u{3C3}-\u{3B1}\u{3C3}.\u{3B1}\u{3C3}.\u{3B1}\u{3C2}",
                       ThreeWordAddress.normalize("\u{391}\u{3A3}-\u{391}\u{3A3}.\u{391}\u{3A3}.\u{391}\u{3A3}"))
        XCTAssertEqual("strasse.\u{DF}.x", ThreeWordAddress.normalize("STRASSE.\u{1E9E}.x"))
        XCTAssertNil(ThreeWordAddress.normalize("\u{130}stanbul.word.word"))
        XCTAssertNil(ThreeWordAddress.normalize("\u{85}filled.count.soap"))
        XCTAssertEqual("filled.count.soap", ThreeWordAddress.normalize("\u{1C}filled.count.soap\u{1F}"))
    }

    func testStravaNamesUseKotlinBlankness() {
        XCTAssertEqual("\u{85}", StravaPolicy.activityName("\u{85}"))
        XCTAssertEqual("Hike", StravaPolicy.activityName("\u{1C}\u{2028}"))
        XCTAssertEqual("x", StravaPolicy.activityName("\u{A0}x\u{A0}"))
        XCTAssertEqual("@\u{85}", StravaAthlete(id: 1, username: "\u{85}", firstName: nil, lastName: nil).handle)
        XCTAssertNil(StravaAthlete(id: 1, username: "\u{1C}\u{2028}", firstName: nil, lastName: nil).handle)
    }
}
