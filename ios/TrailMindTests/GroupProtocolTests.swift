import XCTest
@testable import TrailMind

/// The middle of a 15-minute epoch, so one epoch either side is exactly ±900 s.
private let T: Int64 = 1_790_000_550

/// Port of core/src/test/kotlin/com/trailmind/core/GroupProtocolTest.kt.
final class GroupProtocolTests: XCTestCase {
    private let random = SecureRandom()

    func testHkdfMatchesRfc5869() {
        let ikm = [UInt8](repeating: 0x0b, count: 22)
        let prk = Hkdf.extract((0..<13).map { UInt8($0) }, ikm)
        XCTAssertEqual("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", hex(prk))
        XCTAssertEqual(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            hex(Hkdf.expand(prk, (0..<10).map { UInt8(0xf0 + $0) }, 42))
        )
        let prk3 = Hkdf.extract([], ikm)
        XCTAssertEqual("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04", hex(prk3))
        XCTAssertEqual(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
            hex(Hkdf.expand(prk3, [], 42))
        )
    }

    func testCodesRoundTripAndCatchMostTypos() {
        for _ in 0..<50 {
            let code = GroupCode.generate(random)
            XCTAssertEqual(16, code.text.count)
            XCTAssertEqual(code, GroupCode.parse(code.formatted))
            XCTAssertEqual(code, GroupCode.parse(chunked(code.text.lowercased(), 4).joined(separator: " ")))
            XCTAssertEqual(code, GroupCode.parse(String(code.text.map { $0 == "0" ? "O" : $0 == "1" ? "l" : $0 })))
        }
        let code = GroupCode.generate(random)
        let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
        let text = Array(code.text)
        var caught = 0
        var total = 0
        for i in 0..<GroupCode.length {
            for c in alphabet {
                if c == text[i] { continue }
                total += 1
                var typo = text
                typo[i] = c
                if GroupCode.parse(String(typo)) == nil { caught += 1 }
            }
        }
        XCTAssertTrue(Double(caught) >= Double(total) * 0.9, "caught \(caught) of \(total) single-character typos")
        XCTAssertNil(GroupCode.parse("TOO-SHORT"))
        XCTAssertNil(GroupCode.parse(code.text + "0"))
        XCTAssertNil(GroupCode.parse(String(code.text.dropLast()) + "U"))
        XCTAssertEqual("GroupCode(****)", String(describing: code))
    }

    func testKeysDependOnlyOnTheCode() throws {
        let code = GroupCode.generate(random)
        let a = GroupKeys(code)
        let b = GroupKeys(try XCTUnwrap(GroupCode.parse(code.text)))
        XCTAssertEqual(a.groupId, b.groupId)
        XCTAssertEqual(16, a.groupId.count)
        XCTAssertEqual(a.tag(1_000), b.tag(1_000))
        XCTAssertNotEqual(a.tag(1_000), a.tag(1_001))
        XCTAssertNotEqual(GroupKeys(GroupCode.generate(random)).groupId, a.groupId)
    }

    func testTagsMatchTheirOwnAndNeighbouringEpochsOnly() throws {
        let keys = GroupKeys(GroupCode.generate(random))
        let payload = try GroupAdvert.build(keys, unixSeconds: T, frames: [try position(1)], random: random)
        XCTAssertTrue(keys.matches(payload, offset: 1, unixSeconds: T))
        XCTAssertTrue(keys.matches(payload, offset: 1, unixSeconds: T + 900))
        XCTAssertTrue(keys.matches(payload, offset: 1, unixSeconds: T - 900))
        XCTAssertFalse(keys.matches(payload, offset: 1, unixSeconds: T + 1_800))
        XCTAssertFalse(keys.matches(payload, offset: 1, unixSeconds: T - 1_800))
    }

    func testAdvertsRoundTripAndFitOnePacket() throws {
        let keys = GroupKeys(GroupCode.generate(random))
        let frames: [any GroupFrame] = [
            try position(7, sos: true), try ProfileFrame(memberId: 8, colour: 3, name: "Sam ☃"), try XCTUnwrap(try position(9).relayed()),
        ]
        let payload = try GroupAdvert.build(keys, unixSeconds: T, frames: frames, random: random)
        XCTAssertEqual(185, payload.count + GroupAdvert.adOverhead)
        XCTAssertEqual(77, try GroupAdvert.build(keys, unixSeconds: T, frames: Array(frames.prefix(1)), random: random).count + GroupAdvert.adOverhead)
        let opened = try XCTUnwrap(GroupAdvert.open([GroupKeys(GroupCode.generate(random)), keys], payload: payload, unixSeconds: T))
        XCTAssertTrue(keys === opened.keys)
        XCTAssertEqual(comparable(frames), comparable(opened.frames))
        XCTAssertEqual(3, GroupAdvert.maxFrames(251))
        XCTAssertEqual(3, GroupAdvert.maxFrames(1_650))
        XCTAssertEqual(1, GroupAdvert.maxFrames(80))
        XCTAssertEqual(0, GroupAdvert.maxFrames(31))
    }

    func testTamperedFramesAndOtherGroupsAreRejected() throws {
        let keys = GroupKeys(GroupCode.generate(random))
        let payload = try GroupAdvert.build(keys, unixSeconds: T, frames: [try position(1), try position(2)], random: random)
        XCTAssertNil(GroupAdvert.open([GroupKeys(GroupCode.generate(random))], payload: payload, unixSeconds: T))
        XCTAssertNil(GroupAdvert.open([keys], payload: payload, unixSeconds: T + 1_800))
        // A changed byte in one frame drops that frame only.
        var oneBad = payload
        oneBad[GroupAdvert.headerBytes + 15] ^= 1
        XCTAssertEqual([2], try XCTUnwrap(GroupAdvert.open([keys], payload: oneBad, unixSeconds: T)).frames.map { $0.memberId })
        // Frames are bound to their header: moved under the next epoch's tag, none of them opens.
        let next = try GroupAdvert.build(keys, unixSeconds: T + 900, frames: [try position(1), try position(2)], random: random)
        let spliced = Array(next.prefix(GroupAdvert.headerBytes)) + Array(payload[GroupAdvert.headerBytes...])
        XCTAssertNil(GroupAdvert.open([keys], payload: spliced, unixSeconds: T + 900))
        var otherVersion = payload
        otherVersion[0] = 2
        XCTAssertNil(GroupAdvert.open([keys], payload: otherVersion, unixSeconds: T))
        XCTAssertNil(GroupAdvert.open([keys], payload: Array(payload.dropLast()), unixSeconds: T))
        XCTAssertNil(GroupAdvert.open([keys], payload: [], unixSeconds: T))
    }

    func testPositionFramesKeepPrecisionAndBounds() throws {
        let f = try PositionFrame.of(
            memberId: Int(Int32(bitPattern: 0x8000_0001)), sequence: 4_000_000_000, originTimeS: 1_790_000_000,
            lat: 54.5271234, lon: -3.0164567, altitudeM: 949.4, accuracyM: 4.6, batteryPercent: 73,
            status: .ok, capabilities: 5, flags: GroupFrames.flagRecording
        )
        let back = try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(f)) as? PositionFrame)
        XCTAssertEqual(f, back)
        XCTAssertEqual(54.5271234, back.lat, accuracy: 1e-7)
        XCTAssertEqual(-3.0164567, back.lon, accuracy: 1e-7)
        XCTAssertEqual(949, back.altitudeM)
        XCTAssertEqual(GroupFrames.ttl, back.ttl)
        let sosFrame = try PositionFrame.of(
            memberId: 1, sequence: 1, originTimeS: 1, lat: 0.0, lon: 0.0, altitudeM: nil, accuracyM: 999, batteryPercent: 150,
            status: .criticalSos
        )
        let sos = try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(sosFrame)) as? PositionFrame)
        XCTAssertNil(sos.altitudeM)
        XCTAssertEqual(255, sos.accuracyM)
        XCTAssertEqual(100, sos.batteryPercent)
        XCTAssertEqual(GroupFrames.sosTtl, sos.ttl)
        XCTAssertTrue(sos.needsHelp)
        XCTAssertNil(GroupFrames.decode([UInt8](repeating: 0, count: GroupFrames.size)))
        XCTAssertNil(GroupFrames.decode([UInt8](repeating: 0, count: GroupFrames.size - 1)))
        var badBattery = GroupFrames.encode(f)
        badBattery[24] = 200
        XCTAssertNil(GroupFrames.decode(badBattery))
    }

    func testProfileNamesAreCutAtCharacterBoundaries() throws {
        let name = "Élodie the very long-named hiker 🏔"
        let back = try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(try ProfileFrame(memberId: -5, colour: 7, name: name))) as? ProfileFrame)
        XCTAssertEqual("Élodie the very long-n", back.name)
        XCTAssertEqual(try ProfileFrame(memberId: -5, colour: 7, name: back.name), back)
        let mountains = try ProfileFrame(memberId: 1, colour: 0, name: String(repeating: "🏔", count: 9))
        XCTAssertEqual("🏔🏔🏔🏔🏔", try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(mountains)) as? ProfileFrame).name)
    }

    func testPeerTableKeepsTheNewestAndIgnoresItsOwnFrames() throws {
        let table = PeerTable(ownMemberId: 1)
        XCTAssertEqual(.rejected, table.accept(try position(1), receivedMs: 0, nowS: T, rssi: -60, coded: false))
        let news = try position(2, seq: 5)
        XCTAssertEqual(.new, table.accept(try XCTUnwrap(news.relayed()), receivedMs: 1_000, nowS: T, rssi: -80, coded: false))
        XCTAssertEqual(1, try XCTUnwrap(table.peer(2)?.position).hops)
        XCTAssertEqual(.same, table.accept(news, receivedMs: 2_000, nowS: T, rssi: -70, coded: true))
        let peer = try XCTUnwrap(table.peer(2))
        XCTAssertEqual(0, try XCTUnwrap(peer.position).hops)
        XCTAssertEqual(-70, peer.rssi)
        XCTAssertTrue(peer.coded)
        XCTAssertEqual(1_000, peer.positionReceivedMs)
        XCTAssertEqual(.older, table.accept(try position(2, time: T - 10, seq: 4), receivedMs: 3_000, nowS: T, rssi: -60, coded: false))
        XCTAssertEqual(5, try XCTUnwrap(table.peer(2)?.position).sequence)
        XCTAssertEqual(.newer, table.accept(try position(2, time: T + 10, seq: 6), receivedMs: 4_000, nowS: T + 10, rssi: -60, coded: false))
        XCTAssertEqual(.rejected, table.accept(try position(3, time: T + 1_000), receivedMs: 5_000, nowS: T, rssi: -60, coded: false))
        XCTAssertEqual(.new, table.accept(try ProfileFrame(memberId: 2, colour: 4, name: "Sam"), receivedMs: 6_000, nowS: T, rssi: -60, coded: false))
        XCTAssertEqual("Sam", try XCTUnwrap(table.peer(2)).name)
        XCTAssertEqual(.same, table.accept(try ProfileFrame(memberId: 2, colour: 4, name: "Sam"), receivedMs: 7_000, nowS: T, rssi: -60, coded: false))
        XCTAssertEqual([2], table.peers().map { $0.memberId })
    }

    func testFreshnessBands() throws {
        XCTAssertEqual(.fresh, PeerTable.freshness(try position(2, time: T - 120), nowS: T))
        XCTAssertEqual(.stale, PeerTable.freshness(try position(2, time: T - 121), nowS: T))
        XCTAssertEqual(.stale, PeerTable.freshness(try position(2, time: T - 900), nowS: T))
        XCTAssertEqual(.lastSeen, PeerTable.freshness(try position(2, time: T - 901), nowS: T))
    }

    func testRelayPassesOnCallsForHelpFirstAndRetiresFrames() throws {
        let relay = RelayPolicy()
        relay.offer(try position(2), receivedMs: 0)
        relay.offer(try position(3, sos: true), receivedMs: 0)
        relay.offer(try position(4), receivedMs: 0)
        var spent = try position(5)
        spent.ttl = 0
        relay.offer(spent, receivedMs: 0)
        XCTAssertEqual(3, relay.size())
        let first = relay.pick(nowMs: 1_000, nowS: T, max: 2, helpOnly: false)
        XCTAssertEqual([3, 2], first.map { $0.memberId })
        XCTAssertTrue(first.allSatisfy { $0.hops == 1 })
        XCTAssertEqual([GroupFrames.sosTtl - 1, GroupFrames.ttl - 1], first.map { $0.ttl })
        XCTAssertEqual([3, 4], relay.pick(nowMs: 2_000, nowS: T, max: 2, helpOnly: false).map { $0.memberId })
        XCTAssertEqual([3], relay.pick(nowMs: 3_000, nowS: T, max: 3, helpOnly: true).map { $0.memberId })
        // The same news arriving again through another phone doesn't replace the copy with more hops left.
        relay.offer(try XCTUnwrap(try position(3, sos: true).relayed()), receivedMs: 4_000)
        let single = relay.pick(nowMs: 4_000, nowS: T, max: 1, helpOnly: false)
        XCTAssertEqual(1, single.count)
        XCTAssertEqual(GroupFrames.sosTtl - 1, single.first?.ttl)
        XCTAssertEqual([3], relay.pick(nowMs: 61_000, nowS: T + 61, max: 3, helpOnly: false).map { $0.memberId })
        XCTAssertTrue(relay.pick(nowMs: 301_000, nowS: T + 301, max: 3, helpOnly: false).isEmpty)
    }

    func testRadioProfilesFollowWhatThePhoneIsDoing() throws {
        XCTAssertNil(RadioProfile.plan(uiVisible: false, recording: false, boost: true, batteryPercent: 80, powerSave: false, relay: true))
        let onScreen = try XCTUnwrap(RadioProfile.plan(uiVisible: true, recording: false, boost: false, batteryPercent: 80, powerSave: false, relay: true))
        XCTAssertEqual(.onScreen, onScreen.mode)
        XCTAssertEqual(.lowLatency, onScreen.scan)
        let recording = try XCTUnwrap(RadioProfile.plan(uiVisible: false, recording: true, boost: false, batteryPercent: 80, powerSave: false, relay: true))
        XCTAssertEqual(.balanced, recording.scan)
        XCTAssertNil(recording.scanRefreshMs)
        let saver = try XCTUnwrap(RadioProfile.plan(uiVisible: true, recording: true, boost: false, batteryPercent: 20, powerSave: false, relay: true))
        XCTAssertEqual(.saver, saver.mode)
        XCTAssertTrue(saver.relayHelpOnly)
        XCTAssertEqual(
            .saver,
            try XCTUnwrap(RadioProfile.plan(uiVisible: false, recording: true, boost: false, batteryPercent: nil, powerSave: true, relay: true)).mode
        )
        let boost = try XCTUnwrap(RadioProfile.plan(uiVisible: false, recording: true, boost: true, batteryPercent: 10, powerSave: true, relay: false))
        XCTAssertEqual(.boost, boost.mode)
        XCTAssertEqual(.lowLatency, boost.scan)
        XCTAssertNotNil(boost.scanRefreshMs)
        XCTAssertFalse(boost.relay)
    }

    private func position(_ member: Int, time: Int64 = T, seq: Int64 = 1, sos: Bool = false) throws -> PositionFrame {
        try PositionFrame.of(
            memberId: member, sequence: seq, originTimeS: time, lat: 54.5, lon: -3.0, altitudeM: 900.0, accuracyM: 5,
            batteryPercent: 80, status: sos ? .criticalSos : .ok
        )
    }

    /// Frames of different kinds, compared by value as Kotlin's `assertEquals` on lists of data classes does.
    private func comparable(_ frames: [any GroupFrame]) -> [AnyHashable] { frames.map { AnyHashable($0) } }

    /// Kotlin's `chunked(n)`.
    private func chunked(_ text: String, _ size: Int) -> [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: size).map { String(characters[$0..<min($0 + size, characters.count)]) }
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
}
