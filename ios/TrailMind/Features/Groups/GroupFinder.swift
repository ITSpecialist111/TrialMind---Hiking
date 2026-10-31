import Combine
import Foundation
import NearbyInteraction
import simd

/// What the finder needs from the trip group (GroupFinder.Host).
protocol GroupFinderHost: AnyObject {
    var tripGroup: TripGroup? { get }
    func nowS() -> Int64
    func peer(_ memberId: Int) -> PeerTable.Peer?
    func inRange(_ peer: PeerTable.Peer) -> Bool
    func nameOf(_ peer: PeerTable.Peer) -> String
    /// The member's iPhone is connected over the iPhone link now.
    func hasLink(to memberId: Int) -> Bool
    /// Seals `message` for the group and sends it to its target's iPhone; false if it couldn't go.
    func sendToken(_ message: GroupTokenMessage) -> Bool
    /// What this phone advertises changed: the next adverts must carry it.
    func finderChanged()
}

/// Finding one member up close with UWB (frontier/group/GroupFinder.kt), between iPhones with Nearby Interaction.
/// The finder asks in the group's sealed adverts and the other iPhone answers there, exactly as on Android; each also
/// sends its Nearby Interaction discovery token, sealed for the group, over the iPhone link, because Nearby
/// Interaction needs the two phones to swap tokens. Both iPhones need TrailMind open: iOS suspends Nearby Interaction
/// in the background. iPhones can't range with Android phones (their UWB sessions are set up differently), and
/// direction needs an iPhone that reports it.
final class GroupFinder: NSObject, ObservableObject, NISessionDelegate {
    enum Role { case finding, found }
    enum Phase { case asking, starting, ranging, ended }

    struct Measurement: Equatable {
        var distanceM: Double?
        var azimuthDeg: Double?
        var elevationDeg: Double?
    }

    struct State: Equatable {
        var role: Role
        var memberId: Int
        var nonce: Int64
        var phase: Phase
        var startedMs: Int64
        /// Why it ended, or what is wrong while it runs.
        var note: String? = nil
        var measurement: Measurement? = nil
        /// When `measurement` arrived (system uptime, seconds), 0 before the first.
        var measuredAt: TimeInterval = 0

        var active: Bool { phase != .ended }
    }

    static let maxSessionMs: Int64 = 15 * 60_000
    /// A measurement older than this is shown faded.
    static let staleS: TimeInterval = 3
    private static let askMs: Int64 = 30_000
    /// How long the found phone waits for the finder's first measurement, or for the next after one.
    private static let foundWaitMs: Int64 = 60_000
    private static let acceptRepeatMs: Int64 = 20_000
    private static let stopRepeatMs: Int64 = 6_000
    private static let retryS: TimeInterval = 3
    private static let maxRetries = 100
    private static let resultPublishS: TimeInterval = 0.2
    private static let handledMs: Int64 = 10 * 60_000
    private static let maxRequestAgeS: Int64 = 120
    /// iPhone only: a request waits this long for its finder's token, and the finder re-sends its token this often.
    private static let tokenWaitMs: Int64 = 20_000
    private static let tokenResendMs: Int64 = 5_000

    weak var host: GroupFinderHost?

    private(set) var state: State?
    /// What the last one-phone test found, for the diagnostics page.
    private(set) var selfTest: String?

    private var request: RangeFrame?
    private var reply: RangeFrame?
    private var replyUntilMs: Int64 = 0
    /// Requests already answered or ended, so repeats of their adverts are ignored.
    private var handled: [Int64: Int64] = [:]
    private var session: NISession?
    private var configuration: NINearbyPeerConfiguration?
    private var retries = 0
    private var lastPublish: TimeInterval = 0
    private var retryWork: DispatchWorkItem?
    /// Tokens that came over the iPhone link, by find nonce, until their request or answer arrives.
    private var tokens: [Int64: (from: Int, token: NIDiscoveryToken, atMs: Int64)] = [:]
    /// Requests that came before their finder's token.
    private var waiting: [Int64: (frame: RangeFrame, atMs: Int64)] = [:]
    /// The finder's own token for the find in progress, re-sent while it asks.
    private var myToken: [UInt8]?
    private var tokenSentMs: Int64 = 0

    /// This iPhone can measure distance with UWB.
    static var supported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    /// This iPhone reports which way the other phone is.
    static var direction: Bool { NISession.deviceCapabilities.supportsDirectionMeasurement }

    var active: Bool { state?.active == true }
    /// A find is running, or its last Stop or Decline is still going out: the link must stay up.
    var needsRadio: Bool { active || (reply != nil && nowMs() < replyUntilMs) }

    /// Whether this phone could find `peer` now: both iPhones have UWB and it is connected over the iPhone link.
    func canFind(_ peer: PeerTable.Peer) -> Bool {
        guard let host, GroupFinder.supported else { return false }
        return host.inRange(peer) && (peer.position?.capabilities ?? 0) & GroupIPhone.capNearbyInteraction != 0 &&
            host.hasLink(to: peer.memberId)
    }

    /// The capability bits this phone's position frames carry.
    func capabilityBits() -> Int {
        Prefs.shared.groupUwbFindable && GroupFinder.supported ? GroupIPhone.capNearbyInteraction : 0
    }

    /// The frame to add to this phone's adverts, if any.
    func outgoing() -> RangeFrame? {
        if reply != nil && nowMs() >= replyUntilMs { reply = nil }
        return reply ?? request
    }

    func find(_ memberId: Int) {
        guard let host, let g = host.tripGroup, let peer = host.peer(memberId) else { return }
        if active { end(nil, tellPeer: true) }
        let now = nowMs()
        let nonce = Int64.random(in: Int64.min...Int64.max)
        guard GroupFinder.supported else {
            setState(State(role: .finding, memberId: memberId, nonce: nonce, phase: .ended, startedMs: now,
                           note: "This iPhone has no UWB that apps can use."))
            return
        }
        guard (peer.position?.capabilities ?? 0) & GroupIPhone.capNearbyInteraction != 0, host.hasLink(to: memberId) else {
            setState(State(role: .finding, memberId: memberId, nonce: nonce, phase: .ended, startedMs: now,
                           note: "\(host.nameOf(peer))'s phone needs to be an iPhone with UWB, in range with TrailMind open."))
            return
        }
        let s = newSession()
        guard let token = s.discoveryToken, let data = archive(token),
              let frame = try? RangeFrame(memberId: g.memberId, targetId: memberId, kind: RangeFrame.request, nonce: nonce,
                                          timeS: host.nowS(), configId: GroupIPhone.configNearbyInteraction) else {
            s.invalidate()
            setState(State(role: .finding, memberId: memberId, nonce: nonce, phase: .ended, startedMs: now,
                           note: "UWB wouldn't start on this phone."))
            return
        }
        session = s
        configuration = nil
        retries = 0
        request = frame
        reply = nil
        myToken = data
        sendMyToken(kind: GroupTokenMessage.fromFinder, to: memberId, nonce: nonce)
        setState(State(role: .finding, memberId: memberId, nonce: nonce, phase: .asking, startedMs: now))
        host.finderChanged()
    }

    func stop() {
        end(state?.role == .found ? "You stopped it." : "Stopped.", tellPeer: true)
    }

    /// Leaving the group: stop at once, with no one left to tell.
    func leave() {
        cancelRetry()
        session?.invalidate()
        session = nil
        configuration = nil
        request = nil
        reply = nil
        myToken = nil
        tokens.removeAll()
        waiting.removeAll()
        setState(nil)
    }

    /// Starts Nearby Interaction on this phone alone, to show whether it can: no second phone, nothing sent.
    func runSelfTest() {
        guard host?.tripGroup != nil, !active else { return }
        let caps = NISession.deviceCapabilities
        guard caps.supportsPreciseDistanceMeasurement else {
            selfTest = "This iPhone has no UWB that apps can use."
            publish()
            return
        }
        let s = NISession()
        selfTest = s.discoveryToken != nil
            ? "Nearby Interaction started on this iPhone: distance yes, direction \(caps.supportsDirectionMeasurement ? "yes" : "no (distance only)"). A find needs a second iPhone with TrailMind open."
            : "Nearby Interaction didn't start on this iPhone."
        s.invalidate()
        publish()
    }

    // MARK: Frames and tokens from the group

    func onFrame(_ frame: RangeFrame) {
        guard let g = host?.tripGroup, frame.targetId == g.memberId else { return }
        let s = state
        let ours = s.map { $0.active && $0.memberId == frame.memberId && $0.nonce == frame.nonce } ?? false
        switch frame.kind {
        case RangeFrame.request:
            answer(g, frame)
        case RangeFrame.accept:
            if ours, let s, s.role == .finding, s.phase == .asking { startInitiator(s) }
        case RangeFrame.decline:
            if ours, let s, s.role == .finding { end(GroupText.declined(frame.reason), tellPeer: false) }
        case RangeFrame.stop:
            if ours, let s {
                end(s.role == .finding ? "\(name(s.memberId)) stopped it on their phone." : "\(name(s.memberId)) stopped finding you.",
                    tellPeer: false)
            }
        default:
            break
        }
    }

    func onToken(_ message: GroupTokenMessage) {
        guard let token = unarchive(message.token), let g = host?.tripGroup else { return }
        tokens[message.nonce] = (message.memberId, token, nowMs())
        if message.kind == GroupTokenMessage.fromFinder, let w = waiting.removeValue(forKey: message.nonce) {
            answer(g, w.frame)
        } else if message.kind == GroupTokenMessage.fromFound, let s = state, s.active, s.role == .finding,
                  s.memberId == message.memberId, s.nonce == message.nonce, s.phase == .asking, accepted.contains(s.nonce) {
            startInitiator(s)
        }
    }

    /// Finds whose Accept has arrived (the finder may still be waiting for the token that goes with it).
    private var accepted = Set<Int64>()

    func tick() {
        let now = nowMs()
        handled = handled.filter { now - $0.value <= GroupFinder.handledMs }
        tokens = tokens.filter { now - $0.value.atMs <= GroupFinder.handledMs }
        waiting = waiting.filter { now - $0.value.atMs <= GroupFinder.tokenWaitMs }
        guard let s = state, s.active else { return }
        let quietS = uptime() - s.measuredAt
        if s.role == .finding && s.phase == .asking && now - s.startedMs > GroupFinder.askMs {
            end("No answer from \(name(s.memberId))'s phone. It needs TrailMind open on screen, with UWB finding allowed.", tellPeer: true)
        } else if s.role == .found && s.measuredAt == 0 && now - s.startedMs > GroupFinder.foundWaitMs {
            end("\(name(s.memberId))'s phone didn't start UWB.", tellPeer: true)
        } else if s.role == .found && s.measuredAt > 0 && quietS * 1_000 > Double(GroupFinder.foundWaitMs) {
            end("Lost touch with \(name(s.memberId))'s phone.", tellPeer: true)
        } else if now - s.startedMs > GroupFinder.maxSessionMs {
            end("Stopped after \(GroupFinder.maxSessionMs / 60_000) minutes to save battery.", tellPeer: true)
        } else if s.role == .finding && s.phase == .asking && now - tokenSentMs >= GroupFinder.tokenResendMs {
            sendMyToken(kind: GroupTokenMessage.fromFinder, to: s.memberId, nonce: s.nonce)
        }
    }

    // MARK: Internals

    private func answer(_ g: TripGroup, _ f: RangeFrame) {
        guard let host else { return }
        if abs(host.nowS() - f.timeS) > GroupFinder.maxRequestAgeS || handled[f.nonce] != nil { return }
        if let s = state, s.active {
            if s.role == .found && s.memberId == f.memberId && s.nonce == f.nonce { return }
            decline(g, f, RangeFrame.reasonBusy)
            return
        }
        if !Prefs.shared.groupUwbFindable { return decline(g, f, RangeFrame.reasonNotAllowed) }
        if !GroupFinder.supported || f.configId != GroupIPhone.configNearbyInteraction {
            return decline(g, f, RangeFrame.reasonUnsupported)
        }
        guard let theirs = tokens[f.nonce], theirs.from == f.memberId else {
            // The finder's token is on its way over the iPhone link.
            if waiting[f.nonce] == nil { waiting[f.nonce] = (f, nowMs()) }
            return
        }
        let s = newSession()
        guard let mine = s.discoveryToken, let data = archive(mine) else {
            s.invalidate()
            return decline(g, f, RangeFrame.reasonFailed)
        }
        cancelRetry()
        handled[f.nonce] = nowMs()
        let config = NINearbyPeerConfiguration(peerToken: theirs.token)
        session = s
        configuration = config
        retries = 0
        myToken = data
        s.run(config)
        sendMyToken(kind: GroupTokenMessage.fromFound, to: f.memberId, nonce: f.nonce)
        setState(State(role: .found, memberId: f.memberId, nonce: f.nonce, phase: .starting, startedMs: nowMs()))
        if let accept = try? RangeFrame(memberId: g.memberId, targetId: f.memberId, kind: RangeFrame.accept, nonce: f.nonce, timeS: host.nowS()) {
            send(accept, forMs: GroupFinder.acceptRepeatMs)
        }
    }

    private func startInitiator(_ s: State) {
        accepted.insert(s.nonce)
        // Accept can come before the token that goes with it.
        guard let theirs = tokens[s.nonce], theirs.from == s.memberId, let session else { return }
        accepted.remove(s.nonce)
        request = nil
        let config = NINearbyPeerConfiguration(peerToken: theirs.token)
        configuration = config
        handled[s.nonce] = nowMs()
        session.run(config)
        var next = s
        next.phase = .starting
        setState(next)
    }

    private func restartSession() {
        guard let s = state, s.active, let session, let configuration else { return }
        session.run(configuration)
    }

    private func end(_ note: String?, tellPeer: Bool) {
        cancelRetry()
        guard var s = state, s.active else { return }
        session?.invalidate()
        session = nil
        configuration = nil
        request = nil
        myToken = nil
        accepted.remove(s.nonce)
        if tellPeer, let g = host?.tripGroup, let host,
           let stop = try? RangeFrame(memberId: g.memberId, targetId: s.memberId, kind: RangeFrame.stop, nonce: s.nonce, timeS: host.nowS()) {
            send(stop, forMs: GroupFinder.stopRepeatMs)
        }
        handled[s.nonce] = nowMs()
        tokens[s.nonce] = nil
        s.phase = .ended
        s.note = note
        setState(s)
        host?.finderChanged()
    }

    private func decline(_ g: TripGroup, _ f: RangeFrame, _ reason: Int) {
        handled[f.nonce] = nowMs()
        guard let host, let frame = try? RangeFrame(memberId: g.memberId, targetId: f.memberId, kind: RangeFrame.decline,
                                                      nonce: f.nonce, timeS: host.nowS(), reason: reason) else { return }
        send(frame, forMs: GroupFinder.stopRepeatMs)
    }

    private func send(_ frame: RangeFrame, forMs: Int64) {
        reply = frame
        replyUntilMs = nowMs() + forMs
        host?.finderChanged()
    }

    private func sendMyToken(kind: Int, to memberId: Int, nonce: Int64) {
        guard let host, let g = host.tripGroup, let token = myToken else { return }
        tokenSentMs = nowMs()
        _ = host.sendToken(GroupTokenMessage(kind: kind, memberId: g.memberId, targetId: memberId, nonce: nonce, token: token))
    }

    private func newSession() -> NISession {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = .main
        return s
    }

    private func scheduleRetry() {
        cancelRetry()
        let work = DispatchWorkItem { [weak self] in self?.restartSession() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GroupFinder.retryS, execute: work)
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
    }

    private func setState(_ s: State?) {
        state = s
        publish()
    }

    private func publish() {
        lastPublish = uptime()
        objectWillChange.send()
    }

    private func name(_ memberId: Int) -> String {
        if let host, let peer = host.peer(memberId) { return host.nameOf(peer) }
        return GroupText.name(nil, memberId: memberId)
    }

    private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func archive(_ token: NIDiscoveryToken) -> [UInt8]? {
        (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)).map { [UInt8]($0) }
    }

    private func unarchive(_ bytes: [UInt8]) -> NIDiscoveryToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: Data(bytes))
    }

    private func reasonText(_ reason: NINearbyObject.RemovalReason) -> String {
        switch reason {
        case .timeout: return "no reply"
        case .peerEnded: return "stopped by the other phone"
        @unknown default: return "error \(reason.rawValue)"
        }
    }

    private func errorText(_ error: Error) -> String {
        guard let ni = error as? NIError else { return error.localizedDescription }
        switch ni.code {
        case .unsupportedPlatform: return "this iPhone has no UWB that apps can use"
        case .userDidNotAllow: return "Nearby Interaction isn't allowed for TrailMind (Settings > TrailMind)"
        case .invalidConfiguration: return "settings not supported"
        case .resourceUsageTimeout: return "it was paused too long"
        case .activeSessionsLimitExceeded: return "too many UWB sessions at once"
        default: return error.localizedDescription
        }
    }

    // MARK: NISessionDelegate

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard session === self.session, var s = state, s.active, let object = nearbyObjects.first else { return }
        retries = 0
        var azimuth: Double? = nil
        var elevation: Double? = nil
        if let d = object.direction {
            // Device axes: x to the right, y up; the phone held upright facing the way you walk.
            azimuth = toDegrees(Double(asin(d.x.clamped(-1, 1))))
            elevation = toDegrees(Double(asin(d.y.clamped(-1, 1))))
        } else if let h = object.horizontalAngle {
            azimuth = toDegrees(Double(h))
        }
        let wasRanging = s.phase == .ranging && s.note == nil
        s.phase = .ranging
        s.note = nil
        s.measurement = Measurement(distanceM: object.distance.map { Double($0) }, azimuthDeg: azimuth, elevationDeg: elevation)
        s.measuredAt = uptime()
        state = s
        // Results come several times a second; the pages needn't redraw that often.
        if !wasRanging || uptime() - lastPublish >= GroupFinder.resultPublishS { publish() }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard session === self.session, var s = state, s.active else { return }
        let byPeer = reason == .peerEnded
        // A finder keeps trying while its user waits; the found phone only waits for a finder that hasn't started.
        let again = !byPeer && retries < GroupFinder.maxRetries && (s.role == .finding || s.measuredAt == 0)
        if again {
            retries += 1
            s.phase = .starting
            s.note = "No UWB reply yet (\(reasonText(reason))). Move closer, in the open."
            setState(s)
            scheduleRetry()
        } else if s.role == .found {
            end("\(name(s.memberId)) stopped finding you.", tellPeer: !byPeer)
        } else if byPeer {
            end("Their phone stopped answering.", tellPeer: false)
        } else {
            end("UWB stopped: \(reasonText(reason)).", tellPeer: true)
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        guard session === self.session, var s = state, s.active else { return }
        s.note = "Paused while TrailMind isn't on screen."
        setState(s)
    }

    func sessionSuspensionEnded(_ session: NISession) {
        guard session === self.session, let configuration else { return }
        session.run(configuration)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard session === self.session else { return }
        self.session = nil
        guard let s = state, s.active else { return }
        let what = s.measuredAt > 0 ? "UWB stopped" : "UWB wouldn't start"
        if s.role == .found, let g = host?.tripGroup, let host {
            // A decline tells the finder why, where a plain stop would only say the phone went quiet.
            end("\(what): \(errorText(error)).", tellPeer: false)
            if let decline = try? RangeFrame(memberId: g.memberId, targetId: s.memberId, kind: RangeFrame.decline, nonce: s.nonce,
                                             timeS: host.nowS(), reason: RangeFrame.reasonFailed) {
                send(decline, forMs: GroupFinder.stopRepeatMs)
            }
        } else {
            end("\(what): \(errorText(error)).", tellPeer: true)
        }
    }
}
