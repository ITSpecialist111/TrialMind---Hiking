import XCTest
@testable import TrailMind

/// Fixed-input bytes and texts produced by the Android (Kotlin) core on the JVM, which the iPhone must reproduce
/// exactly: phones of either kind read each other's group adverts, and both send the same SOS texts. Each input here
/// is the same as in the Kotlin that produced the expected values (for example `GroupCode.generate` fed the bytes
/// 0x10, 0x11, ... by a counting `SecureRandom`).
final class FrontierParityTests: XCTestCase {
    /// Kotlin's `Random(seed)` (XorWow), so ported tests draw the same values as Android's.
    struct KotlinRandom {
        private var x: Int32
        private var y: Int32
        private var z: Int32
        private var w: Int32
        private var v: Int32
        private var addend: Int32

        init(seed: Int32) {
            let seed2 = seed >> 31
            x = seed
            y = seed2
            z = 0
            w = 0
            v = ~seed
            addend = (seed << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
            for _ in 0..<64 { _ = nextInt() }
        }

        mutating func nextInt() -> Int32 {
            var t = x
            t = t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 2)
            x = y
            y = z
            z = w
            let v0 = v
            w = v0
            t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
            v = t
            addend = addend &+ 362_437
            return t &+ addend
        }

        mutating func nextLong() -> Int64 {
            let high = Int64(nextInt()) << 32
            return high &+ Int64(nextInt())
        }
    }

    private let time: Int64 = 1_790_000_550

    func testKotlinRandomMatchesAndroid() {
        var random = KotlinRandom(seed: 5)
        XCTAssertEqual(-1_350_163_013, random.nextInt())
        XCTAssertEqual(-332_731_564, random.nextInt())
        XCTAssertEqual(-4_882_580_274_371_907_140, random.nextLong())
        XCTAssertEqual(-189_288_304, random.nextInt())
    }

    func testGroupCodesMatchAndroid() throws {
        let code = GroupCode.generate(counting(from: 0x10))
        XCTAssertEqual("208H44RM2MB1E60V", code.text)
        XCTAssertEqual("208H-44RM-2MB1-E60V", code.formatted)
        XCTAssertEqual("1011121314151617181b", hex(code.bytes))
        XCTAssertEqual(code, GroupCode.parse("208h 44rm-2mbl e6ov"))
        let wrapped = GroupCode.generate(counting(from: 0xF7))
        XCTAssertEqual("YZWFKYQVZKYZXZRA", wrapped.text)
        XCTAssertEqual("f7f8f9fafbfcfdfeff0a", hex(wrapped.bytes))
    }

    func testGroupKeysAndTagsMatchAndroid() {
        let keys = GroupKeys(GroupCode.generate(counting(from: 0x10)))
        XCTAssertEqual("d0d86119278e9e04", keys.groupId)
        let tags: [(Int64, String)] = [
            (0, "d4393265"), (1, "3079f3d8"), (1_988_889, "c55412ca"), (-1, "8eaac249"),
            (2_147_483_648, "1d6bb999"), (4_294_967_301, "4b5ebade"),
        ]
        for (epoch, tag) in tags { XCTAssertEqual(tag, hex(keys.tag(epoch)), "epoch \(epoch)") }
        let epochs: [(Int64, Int64)] = [(-1, -1), (-900, -1), (-901, -2), (0, 0), (899, 0), (900, 1), (time, 1_988_889)]
        for (seconds, epoch) in epochs { XCTAssertEqual(epoch, GroupKeys.epoch(seconds), "\(seconds) s") }
    }

    func testFramesMatchAndroid() throws {
        let (position, sos, profile, range) = try frames()
        XCTAssertEqual([545_271_234, -30_164_567, 5], [position.latE7, position.lonE7, position.accuracyM])
        XCTAssertEqual(-12, position.altitudeM)
        let expected: [(any GroupFrame, String)] = [
            (position, "1580000001ee6b28006ab13da620802dc2fe33b9a9fff40549042a033500"),
            (try XCTUnwrap(position.relayed()), "1580000001ee6b28006ab13da620802dc2fe33b9a9fff40549042a123500"),
            (sos, "10000000070000000100000001ca5b17016b49d1ff8000ff640600030000"),
            (profile, "20fffffffb07c3896c6f646965207468652076657279206c6f6e672d6e02"),
            (range, "3111223344fffffffb8000000000000007fffffff003090b010000000000"),
        ]
        for (frame, android) in expected {
            XCTAssertEqual(android, hex(GroupFrames.encode(frame)))
            let decoded = try XCTUnwrap(GroupFrames.decode(bytes(android)))
            XCTAssertEqual(android, hex(GroupFrames.encode(decoded)))
        }
        XCTAssertEqual("Élodie the very long-n", try XCTUnwrap(GroupFrames.decode(GroupFrames.encode(profile)) as? ProfileFrame).name)
        var decline = range
        decline.kind = RangeFrame.decline
        decline.reason = RangeFrame.reasonBusy
        XCTAssertEqual("3411223344fffffffb8000000000000007fffffff003090b010300000000", hex(GroupFrames.encode(decline)))
        XCTAssertEqual(position, GroupFrames.decode(bytes("1580000001ee6b28006ab13da620802dc2fe33b9a9fff40549042a033500")) as? PositionFrame)
    }

    func testSealedAdvertsMatchAndroidBothWays() throws {
        let keys = GroupKeys(GroupCode.generate(counting(from: 0x10)))
        let (position, sos, profile, range) = try frames()
        let android = "01c55412caa0a1a2a3a4a5a6a7a8a9aaab3c692f678b46dfd153aff42a322528928838df344583c9af3f772bbbaf0d90ba926dc67cbd84a9a9c1d3" +
            "acadaeafb0b1b2b3b4b5b6b7354a34883bee84eed3b665fbce72544c266f22d251e22b072539fe37c9d6bbde946bc9af66bf1bf15852b8b9babbbcbd" +
            "bebfc0c1c2c340a126037f60b16571197aa407b15359a35b6005ee9b373cbdc2f78cb9e78ab628a6e16800e5375de8ba"
        let advert = try GroupAdvert.build(keys, unixSeconds: time, frames: [position, profile, range], random: counting(from: 0xA0))
        XCTAssertEqual(android, hex(advert))
        // What an Android phone sent opens here, frame for frame (the name as it was cut to fit).
        let opened = try XCTUnwrap(GroupAdvert.open([keys], payload: bytes(android), unixSeconds: time))
        let cut = try ProfileFrame(memberId: -5, colour: 7, name: "Élodie the very long-n")
        XCTAssertEqual([AnyHashable(position), AnyHashable(cut), AnyHashable(range)], opened.frames.map { AnyHashable($0) })

        let androidSos = "01804c66ca000102030405060708090a0bccd1b8361028b76e2a35272c46d49007e277745aed9b497f2b9714c8d3131f61f2481855742bbcb1a5b4"
        XCTAssertEqual(androidSos, hex(try GroupAdvert.build(keys, unixSeconds: time + 900, frames: [sos], random: counting(from: 0))))
        let openedSos = try XCTUnwrap(GroupAdvert.open([keys], payload: bytes(androidSos), unixSeconds: time + 900))
        XCTAssertEqual([AnyHashable(sos)], openedSos.frames.map { AnyHashable($0) })
        // A 96-bit tag that is off by one bit is refused, as on Android.
        var forged = bytes(androidSos)
        forged[forged.count - 1] ^= 0x01
        XCTAssertNil(GroupAdvert.open([keys], payload: forged, unixSeconds: time + 900))
    }

    func testUwbSessionsMatchAndroid() {
        let keys = GroupKeys(GroupCode.generate(counting(from: 0x10)))
        let android: [(Int, Int, Int64, String)] = [
            (7, 9, 1234, "637742386 1fa1 c707 3709af8f6f1dc17a6071438a050f86a7 a7c3b8aefac1e237"),
            (9, 7, 1234, "807697939 436b f3e5 4ecba2be0c81e22ef7357b1ee0182917 9cd0a6d86843c58a"),
            (-5, Int(Int32.max), Int64.min, "2113742322 d68a 0ba9 8b6576f59918b968d8974ed22c230962 faf6ceaabf71ed63"),
        ]
        for (initiator, responder, nonce, expected) in android {
            let s = UwbSession.derive(keys, initiatorId: initiator, responderId: responder, nonce: nonce)
            let actual = "\(s.sessionId) \(hex(s.localAddress(initiator: true))) \(hex(s.localAddress(initiator: false))) " +
                "\(hex(s.keyFor(UwbSession.configProvisioned) ?? [])) \(hex(s.keyFor(UwbSession.configStatic) ?? []))"
            XCTAssertEqual(expected, actual)
        }
        // The first sessions GroupFindingTests.testSessionsAreAlwaysUsable derives, as Kotlin's Random(5) draws them.
        let drawn = [
            "-1350163013 -332731564 -4882580274371907140 586785832 8ccc e446",
            "-189288304 1337209992 -2405015570610186360 227700904 d4ca 2159",
            "-1252266077 -521060454 -3562978015852248234 1145679437 850c 8809",
        ]
        var random = KotlinRandom(seed: 5)
        for expected in drawn {
            let i = random.nextInt()
            let r = random.nextInt()
            let n = random.nextLong()
            let s = UwbSession.derive(keys, initiatorId: Int(i), responderId: Int(r), nonce: n)
            XCTAssertEqual(
                expected,
                "\(i) \(r) \(n) \(s.sessionId) \(hex(s.localAddress(initiator: true))) \(hex(s.localAddress(initiator: false)))"
            )
        }
    }

    func testTelemetryProtobufMatchesAndroid() throws {
        let payload = try GroupMeshPayload(
            gatewayDeviceId: "gate0001", messageSequence: 42, hikers: [try hiker("hiker001"), try hiker("hiker002", .injuredStationary)],
            fallTelemetry: FallVector(impactGForce: 5.2, freefallDurationSeconds: 0.8, deltaAltitudeMeters: -3.5)
        )
        let android = "0a086761746530303031102a1a270a0868696b6572303031115ddc460378434b4019363cbd52962108c020b50728493080f7c4d5061a2b0a08" +
            "68696b6572303032115ddc460378434b4019363cbd52962108c020b50728493080f7c4d5063803402a220f0d6666a64015cdcc4c3f1d000060c0"
        XCTAssertEqual(android, hex(try FrontierTelemetryCodec.encode(payload)))
        XCTAssertEqual(payload, try FrontierTelemetryCodec.decode(bytes(android)))

        let edge = try GroupMeshPayload(
            gatewayDeviceId: "Ünï€", messageSequence: Int64.max,
            hikers: [
                try HikerTelemetry(
                    hikerId: "é", latitude: -90.0, longitude: 180.0, altitudeMeters: -12, batteryPercent: 100, timestampEpochSeconds: 0,
                    status: .fallDetected, triageCode: 255
                ),
                try HikerTelemetry(
                    hikerId: "x", latitude: 0.0, longitude: -0.0, altitudeMeters: 0, batteryPercent: 0, timestampEpochSeconds: 4_000_000_000,
                    status: .ok, triageCode: 0
                ),
            ],
            fallTelemetry: FallVector(impactGForce: 0, freefallDurationSeconds: -0.0, deltaAltitudeMeters: -123.456)
        )
        let androidEdge = "0a08c39c6ec3afe282ac10ffffffffffffffff7f1a280a02c3a91100000000008056c019000000000080664020f4ffffffffffffffff0128" +
            "64380540ff011a090a01783080d0acf30e22051d79e9f6c2"
        XCTAssertEqual(androidEdge, hex(try FrontierTelemetryCodec.encode(edge)))
        XCTAssertEqual(edge, try FrontierTelemetryCodec.decode(bytes(androidEdge)))

        let hikers = try (1...8).map { try hiker("hiker" + String($0).padStart(3, "0"), $0 == 8 ? .criticalSos : .ok) }
        let packed = try FrontierTelemetryCodec.pack(try GroupMeshPayload(gatewayDeviceId: "gate0001", messageSequence: 1, hikers: hikers))
        let androidPacked = "0a08676174653030303110011a2b0a0868696b6572303038115ddc460378434b4019363cbd52962108c020b50728493080f7c4d50638064" +
            "02a1a270a0868696b6572303031115ddc460378434b4019363cbd52962108c020b50728493080f7c4d5061a270a0868696b6572303032115ddc46037843" +
            "4b4019363cbd52962108c020b50728493080f7c4d5061a270a0868696b6572303033115ddc460378434b4019363cbd52962108c020b50728493080f7c4d5" +
            "061a270a0868696b6572303034115ddc460378434b4019363cbd52962108c020b50728493080f7c4d506"
        XCTAssertEqual(androidPacked, hex(packed.bytes))
        XCTAssertEqual(["hiker008", "hiker001", "hiker002", "hiker003", "hiker004"], packed.includedHikerIds)
        XCTAssertEqual(["hiker005", "hiker006", "hiker007"], packed.omittedHikerIds)
    }

    func testSosTextsMatchAndroid() {
        let parkend = LatLon(51.7785, -2.5360)
        let texts: [(String, String)] = [
            (
                SosText.contact("Possible fall, no response", location: parkend, altitudeM: 170, time: "14:32", batteryPercent: 62),
                "SOS from TrailMind: Possible fall, no response at 14:32. Grid SO 6311 0900. " +
                    "https://www.openstreetmap.org/?mlat=51.77850&mlon=-2.53600 170 m. Battery 62%."
            ),
            (
                SosText.contact(
                    String(repeating: "Fell on the scree – ankle hurts, 3°C and windy ", count: 4), location: parkend, altitudeM: 850,
                    time: "2:32\u{202F}PM", batteryPercent: 7
                ),
                "SOS from TrailMind: Fell on the scree ankle hurts, 3 C and windy Fell on the scree ankle hu at 2:32 PM. " +
                    "Grid SO 6311 0900. 51.77850,-2.53600. 850 m. Battery 7%."
            ),
            (
                SosText.contact("I need help", location: nil, altitudeM: nil, time: "09:05", batteryPercent: -1),
                "SOS from TrailMind: I need help at 09:05. No GPS fix."
            ),
            (
                SosText.contact(
                    "Broken leg  near the cairn... ", location: parkend, altitudeM: nil, time: "10:00", batteryPercent: 100,
                    words: "///Filled.Count.Soap"
                ),
                "SOS from TrailMind: Broken leg near the cairn at 10:00. Grid SO 6311 0900. 51.77850,-2.53600. ///filled.count.soap. " +
                    "Battery 100%."
            ),
            (
                SosText.contact(
                    "Lost in fog, cold, wet, tired and the path has vanished completely near the summit plateau",
                    location: LatLon(56.796849, -5.003508), altitudeM: 1340, time: "16:45", batteryPercent: 3, words: "index.home.raft"
                ),
                "SOS from TrailMind: Lost in fog, cold, wet, tired and the path has vanis at 16:45. Grid NN 1667 7128. " +
                    "56.79685,-5.00351. ///index.home.raft. 1340 m. Battery 3%."
            ),
            (
                SosText.contact(
                    "Café crème 😀 e\u{0301} test\nnew line", location: LatLon(40.0, -3.7), altitudeM: 650, time: "12:00",
                    batteryPercent: 50, words: "café.über.straße"
                ),
                "SOS from TrailMind: Café crème e test new line at 12:00. 40.00000,-3.70000. ///café.über.straße. 650 m. Battery 50%."
            ),
            (
                SosText.contact(
                    "Ankle", location: LatLon(54.4541, -3.2117), altitudeM: -3, time: "07:15", batteryPercent: 101,
                    words: "ñandú.über.straße"
                ),
                "SOS from TrailMind: Ankle at 07:15. Grid NY 2153 0719. https://www.openstreetmap.org/?mlat=54.45410&mlon=-3.21170 -3 m."
            ),
            (
                SosText.emergency("Hiker fallen, injured", location: parkend, time: "14:32"),
                "Police, mountain rescue. Hiker fallen, injured. Grid SO 63117 09006, lat 51.77850 lon -2.53600. Time 14:32."
            ),
            (
                SosText.emergency("Hiker fallen, injured...", location: parkend, time: "14:32", words: "filled.count.soap"),
                "Police, mountain rescue. Hiker fallen, injured. Grid SO 63117 09006, lat 51.77850 lon -2.53600. " +
                    "what3words ///filled.count.soap. Time 14:32."
            ),
            (
                SosText.emergency("  Lost  ", location: nil, time: "9:00 PM", words: "filled.count.soap"),
                "Police, mountain rescue. Lost. location unknown. Time 9:00 PM."
            ),
        ]
        for (actual, android) in texts {
            XCTAssertEqual(Array(android.unicodeScalars), Array(actual.unicodeScalars), actual)
        }
    }

    /// The position, SOS, profile and range frames the Android vectors were made from.
    private func frames() throws -> (PositionFrame, PositionFrame, ProfileFrame, RangeFrame) {
        let position = try PositionFrame.of(
            memberId: Int(Int32(bitPattern: 0x8000_0001)), sequence: 4_000_000_000, originTimeS: time, lat: 54.5271234, lon: -3.0164567,
            altitudeM: -12.5, accuracyM: 4.5, batteryPercent: 73, status: .injuredMoving, triageCode: 42, capabilities: 0x35, flags: 5
        )
        let sos = try PositionFrame.of(
            memberId: 7, sequence: 1, originTimeS: 1, lat: -89.9999999, lon: 179.9999999, altitudeM: nil, accuracyM: 999,
            batteryPercent: 150, status: .criticalSos
        )
        let profile = try ProfileFrame(memberId: -5, colour: 7, name: "  Élodie the very long-named hiker 🏔 ")
        let range = try RangeFrame(
            memberId: 0x11223344, targetId: -5, kind: RangeFrame.request, nonce: Int64.min + 7, timeS: 0xFFFF_FFF0,
            configId: UwbSession.configProvisioned, channel: 9, preambleIndex: 11, updateRate: 1
        )
        return (position, sos, profile, range)
    }

    private func hiker(_ id: String, _ status: EmergencyStatus = .ok) throws -> HikerTelemetry {
        try HikerTelemetry(
            hikerId: id, latitude: 54.5271, longitude: -3.0164, altitudeMeters: 949, batteryPercent: 73,
            timestampEpochSeconds: 1_790_000_000, status: status, triageCode: status == .ok ? 0 : 42
        )
    }

    /// The `SecureRandom` the vectors were made with: bytes counting up from `start`, wrapping at 256.
    private func counting(from start: Int) -> SecureRandom {
        var next = start
        return SecureRandom { count in
            defer { next += count }
            return (0..<count).map { UInt8(truncatingIfNeeded: next + $0) }
        }
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }

    private func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
    }
}
