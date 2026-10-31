import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// A trip group as this phone holds it (GroupSharing.TripGroup).
final class TripGroup {
    let id: String
    let name: String
    let code: GroupCode
    let memberId: Int
    let displayName: String
    let colour: Int
    let createdMs: Int64
    let expiresMs: Int64
    let keys: GroupKeys

    init(id: String, name: String, code: GroupCode, memberId: Int, displayName: String, colour: Int, createdMs: Int64,
         expiresMs: Int64, keys: GroupKeys? = nil) {
        self.id = id
        self.name = name
        self.code = code
        self.memberId = memberId
        self.displayName = displayName
        self.colour = colour
        self.createdMs = createdMs
        self.expiresMs = expiresMs
        self.keys = keys ?? GroupKeys(code)
    }

    func with(displayName: String? = nil, expiresMs: Int64? = nil) -> TripGroup {
        TripGroup(id: id, name: name, code: code, memberId: memberId, displayName: displayName ?? self.displayName, colour: colour,
                  createdMs: createdMs, expiresMs: expiresMs ?? self.expiresMs, keys: keys)
    }
}

/// Trip-group sharing on iPhone (frontier/group/GroupSharing.kt). This phone's position goes out sealed with the
/// group's code, and the group's positions come in, directly or passed on by members in between. Between iPhones the
/// sealed adverts travel over MultipeerConnectivity, because iOS doesn't let apps put data in Bluetooth adverts; Android
/// members' Bluetooth adverts are heard with Core Bluetooth while TrailMind is open. It runs only after the user creates
/// or joins a group, and everything happens on the main thread (the work is a few small AES-GCM operations a second).
final class GroupService: ObservableObject {
    static let shared = GroupService()

    enum Readiness { case noGroup, off, ready }
    enum TrackingStatus { case idle, recording, paused }
    /// How a frame reached this phone.
    enum Via {
        case bluetooth(rssi: Int?, txPower: Int?)
        case iPhone(MCPeerID)
    }

    private static let tickMs: Int64 = 5_000
    private static let profileMs: Int64 = 20_000
    private static let saveMs: Int64 = 30_000
    private static let moveM = 10.0
    private static let inRangeMs: Int64 = 2 * 60_000
    /// "Find my group" on iPhone: the sealed adverts go out every 2 s instead of every 5 s.
    private static let boostResendMs: Int64 = 2_000

    @Published private(set) var group: TripGroup?
    @Published private(set) var members: [PeerTable.Peer] = []
    @Published private(set) var plan: RadioPlan?
    @Published private(set) var boostUntilMs: Int64 = 0
    @Published private(set) var ownFrame: PositionFrame?
    /// Bumped whenever something the pages show may have changed.
    @Published private(set) var revision = 0
    private(set) var opened: Int64 = 0
    private(set) var unreadable: Int64 = 0

    /// iPhones' direct link.
    let link = GroupPeerLink()
    /// Android members' Bluetooth adverts.
    let bluetooth = GroupBluetooth()
    /// Finding a member up close with Nearby Interaction.
    let finder = GroupFinder()

    private let prefs = Prefs.shared
    private var table = PeerTable(ownMemberId: 0)
    private let relay = RelayPolicy()
    private let hikeWatch = GroupHikeWatch()
    private var uiVisible = false
    /// A hike is under way on this phone (recording or paused), as the hike listeners report.
    private var recording = false
    private var lastFix: Fix?
    private var ownFrameMs: Int64 = 0
    private var profileMs: Int64 = 0
    private var helpAlerted: [Int: Int64] = [:]
    private var savedMs: [Int: Int64] = [:]
    /// Members whose last direct frame came over the iPhone link (no signal strength to show), by member id.
    private var directIPhone: [Int: Bool] = [:]
    private var log: [String] = []
    private var publishPending = false
    private var timer: Timer?
    private var lastTickMs: Int64 = 0
    private var lastSendMs: Int64 = 0
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var shownMarkers: [GroupMarker] = []
    private var pausedCache: (revision: Int, paused: Bool)?

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        finder.host = self
        link.onData = { [weak self] data, peer in self?.received(data, from: peer) }
        link.onConnected = { [weak self] _ in self?.reconcile() }
        link.onChanged = { [weak self] in self?.publishSoon() }
        link.inviteContext = { [weak self] in self?.inviteProof() }
        link.acceptsInvite = { [weak self] context in self?.isProof(context) ?? false }
        link.tagMatches = { [weak self] value in self?.tagMatches(value) ?? false }
        bluetooth.onAdvert = { [weak self] payload, rssi, txPower in self?.onAdvert(payload, via: .bluetooth(rssi: rssi, txPower: txPower)) }
        bluetooth.onChanged = { [weak self] in self?.publishSoon() }
        load()
        UIDevice.current.isBatteryMonitoringEnabled = true
        LocationHub.shared.addListener { [weak self] fix in self?.fix(fix) }
        observe()
        uiVisible = UIApplication.shared.applicationState != .background
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.second() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        reconcile()
        publish()
    }

    private func observe() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.link.restart()
                self?.setUiVisible(true)
            }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.setUiVisible(true) }
            .store(in: &cancellables)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.setUiVisible(false) }
            .store(in: &cancellables)
        center.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        // Settings change here, on the Safety page and from the fall alarm; @Published sends before the value is stored.
        let p = prefs
        let changes: [AnyPublisher<Void, Never>] = [
            p.$frontierEnabled.map { _ in () }.eraseToAnyPublisher(),
            p.$frontierHeartbeatsEnabled.map { _ in () }.eraseToAnyPublisher(),
            p.$groupRelayEnabled.map { _ in () }.eraseToAnyPublisher(),
            p.$groupShowOnMap.map { _ in () }.eraseToAnyPublisher(),
            p.$groupUwbFindable.map { _ in () }.eraseToAnyPublisher(),
            p.$groupHikes.map { _ in () }.eraseToAnyPublisher(),
            p.$fallStage.map { _ in () }.eraseToAnyPublisher(),
            p.$frontierEmergencyStatus.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.statusChanged()
                self?.settingsChanged()
            }
            .store(in: &cancellables)
    }

    // MARK: State for the pages

    func readiness() -> Readiness {
        if group == nil { return .noGroup }
        if !prefs.frontierEnabled { return .off }
        return .ready
    }

    func statusLine() -> String {
        switch readiness() {
        case .noGroup: return "Not in a trip group."
        case .off: return "Frontier safety features are off."
        case .ready:
            let radio: String
            if plan == nil {
                radio = "Starts when TrailMind is open or a hike is recording"
            } else if !prefs.frontierHeartbeatsEnabled {
                radio = "Listening only: your position isn't shared"
            } else if let error = link.error {
                radio = "Can't reach other iPhones: " + error
            } else if !link.running {
                radio = "Starting…"
            } else if bluetooth.scanning {
                radio = "Sharing with iPhones, hearing Android phones"
            } else {
                radio = "Sharing with iPhones"
            }
            let all = members
            return "\(radio) · \(all.filter(inRange).count) of \(all.count) in range"
        }
    }

    /// "Group 2/3" for the map chip and the dashboard, or nil while the group isn't running.
    func summary() -> String? {
        guard group != nil, plan != nil else { return nil }
        return "Group \(members.filter(inRange).count)/\(members.count)"
    }

    /// The group's tags and ages use this phone's clock: iOS keeps it set and reports no GPS time to check it against.
    func nowS() -> Int64 { nowMs() / 1_000 }

    /// Heard from the member's own phone in the last two minutes.
    func inRange(_ peer: PeerTable.Peer) -> Bool { nowMs() - peer.lastDirectMs < GroupService.inRangeMs }

    func nameOf(_ peer: PeerTable.Peer) -> String { GroupText.name(peer.name, memberId: peer.memberId) }
    func colourOf(_ peer: PeerTable.Peer) -> UInt32 { GroupColours.of(colour: peer.colour, memberId: peer.memberId) }
    func ownColour() -> UInt32 { GroupColours.of(colour: group?.colour ?? 0, memberId: 0) }
    /// The member's last direct frame came over the iPhone link rather than Bluetooth.
    func viaIPhone(_ memberId: Int) -> Bool { directIPhone[memberId] == true }

    func logCsv() -> String { GroupLog.csv(log) }
    var logCount: Int { log.count }
    func clearLog() { log.removeAll() }

    /// A hike is recording or paused on this phone.
    func hikeUnderWay() -> Bool { recording || FeatureHooks.recordingNow?().recording == true }

    // MARK: Commands (from the pages and other features)

    func setUiVisible(_ visible: Bool) {
        uiVisible = visible
        reconcile()
        publish()
    }

    /// A hike started or ended on this phone (the hike listeners).
    func setRecording(_ on: Bool) {
        recording = on
        pausedCache = nil
        reconcile()
        publish()
    }

    /// This phone's hike has ended: the group hikes still going on were its invitation too, so they aren't offered back.
    func hikeFinished() {
        hikeWatch.handleAll(table.peers(), nowMs: nowMs())
    }

    func settingsChanged() {
        reconcile()
        publish()
    }

    /// "Find my group": listen and send flat out for half an hour.
    func boost() {
        boostUntilMs = nowMs() + RadioProfile.boostMs
        reconcile()
        publish()
    }

    func create(name: String, displayName: String, done: (TripGroup) -> Void) {
        done(newGroup(GroupCode.generate(), name: name, displayName: displayName))
    }

    func join(code: GroupCode, name: String, displayName: String, done: (TripGroup) -> Void) {
        if let current = group, current.code == code { done(current); return }
        done(newGroup(code, name: name, displayName: displayName))
    }

    func leave() { leaveNow() }

    /// Another day on the trip, up to a week from now.
    func extend() {
        guard let g = group else { return }
        saveGroup(g.with(expiresMs: TripTimes.extended(expiresMs: g.expiresMs, nowMs: nowMs())))
        publish()
    }

    func rename(_ displayName: String) {
        guard let g = group else { return }
        let name = FrontierCompat.trim(displayName)
        if FrontierCompat.isBlank(name) { return }
        prefs.groupDisplayName = name
        saveGroup(g.with(displayName: name))
        profileMs = 0
        reconcile()
        publish()
    }

    // MARK: Group lifecycle

    private func load() {
        guard let row = Store.shared.tripGroup() else { return }
        guard let code = GroupVault.unwrap(row.secret) else {
            // The Keychain key is gone (a restore to another phone): the user needs to join again.
            Store.shared.deleteTripGroups()
            return
        }
        let g = TripGroup(id: row.id, name: row.name, code: code, memberId: row.memberId, displayName: row.displayName,
                          colour: row.colour, createdMs: row.createdMs, expiresMs: row.expiresMs)
        guard g.keys.groupId == row.id else {
            Store.shared.deleteTripGroups()
            return
        }
        group = g
        table = PeerTable(ownMemberId: g.memberId)
        for m in Store.shared.groupMembers(g.id) {
            let position = m.position.flatMap { GroupFrames.decode([UInt8]($0)) as? PositionFrame }
            table.restore(PeerTable.Peer(memberId: m.memberId, name: m.name, colour: m.colour, position: position,
                                         positionReceivedMs: m.positionMs, lastHeardMs: m.heardMs, lastDirectMs: m.directMs,
                                         rssi: m.rssi, coded: m.coded))
        }
        members = table.peers()
    }

    private func newGroup(_ code: GroupCode, name: String, displayName: String) -> TripGroup {
        let now = nowMs()
        let keys = GroupKeys(code)
        let trip = FrontierCompat.trim(name)
        let me = FrontierCompat.trim(displayName)
        let g = TripGroup(id: keys.groupId, name: FrontierCompat.isBlank(trip) ? "Trip group" : trip, code: code,
                          memberId: Int(Int32.random(in: Int32.min...Int32.max)),
                          displayName: FrontierCompat.isBlank(me) ? "Hiker" : me,
                          colour: Int.random(in: 0..<GroupColours.all.count), createdMs: now, expiresMs: now + TripTimes.tripMs,
                          keys: keys)
        prefs.groupDisplayName = g.displayName
        prefs.groupSequence = 0
        finder.leave()
        saveGroup(g)
        table = PeerTable(ownMemberId: g.memberId)
        relay.clear()
        hikeWatch.clear()
        helpAlerted.removeAll()
        savedMs.removeAll()
        directIPhone.removeAll()
        ownFrame = nil
        ownFrameMs = 0
        profileMs = 0
        clearLog()
        GroupAlerts.shared.cancelHelp()
        if let f = lastFix ?? LocationHub.shared.latest { makeOwn(f) }
        reconcile()
        publish()
        return g
    }

    private func saveGroup(_ g: TripGroup) {
        if let secret = GroupVault.wrap(g.code) {
            Store.shared.saveTripGroup(TripGroupRow(id: g.id, name: g.name, secret: secret, memberId: g.memberId,
                                                    displayName: g.displayName, colour: g.colour, createdMs: g.createdMs,
                                                    expiresMs: g.expiresMs))
        } else {
            AppModel.shared.toast("Couldn't keep the group code safely, so the group lasts until TrailMind closes.")
        }
        group = g
    }

    private func leaveNow() {
        finder.leave()
        group = nil
        Store.shared.deleteTripGroups()
        table = PeerTable(ownMemberId: 0)
        relay.clear()
        hikeWatch.clear()
        helpAlerted.removeAll()
        savedMs.removeAll()
        directIPhone.removeAll()
        ownFrame = nil
        members = []
        boostUntilMs = 0
        clearLog()
        GroupAlerts.shared.cancelHelp()
        reconcile()
        publish()
    }

    // MARK: Ticks

    /// Every second: the finder's timeouts, Android's 5-second tick, and the faster sends of "Find my group".
    private func second() {
        finder.tick()
        let now = nowMs()
        if now - lastTickMs >= GroupService.tickMs {
            lastTickMs = now
            onTick()
        } else if plan?.mode == .boost, now - lastSendMs >= GroupService.boostResendMs {
            reconcile()
        }
    }

    private func onTick() {
        guard let g = group else { return }
        let now = nowMs()
        // A trip never ends under a hike that's still recording.
        if now > g.expiresMs && !hikeUnderWay() {
            leaveNow()
            return
        }
        if boostUntilMs > 0 && boostUntilMs <= now { boostUntilMs = 0 }
        checkGroupHike()
        reconcile()
        publish()
    }
}

// MARK: - Radio

extension GroupService {
    /// Works out the radio plan and sends this phone's sealed adverts to the iPhones in reach (GroupSharing.reconcile).
    private func reconcile() {
        let ready = readiness() == .ready
        let boost = nowMs() < boostUntilMs || finder.needsRadio
        let p: RadioPlan? = ready ? RadioProfile.plan(
            uiVisible: uiVisible || finder.needsRadio, recording: hikeUnderWay(), boost: boost, batteryPercent: batteryPercent(),
            powerSave: ProcessInfo.processInfo.isLowPowerModeEnabled, relay: prefs.groupRelayEnabled
        ) : nil
        if p != plan { plan = p }
        guard let p, let g = group else {
            link.update(on: false, advertise: false, tag: "", epoch: 0)
            bluetooth.update(on: false, foreground: uiVisible)
            return
        }
        let s = nowS()
        let share = prefs.frontierHeartbeatsEnabled
        let outgoing = finder.outgoing()
        // With sharing off, adverts carry only a UWB ask or answer, and the name that goes with it.
        link.update(on: true, advertise: share || outgoing != nil, tag: GroupPeerTag.value(g.keys, unixSeconds: s),
                    epoch: GroupKeys.epoch(s))
        bluetooth.update(on: true, foreground: uiVisible)
        if share || outgoing != nil, let data = payload(p, share: share) {
            link.broadcast(data)
            lastSendMs = nowMs()
        }
    }

    /// This phone's own position, a UWB ask or answer, others' frames to pass on, and the name: the Android advert.
    private func payload(_ plan: RadioPlan, share: Bool) -> Data? {
        guard let g = group else { return nil }
        let max = GroupAdvert.maxFrames
        let now = nowMs()
        let s = nowS()
        var frames: [any GroupFrame] = []
        if share, var own = ownFrame {
            own.capabilities = capabilityBits()
            own.flags = flags()
            frames.append(own)
        }
        if let out = finder.outgoing(), frames.count < max { frames.append(out) }
        let profileDue = frames.isEmpty || now - profileMs > GroupService.profileMs
        if share && plan.relay {
            frames += relay.pick(nowMs: now, nowS: s, max: max - frames.count - (profileDue ? 1 : 0), helpOnly: plan.relayHelpOnly)
        }
        if frames.count < max, let profile = try? ProfileFrame(memberId: g.memberId, colour: g.colour, name: g.displayName) {
            frames.append(profile)
            profileMs = now
        }
        guard let bytes = try? GroupAdvert.build(g.keys, unixSeconds: s, frames: frames) else { return nil }
        return Data(bytes)
    }

    private func fix(_ f: Fix) {
        lastFix = f
        guard group != nil else { return }
        let moved = ownFrame.map { Geo.distanceM($0.lat, $0.lon, f.lat, f.lon) >= GroupService.moveM } ?? true
        if !moved && nowMs() - ownFrameMs < (uiVisible ? 5_000 : 10_000) { return }
        makeOwn(f)
        if plan != nil { reconcile() }
    }

    private func makeOwn(_ f: Fix) {
        guard let g = group else { return }
        let sequence = (prefs.groupSequence + 1) & 0xFFFF_FFFF
        prefs.groupSequence = sequence
        let originS = (f.timeMs > 0 ? f.timeMs : nowMs()) / 1_000
        ownFrame = try? PositionFrame.of(
            memberId: g.memberId, sequence: sequence, originTimeS: originS, lat: f.lat, lon: f.lon, altitudeM: f.altitudeM,
            accuracyM: f.accuracyM, batteryPercent: batteryPercent() ?? 0, status: status(), capabilities: capabilityBits(),
            flags: flags()
        )
        ownFrameMs = nowMs()
    }

    private func statusChanged() {
        let current = status()
        if ownFrame?.status == current { return }
        if let f = lastFix ?? LocationHub.shared.latest { makeOwn(f) }
        if current.needsHelp { boostUntilMs = nowMs() + RadioProfile.boostMs }
        reconcile()
        publish()
    }

    /// The fall alarm's stage (FallAlert.Stage ordinals, kept in Prefs by the Safety feature), else any emergency set.
    private func status() -> EmergencyStatus {
        switch prefs.fallStage {
        case 1: return .fallDetected
        case 2, 3, 4: return .criticalSos
        default:
            let set = EmergencyStatus.fromWire(prefs.frontierEmergencyStatus)
            return set.needsHelp ? set : .ok
        }
    }

    private func capabilityBits() -> Int {
        // iPhones can neither send nor choose LE Coded, and have no satellite data link: those bits stay clear.
        var bits = 0
        if prefs.groupRelayEnabled { bits |= GroupFrames.capRelay }
        return bits | finder.capabilityBits()
    }

    private func flags() -> Int {
        let groupHike = prefs.groupHikes ? GroupFrames.flagGroupHike : 0
        switch trackingStatus() {
        case .recording: return GroupFrames.flagRecording | groupHike
        case .paused: return GroupFrames.flagPaused | groupHike
        case .idle: return 0
        }
    }

    private func trackingStatus() -> TrackingStatus {
        guard hikeUnderWay() else { return .idle }
        let store = Store.shared
        if pausedCache?.revision != store.revision {
            pausedCache = (store.revision, store.unfinishedHike()?.status == .paused)
        }
        return pausedCache?.paused == true ? .paused : .recording
    }

    private func batteryPercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded()).clamped(0, 100)
    }

    // MARK: Receiving

    private func received(_ data: Data, from peer: MCPeerID) {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return }
        if first == UInt8(GroupAdvert.version) {
            onAdvert(bytes, via: .iPhone(peer))
        } else if first == GroupTokenMessage.marker, let g = group,
                  let message = GroupTokenMessage.open(g.keys, bytes, unixSeconds: nowS()), message.targetId == g.memberId {
            link.bind(peer, memberId: message.memberId)
            finder.onToken(message)
        }
    }

    private func onAdvert(_ payload: [UInt8], via: Via) {
        guard let g = group else { return }
        let now = nowMs()
        let s = nowS()
        guard let result = GroupAdvert.open([g.keys], payload: payload, unixSeconds: s) else {
            unreadable += 1
            return
        }
        opened += 1
        var rssi: Int? = nil
        var txPower: Int? = nil
        var peerID: MCPeerID? = nil
        switch via {
        case .bluetooth(let r, let t):
            rssi = r
            txPower = t
        case .iPhone(let p):
            peerID = p
        }
        for frame in result.frames {
            if let range = frame as? RangeFrame { finder.onFrame(range) }
            let outcome = table.accept(frame, receivedMs: now, nowS: s, rssi: rssi ?? 0, coded: false)
            if frame.hops == 0 && frame.memberId != g.memberId {
                directIPhone[frame.memberId] = peerID != nil
                if let peerID { link.bind(peerID, memberId: frame.memberId) }
            }
            if outcome == .new || outcome == .newer || outcome == .same { relay.offer(frame, receivedMs: now) }
            if outcome == .new || outcome == .newer { news(frame, now: now) }
            record(frame, outcome, rssi: rssi, iPhone: peerID != nil, txPower: txPower, now: now)
        }
        publishSoon()
    }

    private func news(_ frame: any GroupFrame, now: Int64) {
        guard let peer = table.peer(frame.memberId) else { return }
        var important = frame is ProfileFrame
        if let position = frame as? PositionFrame {
            checkGroupHike()
            if position.status.needsHelp {
                alertHelp(peer, position)
                important = true
            } else if helpAlerted.removeValue(forKey: frame.memberId) != nil {
                GroupAlerts.shared.cancelHelp()
                important = true
            }
        }
        if !important && now - (savedMs[frame.memberId] ?? 0) < GroupService.saveMs { return }
        savedMs[frame.memberId] = now
        guard let g = group else { return }
        let p = peer.position
        Store.shared.upsertGroupMember(g.id, GroupMemberRow(
            memberId: peer.memberId, name: peer.name, colour: peer.colour, position: p.map { Data(GroupFrames.encode($0)) },
            positionMs: peer.positionReceivedMs, heardMs: peer.lastHeardMs, directMs: peer.lastDirectMs,
            rssi: viaIPhone(peer.memberId) ? nil : peer.rssi, coded: peer.coded
        ))
        // The satellite message carries the whole group, so a gateway phone can report members it heard.
        if let p, let t = try? HikerTelemetry(
            hikerId: GroupText.memberHex(p.memberId), latitude: p.lat, longitude: p.lon, altitudeMeters: p.altitudeM ?? 0,
            batteryPercent: p.batteryPercent, timestampEpochSeconds: p.originTimeS, status: p.status, triageCode: p.triageCode
        ) {
            Store.shared.upsertMeshHeartbeat(HeartbeatRow(
                hikerId: t.hikerId, latitude: t.latitude, longitude: t.longitude, altitudeM: t.altitudeMeters,
                batteryPercent: t.batteryPercent, timestampS: t.timestampEpochSeconds, status: t.status.wireValue,
                triageCode: t.triageCode
            ), receivedMs: now)
        }
    }

    private func alertHelp(_ peer: PeerTable.Peer, _ frame: PositionFrame) {
        boostUntilMs = nowMs() + RadioProfile.boostMs
        let first = helpAlerted.updateValue(frame.originTimeS, forKey: peer.memberId) == nil
        reconcile()
        guard first, prefs.groupHelpAlerts else { return }
        let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(frame.originTimeS)),
                                                 dateStyle: .none, timeStyle: .short)
        let alert = GroupText.helpAlert(name: nameOf(peer), frame: frame, here: lastFix?.latLon, imperial: prefs.imperial, time: time)
        GroupAlerts.shared.postHelp(title: alert.title, text: alert.text, memberId: peer.memberId)
    }

    private func record(_ frame: any GroupFrame, _ outcome: PeerTable.Result, rssi: Int?, iPhone: Bool, txPower: Int?, now: Int64) {
        log.append(GroupLog.line(frame, outcome: outcome, rssi: iPhone ? nil : rssi, phy: iPhone ? "iphone" : "1m", txPower: txPower,
                                 nowMs: now, own: lastFix?.latLon))
        if log.count > GroupLog.maxLines { log.removeFirst(log.count - GroupLog.maxLines) }
    }

    // MARK: Publishing

    private func publishSoon() {
        if publishPending { return }
        publishPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.publishPending = false
            self?.publish()
        }
    }

    private func publish() {
        members = table.peers()
        revision &+= 1
        updateHikers()
    }

    /// The members on the map (MapScreen.updateHikers): faded after 2 minutes, hollow after 15, dashed when passed on.
    private func updateHikers() {
        guard group != nil, prefs.groupShowOnMap, prefs.frontierEnabled else {
            if !shownMarkers.isEmpty {
                shownMarkers = []
                MapController.shared.setGroupMarkers([])
            }
            return
        }
        let s = nowS()
        let markers = members.compactMap { peer -> GroupMarker? in
            guard let pos = peer.position else { return nil }
            let freshness: GroupMarker.Freshness
            switch PeerTable.freshness(pos, nowS: s) {
            case .fresh: freshness = .live
            case .stale: freshness = .faded
            case .lastSeen: freshness = .hollow
            }
            return GroupMarker(id: peer.memberId, name: nameOf(peer), position: LatLon(pos.lat, pos.lon), colour: colourOf(peer),
                               freshness: freshness, relayed: pos.hops > 0, needsHelp: pos.status.needsHelp)
        }
        if markers != shownMarkers {
            shownMarkers = markers
            MapController.shared.setGroupMarkers(markers)
        }
    }

    // MARK: The iPhone link's checks

    /// What an inviting iPhone sends: the group's sealed name frame, which only a member can make.
    private func inviteProof() -> Data? {
        guard let g = group, let frame = try? ProfileFrame(memberId: g.memberId, colour: g.colour, name: g.displayName),
              let bytes = try? GroupAdvert.build(g.keys, unixSeconds: nowS(), frames: [frame]) else { return nil }
        return Data(bytes)
    }

    private func isProof(_ context: Data?) -> Bool {
        guard let g = group, let context else { return false }
        return GroupAdvert.open([g.keys], payload: [UInt8](context), unixSeconds: nowS()) != nil
    }

    private func tagMatches(_ value: String?) -> Bool {
        guard let g = group else { return false }
        return GroupPeerTag.matches(g.keys, value, unixSeconds: nowS())
    }

    // MARK: Group hikes

    /// Offers this phone's user the group hike another member is recording, once, when it isn't recording itself.
    private func checkGroupHike() {
        guard FeatureHooks.startHike != nil else { return }
        if !prefs.groupHikes || !uiVisible || hikeUnderWay() { return }
        guard let peer = hikeWatch.next(table.peers(), nowS: nowS(), nowMs: nowMs()) else { return }
        let who = nameOf(peer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.uiVisible { self.offerGroupHike(who, memberId: peer.memberId) } else { self.hikeWatch.forget(peer.memberId) }
        }
    }

    /// MainActivity.offerGroupHike: starts recording straight away when that needs nothing from the user, otherwise
    /// (or if they chose to be asked) asks first.
    private func offerGroupHike(_ who: String, memberId: Int) {
        guard prefs.onboardingAccepted, prefs.groupHikes, !hikeUnderWay(), let start = FeatureHooks.startHike else { return }
        let join = { [weak self] in
            guard let self else { return }
            LocationHub.shared.requestPermission()
            GroupAlerts.shared.requestAuthorization()
            if start(self.groupHikeName()) {
                AppModel.shared.toast("\(who) started a group hike, so TrailMind is recording yours too.")
            } else {
                AppModel.shared.toast("Couldn't start recording. Tap Start hike on the map to join \(who).")
            }
        }
        if !prefs.groupHikesAsk && LocationHub.shared.hasPermission {
            join()
            return
        }
        // Another question is on screen: offer again on a later tick rather than replace it.
        if AppModel.shared.dialog != nil {
            hikeWatch.forget(memberId)
            return
        }
        AppModel.shared.choose("\(who) started a group hike",
                               "Record your own copy of it? It is saved on this phone, with your own track, time and distance.",
                               options: [("Start my hike", join)], cancel: "Not now")
    }

    /// Group hikes are named after the group, as TrackingService names them.
    func groupHikeName() -> String {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        if let g = group, prefs.groupHikes { return "\(g.name) · \(stamp)" }
        return "Hike \(stamp)"
    }
}

// MARK: - Finder host

extension GroupService: GroupFinderHost {
    var tripGroup: TripGroup? { group }

    func peer(_ memberId: Int) -> PeerTable.Peer? { table.peer(memberId) }

    func hasLink(to memberId: Int) -> Bool { link.peer(for: memberId) != nil }

    func sendToken(_ message: GroupTokenMessage) -> Bool {
        guard let g = group, let peer = link.peer(for: message.targetId),
              let bytes = try? message.seal(g.keys, unixSeconds: nowS()) else { return false }
        return link.send(Data(bytes), to: peer)
    }

    func finderChanged() {
        reconcile()
        publishSoon()
    }
}

/// The group code's key in the Keychain (this phone only, never backed up), and the code sealed with it.
enum GroupVault {
    private static let account = "group_code_key"

    static func wrap(_ code: GroupCode) -> Data? {
        guard let key = key(create: true), let sealed = try? GroupCodeVault.wrap(Array(code.text.utf8), key: key) else { return nil }
        return Data(sealed)
    }

    static func unwrap(_ secret: Data) -> GroupCode? {
        guard let key = key(create: false), let plain = GroupCodeVault.unwrap([UInt8](secret), key: key) else { return nil }
        return GroupCode.parse(String(decoding: plain, as: UTF8.self))
    }

    private static func key(create: Bool) -> [UInt8]? {
        if let data = Data(base64Encoded: Keychain.get(account)), data.count == GroupCodeVault.keyBytes { return [UInt8](data) }
        guard create else { return nil }
        let key = GroupCodeVault.newKey()
        return Keychain.set(account, Data(key).base64EncodedString()) ? key : nil
    }
}
