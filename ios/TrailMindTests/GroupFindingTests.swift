import XCTest
@testable import TrailMind

/// Port of core/src/test/kotlin/com/trailmind/core/GroupFindingTest.kt.
final class GroupFindingTests: XCTestCase {
    private let code = GroupCode.generate(SecureRandom())

    func testRangeFramesSurviveTheAirAndAreNeverPassedOn() throws {
        let request = try RangeFrame(
            memberId: 0x11223344, targetId: -5, kind: RangeFrame.request, nonce: Int64.min + 7, timeS: 0xFFFF_FFF0,
            configId: UwbSession.configProvisioned, channel: 9, preambleIndex: 11, updateRate: 1
        )
        let bytes = GroupFrames.encode(request)
        XCTAssertEqual(GroupFrames.size, bytes.count)
        XCTAssertEqual(request, GroupFrames.decode(bytes) as? RangeFrame)
        XCTAssertNil(request.relayed())
        XCTAssertEqual(0, request.hops)
        var declined = request
        declined.kind = RangeFrame.decline
        declined.reason = RangeFrame.reasonBusy
        XCTAssertEqual(declined, GroupFrames.decode(GroupFrames.encode(declined)) as? RangeFrame)
        // Kinds this version doesn't know are dropped, not guessed at.
        for kind in [0, 5, 15] {
            var unknown = bytes
            unknown[0] = UInt8((GroupFrames.typeRange << 4) | kind)
            XCTAssertNil(GroupFrames.decode(unknown))
        }

        let keys = GroupKeys(code)
        let position = try PositionFrame.of(
            memberId: 0x11223344, sequence: 3, originTimeS: 1_700_000_000, lat: 54.5, lon: -3.0, altitudeM: 900.0, accuracyM: 5,
            batteryPercent: 80, status: .ok
        )
        let advert = try GroupAdvert.build(keys, unixSeconds: 1_700_000_000, frames: [position, request], random: SecureRandom())
        XCTAssertEqual(
            [AnyHashable(position), AnyHashable(request)],
            try XCTUnwrap(GroupAdvert.open([keys], payload: advert, unixSeconds: 1_700_000_000)).frames.map { AnyHashable($0) }
        )
    }

    func testARangeFrameCountsAsHearingTheMemberDirectly() throws {
        let table = PeerTable(ownMemberId: 1)
        let frame = try RangeFrame(memberId: 2, targetId: 1, kind: RangeFrame.accept, nonce: 42, timeS: 1_700_000_000)
        XCTAssertEqual(.same, table.accept(frame, receivedMs: 5_000, nowS: 1_700_000_000, rssi: -61, coded: true))
        let peer = try XCTUnwrap(table.peer(2))
        XCTAssertEqual(5_000, peer.lastDirectMs)
        XCTAssertEqual(-61, peer.rssi)
        XCTAssertTrue(peer.coded)
        XCTAssertNil(peer.position)
        var own = frame
        own.memberId = 1
        XCTAssertEqual(.rejected, table.accept(own, receivedMs: 6_000, nowS: 1_700_000_000, rssi: -50, coded: false))
    }

    func testBothPhonesWorkOutTheSameSession() throws {
        let finder = UwbSession.derive(GroupKeys(code), initiatorId: 7, responderId: 9, nonce: 1234)
        let found = UwbSession.derive(GroupKeys(try XCTUnwrap(GroupCode.parse(code.text))), initiatorId: 7, responderId: 9, nonce: 1234)
        XCTAssertEqual(finder.sessionId, found.sessionId)
        XCTAssertEqual(finder.localAddress(initiator: true), found.peerAddress(initiator: false))
        XCTAssertEqual(finder.peerAddress(initiator: true), found.localAddress(initiator: false))
        XCTAssertEqual(finder.keyFor(UwbSession.configProvisioned), found.keyFor(UwbSession.configProvisioned))
        XCTAssertEqual(finder.keyFor(UwbSession.configStatic), found.keyFor(UwbSession.configStatic))
        XCTAssertNil(finder.keyFor(2))

        let again = UwbSession.derive(GroupKeys(code), initiatorId: 7, responderId: 9, nonce: 1235)
        XCTAssertNotEqual(finder.sessionId, again.sessionId)
        XCTAssertNotEqual(try XCTUnwrap(finder.keyFor(UwbSession.configProvisioned)), again.keyFor(UwbSession.configProvisioned))
        let otherGroup = UwbSession.derive(GroupKeys(GroupCode.generate(SecureRandom())), initiatorId: 7, responderId: 9, nonce: 1234)
        XCTAssertNotEqual(try XCTUnwrap(finder.keyFor(UwbSession.configProvisioned)), otherGroup.keyFor(UwbSession.configProvisioned))
        let reversed = UwbSession.derive(GroupKeys(code), initiatorId: 9, responderId: 7, nonce: 1234)
        XCTAssertNotEqual(finder.sessionId, reversed.sessionId)
    }

    func testSessionsAreAlwaysUsable() throws {
        let keys = GroupKeys(code)
        // Kotlin's Random(5), so these are the same 3,000 sessions as Android's test checks.
        var random = FrontierParityTests.KotlinRandom(seed: 5)
        for _ in 0..<3_000 {
            let s = UwbSession.derive(
                keys, initiatorId: Int(random.nextInt()), responderId: Int(random.nextInt()), nonce: random.nextLong()
            )
            XCTAssertTrue(s.sessionId > 0)
            let a = s.localAddress(initiator: true)
            let b = s.localAddress(initiator: false)
            XCTAssertEqual(2, a.count)
            XCTAssertNotEqual(a, b)
            for address in [a, b] {
                let v = (Int(address[0]) << 8) | Int(address[1])
                XCTAssertTrue(v != 0x0000 && v != 0xFFFF, "address \(v)")
            }
            XCTAssertEqual(16, try XCTUnwrap(s.keyFor(UwbSession.configProvisioned)).count)
            let staticKey = try XCTUnwrap(s.keyFor(UwbSession.configStatic))
            XCTAssertEqual(8, staticKey.count)
            XCTAssertTrue(staticKey[0] != 0 || staticKey[1] != 0)
        }
    }
}
