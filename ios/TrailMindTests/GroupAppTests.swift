import XCTest
@testable import TrailMind

/// The middle of a 15-minute epoch, so one epoch either side is exactly ±900 s.
private let T: Int64 = 1_790_000_550

/// The trip group's app-layer rules and wording (ui/GroupPage.kt, GroupSharing.kt, GroupFinder.kt, GroupFindPage.kt)
/// and the iPhone additions to the protocol (Nearby Interaction tokens, discovery tags, the code at rest).
final class GroupAppTests: XCTestCase {
    private let fixed = SecureRandom { count in [UInt8](repeating: 0x5A, count: count) }

    private func code() -> GroupCode { GroupCode.generate(fixed) }

    // MARK: Wording

    func testAgesAreCoarse() {
        XCTAssertEqual("0 s", GroupText.age(-5))
        XCTAssertEqual("45 s", GroupText.age(45))
        XCTAssertEqual("89 s", GroupText.age(89))
        XCTAssertEqual("1 min", GroupText.age(90))
        XCTAssertEqual("12 min", GroupText.age(12 * 60 + 59))
        XCTAssertEqual("1 h 0 min", GroupText.age(3_600))
        XCTAssertEqual("3 h 5 min", GroupText.age(3 * 3_600 + 5 * 60 + 30))
        XCTAssertEqual("just now", GroupText.ago(59))
        XCTAssertEqual("60 s ago", GroupText.ago(60))
        XCTAssertEqual("2 min ago", GroupText.ago(150))
    }

    func testInitialsTakeTheFirstLetterOfTwoWords() {
        XCTAssertEqual("SJ", GroupText.initials("Sam Jones"))
        XCTAssertEqual("AM", GroupText.initials("anne-marie bloggs"))
        XCTAssertEqual("JS", GroupText.initials("jo_smith"))
        XCTAssertEqual("S", GroupText.initials("  Sam  "))
        XCTAssertEqual("?", GroupText.initials(" - _ "))
        XCTAssertEqual("?", GroupText.initials(""))
        XCTAssertEqual("ÉB", GroupText.initials("élodie bray"))
        // The first code point, not half of a surrogate pair.
        XCTAssertEqual("🥾B", GroupText.initials("🥾 bob"))
    }

    func testNamesIdsAndColours() {
        XCTAssertEqual("Sam", GroupText.name("Sam", memberId: 1))
        XCTAssertEqual("Hiker 3F2A", GroupText.name(nil, memberId: 0x12_3F2A))
        XCTAssertEqual("Hiker FFFF", GroupText.name("  ", memberId: -1))
        XCTAssertEqual("Hiker 000A", GroupText.name("", memberId: 10))
        XCTAssertEqual("ffffffff", GroupText.memberHex(-1))
        XCTAssertEqual("0000002a", GroupText.memberHex(42))
        XCTAssertEqual("80000000", GroupText.memberHex(Int(Int32.min)))
        XCTAssertEqual(0xFF00_897B, GroupColours.of(colour: 0, memberId: 99))
        XCTAssertEqual(0xFFEF_6C00, GroupColours.of(colour: 9, memberId: 0))
        // Math.floorMod: a negative id still picks a colour.
        XCTAssertEqual(0xFF82_7717, GroupColours.of(colour: nil, memberId: -1))
        XCTAssertEqual(8, GroupColours.all.count)
    }

    func testUwbDistances() {
        XCTAssertEqual("3.4 m", GroupText.uwbDistance(3.44, imperial: false))
        XCTAssertEqual("0.1 m", GroupText.uwbDistance(0.05, imperial: false))
        XCTAssertEqual("27 m", GroupText.uwbDistance(26.5, imperial: false))
        XCTAssertEqual("6.6 ft", GroupText.uwbDistance(2.0, imperial: true))
        XCTAssertEqual("33 ft", GroupText.uwbDistance(10.0, imperial: true))
    }

    func testTripsLastADayAndExtendUpToAWeek() {
        let now: Int64 = 1_790_000_000_000
        XCTAssertEqual(now + 2 * TripTimes.tripMs, TripTimes.extended(expiresMs: now + TripTimes.tripMs, nowMs: now))
        XCTAssertEqual(now + TripTimes.tripMs, TripTimes.extended(expiresMs: now - 5_000, nowMs: now))
        XCTAssertEqual(now + TripTimes.maxTripMs, TripTimes.extended(expiresMs: now + 6 * TripTimes.tripMs + 3_600_000, nowMs: now))
    }

    func testCallsForHelpAreWorded() throws {
        XCTAssertEqual("May have fallen", GroupText.help(.fallDetected))
        XCTAssertEqual("Needs help", GroupText.help(.criticalSos))
        XCTAssertEqual("Hurt and can't move", GroupText.help(.injuredStationary))
        XCTAssertEqual("Hurt but moving", GroupText.help(.injuredMoving))
        XCTAssertEqual("", GroupText.help(.ok))
        XCTAssertEqual("is hurt", GroupText.alertWhat(.injuredMoving))
        XCTAssertEqual("needs help", GroupText.alertWhat(.criticalSos))
        var frame = try PositionFrame.of(
            memberId: 5, sequence: 1, originTimeS: T, lat: 54.45, lon: -3.0, altitudeM: nil, accuracyM: 5, batteryPercent: 50,
            status: .fallDetected
        )
        frame.hops = 1
        let alert = GroupText.helpAlert(name: "Sam", frame: frame, here: LatLon(54.44, -3.0), imperial: false, time: "14:05")
        XCTAssertEqual("Sam may have fallen", alert.title)
        XCTAssertEqual("1.11 km N of you · position from 14:05 · passed on by the group", alert.text)
        frame.hops = 0
        XCTAssertEqual("position from 14:05", GroupText.helpAlert(name: "Sam", frame: frame, here: nil, imperial: false, time: "14:05").text)
    }

    func testMemberDetails() throws {
        let pos = try PositionFrame.of(
            memberId: 7, sequence: 3, originTimeS: T - 75, lat: 54.45, lon: -3.0, altitudeM: 812.4, accuracyM: 6, batteryPercent: 64,
            status: .ok, flags: GroupFrames.flagRecording | GroupFrames.flagGroupHike
        )
        let peer = PeerTable.Peer(memberId: 7, name: "Sam", position: pos, lastHeardMs: T * 1_000, lastDirectMs: T * 1_000, rssi: -71)
        let grid = try XCTUnwrap(OsGrid.fromWgs84(LatLon(54.45, -3.0))?.format(8))
        XCTAssertEqual([
            "Position 75 s old, straight from their phone",
            "1.11 km at 000° N from you (straight line)",
            "Grid ref " + grid,
            "Height about 812 m",
            "Accuracy ±6 m · battery 64%",
            "Recording a group hike",
            "In range now · -71 dBm",
        ], GroupText.memberDetails(peer, nowS: T, nowMs: T * 1_000, here: LatLon(54.44, -3.0), imperial: false, inRange: true))
        // An iPhone heard over the direct link has no signal strength to show.
        XCTAssertEqual("In range now · iPhone link", GroupText.memberDetails(
            peer, nowS: T, nowMs: T * 1_000, here: nil, imperial: false, inRange: true, link: "iPhone link"
        ).last)

        var relayed = pos
        relayed.hops = 2
        relayed.status = .criticalSos
        relayed.flags = GroupFrames.flagPaused
        let far = PeerTable.Peer(memberId: 7, name: "Sam", position: relayed, lastHeardMs: T * 1_000, lastDirectMs: (T - 150) * 1_000)
        let lines = GroupText.memberDetails(far, nowS: T, nowMs: T * 1_000, here: nil, imperial: true, inRange: false)
        XCTAssertEqual("⚠ Needs help", lines[0])
        XCTAssertEqual("Position 75 s old, passed on by 2 phones", lines[1])
        XCTAssertEqual("Height about 2664 ft", lines[3])
        XCTAssertEqual("Hike paused", lines[5])
        XCTAssertEqual("Last heard directly 2 min ago", lines[6])
        XCTAssertEqual(
            ["No position from them yet.", "Only heard through other phones"],
            GroupText.memberDetails(PeerTable.Peer(memberId: 9), nowS: T, nowMs: T * 1_000, here: nil, imperial: false, inRange: false)
        )
    }

    func testMemberLines() throws {
        let pos = try PositionFrame.of(
            memberId: 7, sequence: 3, originTimeS: T - 30, lat: 54.45, lon: -3.0, altitudeM: nil, accuracyM: 6, batteryPercent: 64,
            status: .ok
        )
        let peer = PeerTable.Peer(memberId: 7, name: "Sam", position: pos)
        XCTAssertEqual("just now · 1.11 km N · 64% · in range",
                       GroupText.subtitle(peer, nowS: T, here: LatLon(54.44, -3.0), imperial: false, inRange: true))
        var hurt = pos
        hurt.status = .injuredMoving
        hurt.hops = 1
        XCTAssertEqual("Hurt but moving · 2 min ago · 64% · passed on",
                       GroupText.subtitle(PeerTable.Peer(memberId: 7, position: hurt), nowS: T + 90, here: nil, imperial: false, inRange: false))
        XCTAssertEqual("no position yet · out of range",
                       GroupText.subtitle(PeerTable.Peer(memberId: 8), nowS: T, here: nil, imperial: false, inRange: false))
        XCTAssertEqual("Waiting for a GPS fix", GroupText.ownSubtitle(nil, nowS: T, paused: false))
        XCTAssertEqual("Shared just now", GroupText.ownSubtitle(pos, nowS: T, paused: false))
        XCTAssertEqual("Shared 2 min ago · Hurt but moving · sharing paused until TrailMind is open or a hike records",
                       GroupText.ownSubtitle(hurt, nowS: T + 120, paused: true))
    }

    func testDirectionWords() {
        XCTAssertEqual("", GroupText.direction(azimuthDeg: 30, elevationDeg: 40, measured: true, fresh: false))
        XCTAssertEqual("", GroupText.direction(azimuthDeg: nil, elevationDeg: nil, measured: false, fresh: false))
        XCTAssertEqual("Straight ahead", GroupText.direction(azimuthDeg: 9.6, elevationDeg: 5, measured: true, fresh: true))
        XCTAssertEqual("31° to your right", GroupText.direction(azimuthDeg: 30.5, elevationDeg: nil, measured: true, fresh: true))
        XCTAssertEqual("12° to your left · above you", GroupText.direction(azimuthDeg: -12.4, elevationDeg: 20, measured: true, fresh: true))
        XCTAssertEqual("Hold the phone upright in front of you to see which way. · below you",
                       GroupText.direction(azimuthDeg: nil, elevationDeg: -25, measured: true, fresh: true))
        XCTAssertEqual("Their phone is already ranging with someone else. Try again in a minute.", GroupText.declined(RangeFrame.reasonBusy))
        XCTAssertEqual("Their phone couldn't start UWB.", GroupText.declined(RangeFrame.reasonFailed))
    }

    // MARK: Invites

    func testInviteLinksEncodeAsAndroidDoes() throws {
        let code = code()
        let link = GroupInvite.link(name: "Sam's & Joé+1", code: code)
        XCTAssertEqual("trailmind://group/join?code=\(code.text)&name=Sam's%20%26%20Jo%C3%A9%2B1", link)
        let parsed = try XCTUnwrap(GroupInvite.parse(link))
        XCTAssertEqual(code, parsed.code)
        XCTAssertEqual("Sam's & Joé+1", parsed.name)
        XCTAssertEqual(
            "Join my TrailMind trip group \"Lakes\".\n\nCode: \(code.formatted)\n\nIn TrailMind: Safety > Trip group > Join with code, " +
                "or open trailmind://group/join?code=\(code.text)&name=Lakes\n\nOur phones then show each other on the map over " +
                "Bluetooth, with no signal needed.",
            GroupInvite.text(name: "Lakes", code: code)
        )
    }

    func testInviteLinksParseLikeAndroid() throws {
        let code = code()
        // Typed by hand: any case and dashes, '+' for a space, a long name cut to 40.
        let typed = try XCTUnwrap(GroupInvite.parse(
            "trailmind://group/join?name=" + String(repeating: "a", count: 39) + "+x&code=" + code.formatted.lowercased()
        ))
        XCTAssertEqual(code, typed.code)
        // Trimmed, then cut (Kotlin's trim().take(40)), so the cut can end on the space.
        XCTAssertEqual(String(repeating: "a", count: 39) + " ", typed.name)
        XCTAssertNil(GroupInvite.parse("trailmind://strava/callback?code=abc"))
        XCTAssertNil(GroupInvite.parse("https://group/join?code=\(code.text)"))
        let incomplete = try XCTUnwrap(GroupInvite.parse("trailmind://group/join?code=NOTACODE&name=%20%20"))
        XCTAssertNil(incomplete.code)
        XCTAssertNil(incomplete.name)
        XCTAssertEqual(GroupInvite.Parsed(code: nil, name: nil), GroupInvite.parse("trailmind://group"))
    }

    // MARK: Reception log

    func testLogLinesMatchAndroidsColumns() throws {
        let pos = try PositionFrame.of(
            memberId: -2, sequence: 9, originTimeS: T, lat: 54.45, lon: -3.0, altitudeM: nil, accuracyM: 5, batteryPercent: 80, status: .ok
        )
        XCTAssertEqual(
            "1790000550000,fffffffe,position,9,0,2,newer,-70,1m,,54.45,-3.0,1111,54.44,-3.0",
            GroupLog.line(pos, outcome: .newer, rssi: -70, phy: "1m", txPower: nil, nowMs: 1_790_000_550_000, own: LatLon(54.44, -3.0))
        )
        let profile = try ProfileFrame(memberId: 42, colour: 3, name: "Sam", hops: 1, ttl: 1)
        XCTAssertEqual(
            "5,0000002a,profile,,1,1,same,,iphone,,,,,,",
            GroupLog.line(profile, outcome: .same, rssi: nil, phy: "iphone", txPower: nil, nowMs: 5, own: nil)
        )
        XCTAssertEqual(GroupLog.header + "\na\nb\n", GroupLog.csv(["a", "b"]))
        XCTAssertEqual("rejected", GroupLog.outcomeName(.rejected))
    }

    // MARK: iPhone additions

    func testPeerTagsMatchOnlyTheirGroupAndNeighbouringEpochs() {
        let keys = GroupKeys(GroupCode.generate())
        let tag = GroupPeerTag.value(keys, unixSeconds: T)
        XCTAssertEqual(8, tag.count)
        XCTAssertEqual(FrontierCompat.hex(keys.tag(GroupKeys.epoch(T))), tag)
        XCTAssertTrue(GroupPeerTag.matches(keys, tag, unixSeconds: T))
        XCTAssertTrue(GroupPeerTag.matches(keys, tag.uppercased(), unixSeconds: T + 900))
        XCTAssertTrue(GroupPeerTag.matches(keys, tag, unixSeconds: T - 900))
        XCTAssertFalse(GroupPeerTag.matches(keys, tag, unixSeconds: T + 1_800))
        XCTAssertFalse(GroupPeerTag.matches(GroupKeys(GroupCode.generate()), tag, unixSeconds: T))
        XCTAssertFalse(GroupPeerTag.matches(keys, nil, unixSeconds: T))
        XCTAssertFalse(GroupPeerTag.matches(keys, "zz", unixSeconds: T))
        XCTAssertFalse(GroupPeerTag.matches(keys, tag + "00", unixSeconds: T))
    }

    func testTokenMessagesOpenOnlyForTheirGroup() throws {
        let keys = GroupKeys(GroupCode.generate())
        let token = (0..<300).map { UInt8($0 & 0xFF) }
        let message = GroupTokenMessage(kind: GroupTokenMessage.fromFinder, memberId: -7, targetId: 12, nonce: Int64.min + 5, token: token)
        let sealed = try message.seal(keys, unixSeconds: T)
        XCTAssertEqual(GroupTokenMessage.marker, sealed[0])
        XCTAssertEqual(1 + 4 + 12 + 17 + 300 + 16, sealed.count)
        XCTAssertEqual(message, GroupTokenMessage.open(keys, sealed, unixSeconds: T + 600))
        XCTAssertNil(GroupTokenMessage.open(keys, sealed, unixSeconds: T + 1_800))
        XCTAssertNil(GroupTokenMessage.open(GroupKeys(GroupCode.generate()), sealed, unixSeconds: T))
        var tampered = sealed
        tampered[sealed.count - 20] ^= 1
        XCTAssertNil(GroupTokenMessage.open(keys, tampered, unixSeconds: T))
        var header = sealed
        header[0] = UInt8(GroupAdvert.version)
        XCTAssertNil(GroupTokenMessage.open(keys, header, unixSeconds: T))
        // Never mistaken for an advert, nor an advert for one.
        XCTAssertNil(GroupAdvert.open([keys], payload: sealed, unixSeconds: T))
        let advert = try GroupAdvert.build(keys, unixSeconds: T, frames: [try ProfileFrame(memberId: 1, colour: 2, name: "Sam")])
        XCTAssertNil(GroupTokenMessage.open(keys, advert, unixSeconds: T))
        XCTAssertThrowsError(try GroupTokenMessage(kind: 3, memberId: 1, targetId: 2, nonce: 1, token: token).seal(keys, unixSeconds: T))
        XCTAssertThrowsError(try GroupTokenMessage(kind: 1, memberId: 1, targetId: 2, nonce: 1, token: []).seal(keys, unixSeconds: T))
        // Its key is its own: not the frames' key.
        XCTAssertNotEqual(keys.encKey, GroupTokenMessage.key(keys))
        XCTAssertEqual(16, GroupTokenMessage.key(keys).count)
    }

    func testGroupCodesAreSealedAtRest() throws {
        let key = GroupCodeVault.newKey()
        let plain = Array(GroupCode.generate().text.utf8)
        let wrapped = try GroupCodeVault.wrap(plain, key: key)
        XCTAssertEqual(12 + plain.count + 16, wrapped.count)
        XCTAssertNotEqual(plain, Array(wrapped[12..<(12 + plain.count)]))
        XCTAssertEqual(plain, GroupCodeVault.unwrap(wrapped, key: key))
        XCTAssertNil(GroupCodeVault.unwrap(wrapped, key: GroupCodeVault.newKey()))
        XCTAssertNil(GroupCodeVault.unwrap(Array(wrapped.prefix(20)), key: key))
        XCTAssertThrowsError(try GroupCodeVault.wrap(plain, key: [1, 2, 3]))
    }

    func testTheNearbyInteractionBitsStayClearOfAndroids() {
        let android = GroupFrames.capCodedTx | GroupFrames.capCodedRx | GroupFrames.capRelay | GroupFrames.capSatellite |
            GroupFrames.capUwb | GroupFrames.capUwbStatic
        XCTAssertEqual(0, android & GroupIPhone.capNearbyInteraction)
        XCTAssertFalse([UwbSession.configProvisioned, UwbSession.configStatic].contains(GroupIPhone.configNearbyInteraction))
        XCTAssertNoThrow(try RangeFrame(
            memberId: 1, targetId: 2, kind: RangeFrame.request, nonce: 3, timeS: T, configId: GroupIPhone.configNearbyInteraction
        ))
    }
}
