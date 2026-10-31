import Foundation

/// One step of finding a member up close with UWB, sealed in the group's adverts like every other frame. UWB reaches
/// only tens of metres, so these go between phones in direct Bluetooth range and are never passed on.
struct RangeFrame: GroupFrame {
    /// From the finder: start answering UWB with these settings.
    static let request = 1
    /// From the member being found: answering now.
    static let accept = 2
    /// From either phone: the session is over.
    static let stop = 3
    /// From the member being found: can't answer, see `reason`.
    static let decline = 4

    static let reasonNotAllowed = 1
    static let reasonUwbOff = 2
    static let reasonBusy = 3
    static let reasonUnsupported = 4
    static let reasonFailed = 5

    var memberId: Int
    /// The member this is for.
    var targetId: Int
    var kind: Int
    /// Chosen by the finder; picks the session's keys and addresses, and ties every later frame to this request.
    var nonce: Int64
    var timeS: Int64
    var configId: Int
    var channel: Int
    var preambleIndex: Int
    var updateRate: Int
    var reason: Int

    init(
        memberId: Int, targetId: Int, kind: Int, nonce: Int64, timeS: Int64, configId: Int = 0, channel: Int = 0,
        preambleIndex: Int = 0, updateRate: Int = 0, reason: Int = 0
    ) throws {
        try FrontierError.require((RangeFrame.request...RangeFrame.decline).contains(kind), "unknown range frame kind \(kind)")
        try FrontierError.require((0...0xFFFF_FFFF).contains(timeS), "time out of range")
        try FrontierError.require(
            [configId, channel, preambleIndex, updateRate, reason].allSatisfy { (0...255).contains($0) }, "byte field out of range"
        )
        self.memberId = memberId
        self.targetId = targetId
        self.kind = kind
        self.nonce = nonce
        self.timeS = timeS
        self.configId = configId
        self.channel = channel
        self.preambleIndex = preambleIndex
        self.updateRate = updateRate
        self.reason = reason
    }

    var hops: Int { 0 }
    var ttl: Int { 0 }

    func relayed() -> (any GroupFrame)? { nil }
}

/// What both phones need for one UWB session, worked out on each phone from the group's key, the two members and the
/// finder's nonce, so none of it goes over the air. Nobody without the group code can join, spoof or follow the session.
struct UwbSession {
    /// Android's UwbRangingParams.CONFIG_PROVISIONED_UNICAST_DS_TWR: resists replay and relay attacks.
    static let configProvisioned = 3
    /// Android's UwbRangingParams.CONFIG_UNICAST_DS_TWR, for phones without provisioned STS.
    static let configStatic = 1
    static let channel = 9
    /// The preamble codes every FiRa phone supports on channel 9 at the base pulse rate.
    static let preambles = [9, 10, 11, 12]

    /// FiRa session id: positive and never 0.
    let sessionId: Int
    /// Two-byte UWB short addresses, never 0x0000 or the 0xFFFF broadcast, and never the same.
    let initiatorAddress: [UInt8]
    let responderAddress: [UInt8]
    /// Session key for provisioned STS (`configProvisioned`).
    let provisionedKey: [UInt8]
    /// Vendor id then static STS IV, for static STS (`configStatic`).
    let staticKey: [UInt8]

    private init(sessionId: Int, initiatorAddress: [UInt8], responderAddress: [UInt8], provisionedKey: [UInt8], staticKey: [UInt8]) {
        self.sessionId = sessionId
        self.initiatorAddress = initiatorAddress
        self.responderAddress = responderAddress
        self.provisionedKey = provisionedKey
        self.staticKey = staticKey
    }

    func localAddress(initiator: Bool) -> [UInt8] { initiator ? initiatorAddress : responderAddress }
    func peerAddress(initiator: Bool) -> [UInt8] { initiator ? responderAddress : initiatorAddress }

    /// The key `configId` needs, or nil for a configuration TrailMind doesn't use.
    func keyFor(_ configId: Int) -> [UInt8]? {
        switch configId {
        case UwbSession.configProvisioned: return provisionedKey
        case UwbSession.configStatic: return staticKey
        default: return nil
        }
    }

    static func derive(_ keys: GroupKeys, initiatorId: Int, responderId: Int, nonce: Int64) -> UwbSession {
        var info = GroupByteWriter(count: 7 + 16)
        info.put(Array("session".utf8))
        info.putInt(initiatorId)
        info.putInt(responderId)
        info.putLong(nonce)
        var okm = GroupByteReader(Hkdf.expand(keys.uwbKey, info.bytes, 4 + 2 + 2 + 16 + 8))
        var sessionId = okm.getInt() & 0x7FFF_FFFF
        if sessionId == 0 { sessionId = 1 }
        let initiator = usable(okm.getShort() & 0xFFFF)
        var responder = usable(okm.getShort() & 0xFFFF)
        if responder == initiator { responder = usable(responder ^ 0x8000) }
        let provisioned = okm.get(16)
        var staticKey = okm.get(8)
        if staticKey[0] == 0 && staticKey[1] == 0 { staticKey[1] = 1 }
        return UwbSession(
            sessionId: sessionId, initiatorAddress: address(initiator), responderAddress: address(responder),
            provisionedKey: provisioned, staticKey: staticKey
        )
    }

    private static func usable(_ a: Int) -> Int {
        switch a {
        case 0x0000: return 0x0001
        case 0xFFFF: return 0xFFFE
        default: return a
        }
    }

    private static func address(_ a: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: a >> 8), UInt8(truncatingIfNeeded: a)] }
}
