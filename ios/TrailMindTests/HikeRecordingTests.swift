import XCTest
@testable import TrailMind

/// The recording side of the hikes feature: TrackingState (HikeTrack), TrackingService's per-fix handling
/// (RecordingPipeline) and its storm alarm (HikeStormWatch). The Android app has no unit tests for these, so these pin
/// down the behaviour the port keeps.
final class HikeRecordingTests: XCTestCase {
    private let start = LatLon(54.0, -3.0)

    private func east(_ m: Double, from: LatLon? = nil) -> LatLon { Geo.destination(from ?? start, bearingDeg: 90.0, distanceM: m) }

    private func point(_ m: Double, ele: Double? = nil, timeMs: Int64? = nil) -> TrackPoint {
        let p = east(m)
        return TrackPoint(lat: p.lat, lon: p.lon, ele: ele, timeMs: timeMs, accuracyM: 5)
    }

    // MARK: HikeTrack

    func testDistanceAscentAndDescentAccumulateWithHysteresis() {
        let track = HikeTrack()
        track.begin(id: 1, name: "Walk", start: 0, restored: [], restoredActiveMs: 0, nowMs: 0)
        let eles = [100.0, 102.0, 105.0, 103.0, 110.0, 109.0, 100.0]
        for (i, e) in eles.enumerated() { XCTAssertTrue(track.add(point(Double(i) * 10.0, ele: e))) }
        XCTAssertEqual(track.distanceM, 60.0, accuracy: 0.01)
        XCTAssertEqual(track.ascentM, 10.0)
        XCTAssertEqual(track.descentM, 10.0)
        XCTAssertEqual(track.points.count, 7)
        XCTAssertEqual(track.line.count, 1)
        XCTAssertEqual(track.line[0].count, 7)
        XCTAssertEqual(track.status, .recording)
        XCTAssertEqual(track.hikeId, 1)
    }

    func testPausingStopsTheClockIgnoresPointsAndBreaksTheLine() {
        let track = HikeTrack()
        track.begin(id: 2, name: "Walk", start: 0, restored: [], restoredActiveMs: 0, nowMs: 0)
        track.add(point(0, ele: 100))
        track.add(point(10, ele: 100))
        track.pause(nowMs: 60_000)
        XCTAssertEqual(track.status, .paused)
        XCTAssertFalse(track.add(point(20)))
        XCTAssertEqual(track.activeMs(100_000), 60_000)
        track.resume(nowMs: 120_000)
        XCTAssertTrue(track.add(point(500, ele: 150)))
        XCTAssertEqual(track.activeMs(180_000), 120_000)
        // The gap is neither drawn nor counted, and the climb starts afresh after the break.
        XCTAssertEqual(track.line.map(\.count), [2, 1])
        XCTAssertEqual(track.distanceM, 10.0, accuracy: 0.01)
        XCTAssertEqual(track.ascentM, 0.0)
        XCTAssertEqual(track.points.count, 3)
    }

    func testARewindTakesTheDriveOffTheActiveTime() {
        let track = HikeTrack()
        track.begin(id: 3, name: "Walk", start: 0, restored: [], restoredActiveMs: 0, nowMs: 0)
        track.pause(rewindMs: 30_000, nowMs: 100_000)
        XCTAssertEqual(track.activeMs(500_000), 70_000)
        track.resume(nowMs: 200_000)
        track.pause(rewindMs: 90_000, nowMs: 260_000)
        XCTAssertEqual(track.activeMs(900_000), 70_000)
    }

    func testBeginRestoresSegmentsWithoutJoiningThem() {
        let track = HikeTrack()
        let restored = [[point(0, ele: 100), point(10, ele: 110)], [point(1_000, ele: 50), point(1_020, ele: 40)]]
        track.begin(id: 4, name: "Recovered", start: 5, restored: restored, restoredActiveMs: 600_000, nowMs: 1_000_000)
        XCTAssertEqual(track.status, .recording)
        XCTAssertEqual(track.hikeName, "Recovered")
        XCTAssertEqual(track.startMs, 5)
        XCTAssertEqual(track.distanceM, 30.0, accuracy: 0.01)
        XCTAssertEqual(track.ascentM, 10.0)
        XCTAssertEqual(track.descentM, 10.0)
        XCTAssertEqual(track.line.map(\.count), [2, 2])
        // The first point after recovery starts a new part, as the recorder starts a new segment.
        track.add(point(2_000, ele: 300))
        XCTAssertEqual(track.line.map(\.count), [2, 2, 1])
        XCTAssertEqual(track.distanceM, 30.0, accuracy: 0.01)
        XCTAssertEqual(track.activeMs(1_060_000), 660_000)
    }

    func testEndClearsTheRecording() {
        let track = HikeTrack()
        track.begin(id: 6, name: "Walk", start: 0, restored: [], restoredActiveMs: 0, nowMs: 0)
        track.add(point(0))
        track.add(point(50))
        track.end()
        XCTAssertEqual(track.status, .idle)
        XCTAssertNil(track.hikeId)
        XCTAssertTrue(track.points.isEmpty)
        XCTAssertTrue(track.line.isEmpty)
        XCTAssertEqual(track.distanceM, 0.0)
        XCTAssertEqual(track.activeMs(1_000_000), 0)
        XCTAssertFalse(track.add(point(100)))
    }

    // MARK: RecordingPipeline

    private var t: Int64 = 0
    private var lat = 51.8

    /// One fix every 2 s heading north at `mps`, with the receiver's speed.
    private func fix(_ pipeline: RecordingPipeline, _ mps: Double, autoPause: Bool = true) -> RecordingPipeline.Outcome {
        t += 2_000
        lat += mps * 2.0 / 111_320.0
        let p = TrackPoint(lat: lat, lon: -2.5, ele: 200, timeMs: t, accuracyM: 8)
        return pipeline.onFix(p, steadyMs: t, accuracyM: 8, speedMps: mps, autoPauseInVehicle: autoPause)
    }

    private func move(_ pipeline: RecordingPipeline, _ mps: Double, _ seconds: Int, autoPause: Bool = true) -> [RecordingPipeline.Outcome] {
        (0..<(seconds / 2)).map { _ in fix(pipeline, mps, autoPause: autoPause) }
    }

    private func stored(_ outcomes: [RecordingPipeline.Outcome]) -> [TrackPoint] {
        outcomes.flatMap { outcome -> [TrackPoint] in
            if case .store(let points) = outcome { return points }
            return []
        }
    }

    func testWalkingIsStoredThroughTheBreadcrumbFilter() {
        let pipeline = RecordingPipeline()
        let outcomes = move(pipeline, 1.4, 60)
        // 2.8 m between fixes: the filter keeps the first and then every fix 5 m on from the last kept one.
        XCTAssertEqual(stored(outcomes).count, 15)
        XCTAssertTrue(pipeline.held.isEmpty)
    }

    func testABurstIsHeldBackThenSavedWhenItEnds() {
        let pipeline = RecordingPipeline()
        let walk = stored(move(pipeline, 1.3, 30))
        let burst = move(pipeline, 9.0, 14)
        XCTAssertTrue(burst.allSatisfy { $0 == .store([]) })
        let heldDuringBurst = pipeline.held
        XCTAssertFalse(heldDuringBurst.isEmpty)
        let after = move(pipeline, 1.3, 30)
        let saved = stored(after)
        // Nothing is lost: the held fixes come first, in order, once the run is over.
        XCTAssertEqual(Array(saved.prefix(heldDuringBurst.count)), heldDuringBurst)
        XCTAssertTrue(pipeline.held.isEmpty)
        let times = (walk + saved).compactMap(\.timeMs)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count)
    }

    func testADriveIsDroppedAndPausesTheHikeWithTheDriveTakenOff() throws {
        let pipeline = RecordingPipeline()
        let walk = stored(move(pipeline, 1.3, 60))
        let lastWalkTime = try XCTUnwrap(walk.last?.timeMs)
        let drive = move(pipeline, 14.0, 60)
        let pauseIndex = try XCTUnwrap(drive.firstIndex { if case .autoPause = $0 { return true } else { return false } })
        XCTAssertEqual(drive[pauseIndex], .autoPause(rewindMs: 30_000))
        // No fix taken during the drive reaches the saved track.
        XCTAssertTrue(stored(Array(drive.prefix(pauseIndex))).allSatisfy { ($0.timeMs ?? 0) <= lastWalkTime })
        XCTAssertTrue(pipeline.held.isEmpty)
    }

    func testWithAutoPauseOffEveryFixGoesThroughTheFilter() {
        let pipeline = RecordingPipeline()
        _ = move(pipeline, 1.3, 30, autoPause: false)
        let drive = move(pipeline, 14.0, 60, autoPause: false)
        XCTAssertFalse(drive.contains { if case .autoPause = $0 { return true } else { return false } })
        XCTAssertEqual(stored(drive).count, 30)
        XCTAssertTrue(pipeline.held.isEmpty)
    }

    func testFlushHeldSavesTheBurstOnPause() {
        let pipeline = RecordingPipeline()
        _ = move(pipeline, 1.3, 30)
        _ = move(pipeline, 9.0, 10)
        let held = pipeline.held
        XCTAssertFalse(held.isEmpty)
        XCTAssertEqual(pipeline.flushHeld(), held)
        XCTAssertTrue(pipeline.flushHeld().isEmpty)
    }

    // MARK: HikeStormWatch

    /// Station pressure at `altitudeM` for a sea-level pressure (the ISA formula the watch inverts).
    private func station(_ seaLevelHpa: Double, _ altitudeM: Double) -> Double {
        seaLevelHpa * pow(1 - altitudeM / HikeStormWatch.scaleM, HikeStormWatch.exponent)
    }

    func testAFallingSeaLevelPressureWarnsOnceEveryThreeHours() throws {
        let watch = HikeStormWatch()
        for minute in 0...180 {
            let now = Int64(minute) * 60_000
            let seaLevel = 1012.0 - 8.0 * Double(minute) / 180.0
            for _ in 0..<5 { watch.onPressure(station(seaLevel, 500)) }
            watch.onFix(gpsAltitudeM: 500, accuracyM: 5, nowMs: now)
            if minute == 140 { XCTAssertNil(watch.change(), "needs 80% of the three hours") }
        }
        let change = try XCTUnwrap(watch.change())
        XCTAssertLessThan(change, -4.0)
        XCTAssertGreaterThan(change, -8.0)
        XCTAssertEqual(watch.alertDue(nowMs: 180 * 60_000), change)
        XCTAssertNil(watch.alertDue(nowMs: 181 * 60_000))
        XCTAssertNil(watch.alertDue(nowMs: (180 + 179) * 60_000))
        watch.resetAlerts()
        XCTAssertEqual(watch.alertDue(nowMs: 182 * 60_000), change)
    }

    func testClimbingIsNotAStorm() throws {
        let watch = HikeStormWatch()
        for minute in 0...180 {
            let altitude = 100.0 + 700.0 * Double(minute) / 180.0
            for _ in 0..<5 { watch.onPressure(station(1015.0, altitude)) }
            watch.onFix(gpsAltitudeM: altitude, accuracyM: 5, nowMs: Int64(minute) * 60_000)
        }
        let change = try XCTUnwrap(watch.change())
        XCTAssertEqual(change, 0.0, accuracy: 0.5)
        XCTAssertNil(watch.alertDue(nowMs: 180 * 60_000))
    }

    func testPoorGpsAltitudeAndMissingPressureAreIgnored() {
        let watch = HikeStormWatch()
        watch.onFix(gpsAltitudeM: 300, accuracyM: 5, nowMs: 0)
        XCTAssertNil(watch.seaLevelHpa)
        watch.onPressure(980)
        watch.onFix(gpsAltitudeM: 300, accuracyM: 40, nowMs: 60_000)
        XCTAssertNil(watch.seaLevelHpa)
        watch.onFix(gpsAltitudeM: nil, accuracyM: 5, nowMs: 120_000)
        XCTAssertNil(watch.seaLevelHpa)
        watch.onFix(gpsAltitudeM: 300, accuracyM: 5, nowMs: 180_000)
        XCTAssertEqual(watch.seaLevelHpa ?? 0, HikeStormWatch.seaLevelHpa(980, 300), accuracy: 1e-9)
    }

    // MARK: Wording

    func testNewHikeNames() {
        XCTAssertEqual(HikeText.hikeTitle(name: "Helvellyn", groupName: "Lakes", stamp: "31 Oct 2026 at 09:18"), "Helvellyn")
        XCTAssertEqual(HikeText.hikeTitle(name: "  ", groupName: "Lakes", stamp: "31 Oct 2026 at 09:18"), "Lakes · 31 Oct 2026 at 09:18")
        XCTAssertEqual(HikeText.hikeTitle(name: nil, groupName: nil, stamp: "31 Oct 2026 at 09:18"), "Hike 31 Oct 2026 at 09:18")
    }

    func testRecordingWording() {
        XCTAssertEqual(HikeText.weatherWarning(changeHpa: -4.25),
                       "Air pressure has fallen 4.3 hPa in 3 hours, so the weather may be turning. Check the forecast and your way off the hill.")
        XCTAssertEqual(HikeText.averagePace(distanceM: 3_000, activeMs: 3_600_000, imperial: false), "3.0 km/h")
        XCTAssertEqual(HikeText.averagePace(distanceM: 3_000, activeMs: 3_600_000, imperial: true), "1.9 mph")
        XCTAssertEqual(HikeText.averagePace(distanceM: 20, activeMs: 3_600_000, imperial: false), "—")
        XCTAssertEqual(HikeText.averagePace(distanceM: 3_000, activeMs: 30_000, imperial: false), "—")
    }
}
