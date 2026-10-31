import XCTest
@testable import TrailMind

private let nowS: Int64 = 1_790_000_000
private let nowMs: Int64 = nowS * 1_000
private let recordingForGroup = GroupFrames.flagRecording | GroupFrames.flagGroupHike

/// Port of core/src/test/kotlin/com/trailmind/core/GroupHikeTest.kt.
final class GroupHikeTests: XCTestCase {
    private let watch = GroupHikeWatch()

    private func peer(_ id: Int, _ flags: Int, ageS: Int64 = 10, sequence: Int64 = 1, atS: Int64 = nowS) throws -> PeerTable.Peer {
        PeerTable.Peer(
            memberId: id,
            position: try PositionFrame.of(
                memberId: id, sequence: sequence, originTimeS: atS - ageS, lat: 51.8, lon: -2.5, altitudeM: 120.0, accuracyM: 5,
                batteryPercent: 80, status: .ok, flags: flags
            )
        )
    }

    func testTheGroupHikeFlagSurvivesTheAir() throws {
        let f = try PositionFrame.of(
            memberId: 7, sequence: 1, originTimeS: nowS, lat: 51.8, lon: -2.5, altitudeM: nil, accuracyM: 5, batteryPercent: 90,
            status: .ok, flags: recordingForGroup
        )
        let back = try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(f)) as? PositionFrame)
        XCTAssertEqual(recordingForGroup, back.flags)
        XCTAssertTrue(GroupHikeWatch.isGroupHike(back))
        // A solo recording is not an invitation.
        var solo = back
        solo.flags = GroupFrames.flagRecording
        XCTAssertFalse(GroupHikeWatch.isGroupHike(solo))
        // Nor is a paused group hike.
        var paused = back
        paused.flags = GroupFrames.flagPaused | GroupFrames.flagGroupHike
        XCTAssertFalse(GroupHikeWatch.isGroupHike(paused))
    }

    func testAMemberRecordingForTheGroupIsOfferedOnce() throws {
        let peers = [try peer(1, recordingForGroup)]
        XCTAssertEqual(1, watch.next(peers, nowS: nowS, nowMs: nowMs)?.memberId)
        XCTAssertNil(watch.next(peers, nowS: nowS + 5, nowMs: nowMs + 5_000))
    }

    func testNothingIsOfferedForSoloIdleOrStaleMembers() throws {
        let peers = [
            try peer(1, GroupFrames.flagRecording),
            try peer(2, 0),
            try peer(3, recordingForGroup, ageS: PeerTable.freshS + 1),
            PeerTable.Peer(memberId: 4),
        ]
        XCTAssertNil(watch.next(peers, nowS: nowS, nowMs: nowMs))
    }

    func testTheFreshestHikeWinsWhenSeveralAreGoingOn() throws {
        let peers = [try peer(1, recordingForGroup, ageS: 60), try peer(2, recordingForGroup, ageS: 5)]
        XCTAssertEqual(2, watch.next(peers, nowS: nowS, nowMs: nowMs)?.memberId)
        XCTAssertEqual(1, watch.next(peers, nowS: nowS, nowMs: nowMs)?.memberId)
        XCTAssertNil(watch.next(peers, nowS: nowS, nowMs: nowMs))
    }

    func testAPausedHikeIsNotOfferedAgainOnceTheMemberResumes() throws {
        XCTAssertEqual(1, watch.next([try peer(1, recordingForGroup)], nowS: nowS, nowMs: nowMs)?.memberId)
        // They stop for lunch (or the car park): still the same hike.
        XCTAssertNil(watch.next(
            [try peer(1, GroupFrames.flagPaused | GroupFrames.flagGroupHike)], nowS: nowS + 600, nowMs: nowMs + 600_000
        ))
        XCTAssertNil(watch.next([try peer(1, recordingForGroup)], nowS: nowS + 1_200, nowMs: nowMs + 1_200_000))
    }

    func testANewHikeAfterTheOldOneEndedIsOffered() throws {
        XCTAssertEqual(1, watch.next([try peer(1, recordingForGroup)], nowS: nowS, nowMs: nowMs)?.memberId)
        XCTAssertNil(watch.next([try peer(1, 0)], nowS: nowS + 3_600, nowMs: nowMs + 3_600_000))
        let later = try peer(1, recordingForGroup, ageS: 5, sequence: 9, atS: nowS + 7_200)
        XCTAssertEqual(1, watch.next([later], nowS: nowS + 7_200, nowMs: nowMs + 7_200_000)?.memberId)
    }

    func testFinishingYourOwnHikeDoesNotPullYouBackIn() throws {
        let peers = [try peer(1, recordingForGroup), try peer(2, 0)]
        watch.handleAll(peers, nowMs: nowMs)
        XCTAssertNil(watch.next(peers, nowS: nowS + 30, nowMs: nowMs + 30_000))
        // Someone else starting afterwards is still offered.
        XCTAssertEqual(
            2,
            watch.next([try peer(1, recordingForGroup), try peer(2, recordingForGroup)], nowS: nowS + 60, nowMs: nowMs + 60_000)?.memberId
        )
    }

    func testADayLaterAHikeStillGoingOnIsOfferedAgain() throws {
        XCTAssertEqual(1, watch.next([try peer(1, recordingForGroup)], nowS: nowS, nowMs: nowMs)?.memberId)
        let day: Int64 = 25 * 3_600
        XCTAssertEqual(
            1,
            watch.next([try peer(1, recordingForGroup, ageS: 5, atS: nowS + day)], nowS: nowS + day, nowMs: nowMs + day * 1_000)?.memberId
        )
    }

    func testClearForgetsEverything() throws {
        let peers = [try peer(1, recordingForGroup)]
        _ = watch.next(peers, nowS: nowS, nowMs: nowMs)
        watch.clear()
        XCTAssertEqual(1, watch.next(peers, nowS: nowS, nowMs: nowMs + 1)?.memberId)
    }

    func testAnOfferThatCouldNotBeShownCanBeMadeAgain() throws {
        let peers = [try peer(1, recordingForGroup)]
        XCTAssertEqual(1, watch.next(peers, nowS: nowS, nowMs: nowMs)?.memberId)
        watch.forget(1)
        XCTAssertEqual(1, watch.next(peers, nowS: nowS + 5, nowMs: nowMs + 5_000)?.memberId)
    }
}
