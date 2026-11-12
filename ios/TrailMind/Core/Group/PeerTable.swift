import Foundation

/// What this phone knows about each other member of its trip group, merged from direct and relayed frames.
final class PeerTable {
    enum Freshness { case fresh, stale, lastSeen }
    enum Result { case new, newer, same, older, rejected }

    struct Peer: Hashable {
        var memberId: Int
        var name: String? = nil
        var colour: Int? = nil
        var position: PositionFrame? = nil
        /// When this phone first got `position` (phone clock, ms).
        var positionReceivedMs: Int64 = 0
        /// When anything was last heard from or about this member, direct or relayed.
        var lastHeardMs: Int64 = 0
        /// When this phone last heard the member's own phone rather than a relay.
        var lastDirectMs: Int64 = 0
        /// Signal strength of the last direct frame, dBm.
        var rssi: Int? = nil
        /// Whether the last direct frame came on LE Coded (long range).
        var coded: Bool = false
    }

    static let futureToleranceS: Int64 = 300
    static let freshS: Int64 = 120
    static let staleS: Int64 = 900

    private let ownMemberId: Int
    /// Kotlin's `LinkedHashMap`: peers in the order they were first heard.
    private var byId: [Int: Peer] = [:]
    private var order: [Int] = []
    private let lock = NSLock()

    init(ownMemberId: Int) { self.ownMemberId = ownMemberId }

    func peers() -> [Peer] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { byId[$0] }
    }

    func peer(_ memberId: Int) -> Peer? {
        lock.lock()
        defer { lock.unlock() }
        return byId[memberId]
    }

    func restore(_ peer: Peer) {
        lock.lock()
        defer { lock.unlock() }
        if peer.memberId != ownMemberId { put(peer) }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        byId.removeAll()
        order.removeAll()
    }

    /// Merges `frame`, heard at `receivedMs` with `rssi` dBm, and says how it compared with what was known.
    func accept(_ frame: any GroupFrame, receivedMs: Int64, nowS: Int64, rssi: Int, coded: Bool) -> Result {
        lock.lock()
        defer { lock.unlock() }
        if frame.memberId == ownMemberId { return .rejected }
        if let position = frame as? PositionFrame, position.originTimeS > nowS + PeerTable.futureToleranceS { return .rejected }
        let old = byId[frame.memberId] ?? Peer(memberId: frame.memberId)
        let direct = frame.hops == 0
        var heard = old
        heard.lastHeardMs = receivedMs
        heard.lastDirectMs = direct ? receivedMs : old.lastDirectMs
        heard.rssi = direct ? rssi : old.rssi
        heard.coded = direct ? coded : old.coded
        switch frame {
        // Only says the member's phone is in range; what it asks is for GroupFinder.
        case is RangeFrame:
            put(heard)
            return .same
        case let frame as ProfileFrame:
            let same = old.name == frame.name && old.colour == frame.colour
            heard.name = frame.name
            heard.colour = frame.colour
            put(heard)
            return same ? .same : .new
        case let frame as PositionFrame:
            let cur = old.position
            let comparison = cur.map { PeerTable.compare(frame, $0) } ?? 1
            if comparison > 0 {
                heard.position = frame
                heard.positionReceivedMs = receivedMs
                put(heard)
                return cur == nil ? .new : .newer
            } else if comparison == 0 {
                // A copy with fewer hops replaces a relayed one, so the map can show it as direct.
                if let cur, frame.hops < cur.hops { heard.position = frame }
                put(heard)
                return .same
            } else {
                put(heard)
                return .older
            }
        default:
            return .rejected
        }
    }

    /// Kotlin's `LinkedHashMap.put`: a new member goes last, a known one keeps its place.
    private func put(_ peer: Peer) {
        if byId.updateValue(peer, forKey: peer.memberId) == nil { order.append(peer.memberId) }
    }

    /// `compareValuesBy(a, b, { it.originTimeS }, { it.sequence })`.
    private static func compare(_ a: PositionFrame, _ b: PositionFrame) -> Int {
        if a.originTimeS != b.originTimeS { return a.originTimeS < b.originTimeS ? -1 : 1 }
        if a.sequence != b.sequence { return a.sequence < b.sequence ? -1 : 1 }
        return 0
    }

    static func freshness(_ position: PositionFrame, nowS: Int64) -> Freshness {
        let age = nowS - position.originTimeS
        if age <= freshS { return .fresh }
        if age <= staleS { return .stale }
        return .lastSeen
    }
}

/// Chooses which frames heard from other members this phone passes on, so a member out of someone's range can still
/// reach them through a phone in between. Each frame is passed on for a minute after it first arrives (five for a call
/// for help), a few at a time: calls for help first, then whichever was sent longest ago.
final class RelayPolicy {
    static let maxAgeS: Int64 = 600
    static let helpMaxAgeS: Int64 = 3600

    private final class Candidate {
        let frame: any GroupFrame
        let firstSeenMs: Int64
        var lastSentMs: Int64 = 0

        init(_ frame: any GroupFrame, _ firstSeenMs: Int64) {
            self.frame = frame
            self.firstSeenMs = firstSeenMs
        }
    }

    private let windowMs: Int64
    private let helpWindowMs: Int64
    /// Kotlin's `LinkedHashMap`: candidates in the order their member and kind were first offered.
    private var candidates: [Int64: Candidate] = [:]
    private var order: [Int64] = []
    private let lock = NSLock()

    init(windowMs: Int64 = 60_000, helpWindowMs: Int64 = 300_000) {
        self.windowMs = windowMs
        self.helpWindowMs = helpWindowMs
    }

    /// Offers a frame this phone accepted as new, or as the same news with fewer hops.
    func offer(_ frame: any GroupFrame, receivedMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let next = frame.relayed() else { return }
        let key = RelayPolicy.key(frame)
        if let existing = candidates[key], RelayPolicy.sameNews(existing.frame, next) {
            if existing.frame.ttl < next.ttl { put(key, Candidate(next, existing.firstSeenMs)) }
            return
        }
        put(key, Candidate(next, receivedMs))
    }

    func pick(nowMs: Int64, nowS: Int64, max: Int, helpOnly: Bool) -> [any GroupFrame] {
        lock.lock()
        defer { lock.unlock() }
        order = order.filter { key in
            guard let candidate = candidates[key], expired(candidate, nowMs, nowS) else { return true }
            candidates[key] = nil
            return false
        }
        if max <= 0 { return [] }
        let eligible = order.compactMap { candidates[$0] }.filter { !helpOnly || $0.frame.needsHelp }
        let chosen = FrontierCompat.stableSorted(eligible) { a, b in
            if a.frame.needsHelp != b.frame.needsHelp { return a.frame.needsHelp }
            return a.lastSentMs < b.lastSentMs
        }.prefix(max)
        for candidate in chosen { candidate.lastSentMs = nowMs }
        return chosen.map(\.frame)
    }

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return candidates.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        candidates.removeAll()
        order.removeAll()
    }

    /// Kotlin's `LinkedHashMap.put`: a new key goes last, a known one keeps its place.
    private func put(_ key: Int64, _ candidate: Candidate) {
        if candidates.updateValue(candidate, forKey: key) == nil { order.append(key) }
    }

    private static func key(_ f: any GroupFrame) -> Int64 {
        (Int64(UInt32(truncatingIfNeeded: f.memberId)) << 2) | (f is PositionFrame ? 1 : 2)
    }

    private static func sameNews(_ a: any GroupFrame, _ b: any GroupFrame) -> Bool {
        if let a = a as? PositionFrame, let b = b as? PositionFrame { return a.sequence == b.sequence && a.originTimeS == b.originTimeS }
        if let a = a as? ProfileFrame, let b = b as? ProfileFrame { return a.name == b.name && a.colour == b.colour }
        return false
    }

    private func expired(_ c: Candidate, _ nowMs: Int64, _ nowS: Int64) -> Bool {
        let help = c.frame.needsHelp
        if nowMs - c.firstSeenMs > (help ? helpWindowMs : windowMs) { return true }
        guard let f = c.frame as? PositionFrame else { return false }
        return nowS - f.originTimeS > (help ? RelayPolicy.helpMaxAgeS : RelayPolicy.maxAgeS)
    }
}
