import XCTest
@testable import TrailMind

final class RouteReadinessTests: XCTestCase {
    private let sources = TileSources.builtIns()
    private var outdoor: TileSource { sources.first { $0.id == TileSources.osOutdoor }! }
    private var leisure: TileSource { sources.first { $0.id == TileSources.osLeisure }! }
    private let line = TripReadiness.sampleRoute([LatLon(54.45, -3.20), LatLon(54.46, -3.18)])

    func testCoverageCountsTilesAtEachPacksLastZoom() {
        let packs = [ReadinessPack(id: 1, maxZoom: 14), ReadinessPack(id: 2, maxZoom: 16)]
        // Pack 2 holds the first half of the line at zoom 16; pack 1 holds nothing.
        let half = Set(line.prefix(line.count / 2).map { WebMercator.tileFor($0, 16) })
        var asked: [Int64: Int] = [:]
        let result = RouteReadiness.mapCoverage(source: outdoor, points: line, packs: packs, nowMs: 0, hasTile: { pack, key in
            asked[pack.id, default: 0] += 1
            XCTAssertEqual(key.z, pack.maxZoom)
            return pack.id == 2 && half.contains(key)
        }, premiumCachedAt: { _ in 0 })
        let expected = TripReadiness.coverage(hits: line.filter { half.contains(WebMercator.tileFor($0, 16)) }.count, samples: line.count)
        XCTAssertEqual(result.coverage, expected)
        XCTAssertTrue(expected > 0 && expected < 100, "\(expected)")
        XCTAssertNil(result.untilMs)
        XCTAssertEqual(asked[1], line.count)

        let all = RouteReadiness.mapCoverage(source: outdoor, points: line, packs: packs, nowMs: 0, hasTile: { _, _ in true },
                                             premiumCachedAt: { _ in 0 })
        XCTAssertEqual(all.coverage, 100)
        XCTAssertEqual(RouteReadiness.mapCoverage(source: outdoor, points: line, packs: [], nowMs: 0, hasTile: { _, _ in true },
                                                  premiumCachedAt: { _ in 0 }).coverage, 0)
    }

    func testSignalOnlyMapsAreNotCounted() {
        for id in [TileSources.osm, TileSources.apple] {
            let source = sources.first { $0.id == id }!
            XCTAssertTrue(RouteReadiness.needsSignal(source))
            let result = RouteReadiness.mapCoverage(source: source, points: line, packs: [ReadinessPack(id: 1, maxZoom: 16)], nowMs: 0,
                                                    hasTile: { _, _ in true }, premiumCachedAt: { _ in 0 })
            XCTAssertNil(result.coverage)
        }
        XCTAssertFalse(RouteReadiness.needsSignal(outdoor))
        XCTAssertTrue(RouteReadiness.canDownload(leisure))
    }

    func testExplorerDetailMustBeFreshAndSaysWhenItExpires() throws {
        let now: Int64 = 1_700_000_000_000
        let pack = ReadinessPack(id: 7, maxZoom: 5, premiumMaxZoom: 9, premiumMs: now - 3_600_000)
        let first = try XCTUnwrap(OsGrid.fromWgs84(line[0]))
        var cachedAt: [TileKey: Int64] = [:]
        for (i, p) in line.enumerated() {
            let tile = RouteText.bngTile(OsGrid.fromWgs84(p)!, 9)
            // Detail cached two hours ago, except one stale tile (25 hours) somewhere along the line.
            cachedAt[tile] = i == line.count - 1 ? now - 25 * 3_600_000 : now - 2 * 3_600_000
        }
        let staleTile = RouteText.bngTile(OsGrid.fromWgs84(line[line.count - 1])!, 9)
        let staleCount = line.filter { RouteText.bngTile(OsGrid.fromWgs84($0)!, 9) == staleTile }.count
        var askedFirst: TileKey?
        let result = RouteReadiness.mapCoverage(source: leisure, points: line, packs: [pack], nowMs: now, hasTile: { _, key in
            if askedFirst == nil { askedFirst = key }
            return key.z == 5
        }, premiumCachedAt: { cachedAt[$0] ?? 0 })
        // Packs are looked up in the OS grid at their own last zoom.
        XCTAssertEqual(askedFirst, RouteText.bngTile(first, 5))
        XCTAssertEqual(result.coverage, TripReadiness.coverage(hits: line.count - staleCount, samples: line.count))
        // The earliest-cached tile decides, even a stale one.
        XCTAssertEqual(result.untilMs, now - 25 * 3_600_000 + RouteReadiness.premiumHoldMs)

        // Nothing cached: the pack's own pre-load time.
        let none = RouteReadiness.mapCoverage(source: leisure, points: line, packs: [pack], nowMs: now, hasTile: { _, _ in true },
                                              premiumCachedAt: { _ in 0 })
        XCTAssertEqual(none.coverage, 0)
        XCTAssertEqual(none.untilMs, pack.premiumMs + RouteReadiness.premiumHoldMs)

        // Without detail packs the overview alone counts.
        let overview = RouteReadiness.mapCoverage(source: leisure, points: line, packs: [ReadinessPack(id: 8, maxZoom: 5)], nowMs: now,
                                                  hasTile: { _, _ in true }, premiumCachedAt: { _ in 0 })
        XCTAssertEqual(overview.coverage, 100)
        XCTAssertNil(overview.untilMs)
    }
}

final class RouteLibraryTextTests: XCTestCase {
    private func doc(name: String? = nil, track: [TrackPoint] = [], route: [TrackPoint] = []) -> GpxDocument {
        GpxDocument(name: name, tracks: track.isEmpty ? [] : [GpxTrack(name: nil, segments: [track])],
                    routes: route.isEmpty ? [] : [GpxRoute(name: "Planned", points: route)],
                    waypoints: [Waypoint(lat: 54.5, lon: -3.0, name: "Summit")])
    }

    func testImportNamesTheRouteAndAsksForHeightsWhenItHasNone() throws {
        let flat = [TrackPoint(lat: 54.0, lon: -3.0), TrackPoint(lat: 54.01, lon: -3.0)]
        let high = [TrackPoint(lat: 54.0, lon: -3.0, ele: 100), TrackPoint(lat: 54.01, lon: -3.0)]
        let a = try RouteImportPlan.prepare(doc(name: "Helvellyn", track: flat), fileName: "file")
        XCTAssertEqual(a.name, "Helvellyn")
        XCTAssertEqual(a.line, flat)
        XCTAssertEqual(a.waypoints.map(\.name), ["Summit"])
        XCTAssertTrue(a.needsTerrain)
        let b = try RouteImportPlan.prepare(doc(track: high), fileName: "walk")
        XCTAssertEqual(b.name, "walk")
        XCTAssertFalse(b.needsTerrain)
        XCTAssertEqual(try RouteImportPlan.prepare(doc(route: flat), fileName: nil).name, "Planned")
        XCTAssertEqual(try RouteImportPlan.prepare(doc(track: flat), fileName: nil).name, "Imported route")
        XCTAssertEqual(try RouteImportPlan.prepare(doc(track: flat), fileName: " ").name, "Imported route")
        XCTAssertThrowsError(try RouteImportPlan.prepare(doc(track: [flat[0]]), fileName: nil)) {
            XCTAssertEqual($0.localizedDescription, "No track or route with at least two points was found in this file.")
        }
        XCTAssertEqual(RouteImportPlan.baseName("Coast to Coast.gpx"), "Coast to Coast")
        XCTAssertEqual(RouteImportPlan.baseName("a.b.gpx"), "a.b")
        XCTAssertEqual(RouteImportPlan.baseName("noext"), "noext")
    }

    func testFinderWording() {
        let trail = WaymarkedTrails.Trail(id: 1, name: "Offa's Dyke Path", ref: "ODP", group: "NAT")
        XCTAssertEqual(RouteText.finderSubtitle(trail), "National trail · ODP")
        XCTAssertEqual(RouteText.finderSubtitle(WaymarkedTrails.Trail(id: 2, name: "W1", ref: "W1", group: "LOC")), "Local walk")
        XCTAssertEqual(RouteText.finderSubtitle(WaymarkedTrails.Trail(id: 3, name: "x", ref: nil, group: "")), "Waymarked route")
        XCTAssertEqual(RouteText.finderHeading(.nearMe, searched: "", noFix: false, imperial: false), "Routes within 10.0 km of you")
        XCTAssertEqual(RouteText.finderHeading(.nearMe, searched: "", noFix: false, imperial: true), "Routes within 6.21 mi of you")
        XCTAssertEqual(RouteText.finderHeading(.nearMe, searched: "", noFix: true, imperial: false),
                       "No GPS fix yet, so these are routes around the map centre")
        XCTAssertEqual(RouteText.finderHeading(.search, searched: "Dyke", noFix: true, imperial: false), "Routes matching \"Dyke\"")
        XCTAssertEqual(RouteText.finderHeading(.mapView, searched: "", noFix: true, imperial: false), "Routes in the map view")
        XCTAssertEqual(RouteText.finderEmpty(.search, searched: "Zzz"), "No waymarked route is called \"Zzz\". Try part of the name.")
        XCTAssertEqual(RouteText.finderLoading(.mapView), "Looking for waymarked routes…")
        XCTAssertEqual(RouteText.finderAdded(hasElevation: true, lengthM: 90_000, imperial: false), "Route added")
        XCTAssertEqual(RouteText.finderAdded(hasElevation: false, lengthM: 90_000, imperial: false),
                       "Route added. Heights are only downloaded for routes up to 60.0 km.")
        XCTAssertEqual(RouteText.finderAdded(hasElevation: false, lengthM: 5_000, imperial: false), "Route added without heights")
        XCTAssertTrue(RouteText.finderNote.hasSuffix("Tap one to add it to your routes. " + WaymarkedTrails.attribution))
    }

    func testPlannerWording() {
        XCTAssertEqual(RouteText.plannerStatus(pending: true, points: 3), "Finding a path…")
        XCTAssertEqual(RouteText.plannerStatus(pending: false, points: 0), "Tap the map to add a start point.")
        XCTAssertEqual(RouteText.plannerStatus(pending: false, points: 1), "1 point")
        XCTAssertEqual(RouteText.plannerStatus(pending: false, points: 4), "4 points")
        XCTAssertEqual(RouteText.plannerNotice(offline: true, noPath: true), "Offline: this leg is a straight line")
        XCTAssertEqual(RouteText.plannerNotice(offline: false, noPath: true), "No path found here, so this leg is a straight line")
        XCTAssertEqual(RouteText.plannerNotice(offline: false, noPath: false), "Routing service unavailable, so this leg is a straight line")
    }

    func testFacilityWording() {
        let cafe = Facility(category: .cafe, position: LatLon(54, -3), name: "", ele: "", openingHours: "Mo-Su 09:00-17:00",
                            alongM: 1234, offM: 56.4)
        XCTAssertEqual(RouteText.facilityTitle(cafe), "Café")
        XCTAssertEqual(RouteText.facilityDetail(cafe, imperial: false), "Café · at 1.23 km, 56 m off route · Hours: Mo-Su 09:00-17:00")
        let peak = Facility(category: .peak, position: LatLon(54, -3), name: "Skiddaw", ele: "931", alongM: 500, offM: 3)
        XCTAssertEqual(RouteText.facilityTitle(peak), "Skiddaw")
        XCTAssertEqual(RouteText.facilityDetail(peak, imperial: false), "Peak · at 500 m, 3 m off route · 931 m high")
        var odd = peak
        odd.ele = "about 900"
        XCTAssertEqual(RouteText.facilityDetail(odd, imperial: false), "Peak · at 500 m, 3 m off route")
        let counts = RouteText.facilityCounts([peak, cafe, peak, cafe, cafe])
        XCTAssertEqual(counts.map(\.category), [.peak, .cafe])
        XCTAssertEqual(counts.map(\.count), [2, 3])
    }

    func testLidarWording() {
        let steep = LidarSection(1234, 1250, 38.6, LatLon(54, -3))
        XCTAssertEqual(RouteText.lidarSteepTitle(steep, imperial: false), "At 1.23 km · 39°")
        XCTAssertEqual(RouteText.lidarSteepDetail(steep, imperial: false), "For 16 m along the line. Tap to see it.")
        let onLine = LidarSection(400, 400, 0.4, LatLon(54, -3))
        XCTAssertEqual(RouteText.lidarCragTitle(onLine, imperial: false), "At 400 m · on the line")
        XCTAssertEqual(RouteText.lidarCragDetail(onLine, imperial: false), "For 1 m along the line. Tap to see it.")
        XCTAssertEqual(RouteText.lidarCragTitle(LidarSection(10, 20, 6.2, LatLon(54, -3)), imperial: false), "At 10 m · 6 m away")
        XCTAssertEqual(RouteText.lidarDownloadNote(squares: nil, missing: 0, online: true), "Working out the download…")
        XCTAssertEqual(RouteText.lidarDownloadNote(squares: 10, missing: 0, online: false), "The LiDAR for this route is on the phone.")
        XCTAssertEqual(RouteText.lidarDownloadNote(squares: 10, missing: 10, online: true), "Downloads about 1.5 MB and keeps it on the phone.")
        XCTAssertEqual(RouteText.lidarDownloadNote(squares: 10, missing: 7, online: false, decimalSeparator: ","),
                       "Needs normal signal to download about 1,0 MB.")
        XCTAssertEqual(RouteText.lidarProgress(done: 0, total: 0), "Starting…")
        XCTAssertEqual(RouteText.lidarProgress(done: 4, total: 9), "Downloading LiDAR: 4 of 9 squares… You can leave this page.")
    }

    func testWaypointLine() {
        let w = Waypoint(lat: 54.527, lon: -3.0165, name: "Helvellyn", ele: 950, description: "Summit shelter")
        XCTAssertEqual(RouteText.waypointDetail(w, imperial: false), "\(OsGrid.fromWgs84(w.latLon())!.format(6)!) · 950 m · Summit shelter")
        let abroad = Waypoint(lat: 45.8326, lon: 6.8652, name: "Mont Blanc")
        XCTAssertEqual(RouteText.waypointDetail(abroad, imperial: false), Units.latLon(45.8326, 6.8652))
    }
}
