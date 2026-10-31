import Foundation

/// Decides when this phone should offer to record the hike another member of the trip group is recording, so that
/// everyone in the group ends up with their own log of it.
///
/// A member's position frames say what they're doing: `GroupFrames.flagRecording` with `GroupFrames.flagGroupHike`
/// means they are recording a hike for the group. `next` returns such a member once, so the phone can start
/// recording or ask. Whatever was decided, that member isn't offered again until their hike has ended, which shows
/// as a frame with neither `GroupFrames.flagRecording` nor `GroupFrames.flagPaused` set. A paused hike still counts as
/// under way, so someone stopping for lunch (or in the car park) doesn't make a finished hike come back.
final class GroupHikeWatch {
    private let freshS: Int64
    private let handledMaxMs: Int64
    private var handled: [Int: Int64] = [:]
    private let lock = NSLock()

    init(freshS: Int64 = PeerTable.freshS, handledMaxMs: Int64 = 24 * 3_600_000) {
        self.freshS = freshS
        self.handledMaxMs = handledMaxMs
    }

    /// The member whose group hike should be offered now, or nil. Each hike is returned once.
    func next(_ peers: [PeerTable.Peer], nowS: Int64, nowMs: Int64) -> PeerTable.Peer? {
        lock.lock()
        defer { lock.unlock() }
        var best: PeerTable.Peer? = nil
        for peer in peers {
            guard let position = peer.position else { continue }
            if position.flags & (GroupFrames.flagRecording | GroupFrames.flagPaused) == 0 {
                handled[peer.memberId] = nil
                continue
            }
            if let handledMs = handled[peer.memberId] {
                if nowMs - handledMs <= handledMaxMs { continue }
                handled[peer.memberId] = nil
            }
            if !GroupHikeWatch.isGroupHike(position) || nowS - position.originTimeS > freshS { continue }
            if best == nil || position.originTimeS > best!.position!.originTimeS { best = peer }
        }
        if let best { handled[best.memberId] = nowMs }
        return best
    }

    /// This phone has finished its own hike: the group hikes still going on are not offered back.
    func handleAll(_ peers: [PeerTable.Peer], nowMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        for peer in peers {
            guard let position = peer.position else { continue }
            if position.flags & (GroupFrames.flagRecording | GroupFrames.flagPaused) != 0 { handled[peer.memberId] = nowMs }
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        handled.removeAll()
    }

    /// Lets `memberId`'s hike be offered again, when an offer couldn't be made.
    func forget(_ memberId: Int) {
        lock.lock()
        defer { lock.unlock() }
        handled[memberId] = nil
    }

    /// Recording, and recording for the group.
    static func isGroupHike(_ position: PositionFrame) -> Bool {
        position.flags & GroupFrames.flagRecording != 0 && position.flags & GroupFrames.flagGroupHike != 0
    }
}
