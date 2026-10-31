import Foundation
import MultipeerConnectivity
import Network

/// The iPhones' direct link for the trip group: MultipeerConnectivity, which joins iPhones over peer-to-peer Wi-Fi and
/// Bluetooth with no network, pairing or prompts. iPhones in the group find each other by the group's rotating tag in
/// their discovery info, one of each pair invites the other with a frame sealed under the group's key (anyone else is
/// turned away), and they then exchange exactly the sealed adverts Android phones broadcast. iOS runs this while
/// TrailMind is open and pauses it in the background. A new random name and tag every 15 minutes, as Android's
/// Bluetooth address changes with its tag, so the group can't be followed for long. A session holds up to 8 iPhones.
final class GroupPeerLink: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    var onData: ((Data, MCPeerID) -> Void)?
    var onConnected: ((MCPeerID) -> Void)?
    var onChanged: (() -> Void)?
    /// What to send with an invitation: proof of membership.
    var inviteContext: (() -> Data?)?
    /// Whether an invitation's context proves membership.
    var acceptsInvite: ((Data?) -> Bool)?
    /// Whether a discovered iPhone's tag is this group's.
    var tagMatches: ((String?) -> Bool)?

    private(set) var running = false
    private(set) var advertising = false
    private(set) var received: Int64 = 0
    private(set) var sent: Int64 = 0
    private(set) var sendFailures: Int64 = 0
    private(set) var startedAt: Date?

    /// Why other iPhones can't reach this one, or nil.
    var error: String? { localNetworkDenied ? "Local Network access is off for TrailMind" : linkError }

    private static let inviteTimeoutS: TimeInterval = 20
    private static let reinviteS: TimeInterval = 30
    /// kDNSServiceErr_PolicyDenied: the user turned Local Network off for TrailMind.
    private static let policyDenied: Int32 = -65570
    /// NSNetServicesMissingRequiredConfigurationError: the app's Info.plist lacks the Bonjour service type.
    private static let missingConfiguration = -72008

    private var me: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Browses the same Bonjour service only to learn whether iOS allows TrailMind on the local network: Multipeer
    /// Connectivity just finds nobody when it doesn't.
    private var probe: NWBrowser?
    private var linkError: String?
    private var localNetworkDenied = false
    private var tag = ""
    private var epoch = Int64.min
    /// Group iPhones found nearby (their tag matched), to invite and re-invite.
    private var nearby = Set<MCPeerID>()
    private var foundAt: [MCPeerID: Date] = [:]
    private var invitedAt: [MCPeerID: Date] = [:]
    private var memberOfPeer: [MCPeerID: Int] = [:]

    var connectedPeers: [MCPeerID] { session?.connectedPeers ?? [] }
    var name: String? { me?.displayName }
    var nearbyCount: Int { nearby.count }

    /// Runs the link (advertising only when this phone has something to send), or stops it.
    func update(on: Bool, advertise: Bool, tag: String, epoch: Int64) {
        guard on else {
            stop()
            return
        }
        // A new epoch or a new group: a new name and tag, and no sessions with the old group.
        if running && (epoch != self.epoch || tag != self.tag) { stop() }
        self.tag = tag
        self.epoch = epoch
        if !running { start() }
        setAdvertising(advertise)
        for peer in nearby { inviteIfNeeded(peer) }
    }

    /// Starts afresh, after iOS dropped the sessions in the background.
    func restart() {
        guard running else { return }
        let wasAdvertising = advertising
        stop()
        start()
        setAdvertising(wasAdvertising)
    }

    func stop() {
        guard running else { return }
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        probe?.cancel()
        probe = nil
        me = nil
        running = false
        advertising = false
        startedAt = nil
        nearby.removeAll()
        foundAt.removeAll()
        invitedAt.removeAll()
        memberOfPeer.removeAll()
        onChanged?()
    }

    /// To every connected iPhone in the group.
    func broadcast(_ data: Data) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        do {
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            sent += 1
        } catch {
            // A peer dropping as it is sent to; the next send goes to whoever is still connected.
            sendFailures += 1
        }
    }

    func send(_ data: Data, to peer: MCPeerID) -> Bool {
        guard let session, session.connectedPeers.contains(peer) else { return false }
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
            sent += 1
            return true
        } catch {
            sendFailures += 1
            return false
        }
    }

    /// Which member a connected iPhone is, learnt from the frames it sends about itself.
    func bind(_ peer: MCPeerID, memberId: Int) { memberOfPeer[peer] = memberId }

    func peer(for memberId: Int) -> MCPeerID? { connectedPeers.first { memberOfPeer[$0] == memberId } }

    // MARK: Internals

    private func start() {
        let peer = MCPeerID(displayName: String(UInt32.random(in: UInt32.min...UInt32.max), radix: 16))
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: GroupIPhone.serviceType)
        browser.delegate = self
        me = peer
        self.session = session
        self.browser = browser
        linkError = nil
        running = true
        startedAt = Date()
        browser.startBrowsingForPeers()
        startProbe()
        onChanged?()
    }

    private func setAdvertising(_ on: Bool) {
        guard running, let me else { return }
        if on, advertiser == nil {
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["v": "1", GroupPeerTag.key: tag], serviceType: GroupIPhone.serviceType)
            a.delegate = self
            advertiser = a
            a.startAdvertisingPeer()
            advertising = true
        } else if !on, let a = advertiser {
            a.stopAdvertisingPeer()
            a.delegate = nil
            advertiser = nil
            advertising = false
        }
    }

    /// One of each pair invites first (GroupPeerInvite); if no connection comes of that within a few seconds, the other
    /// invites too.
    private func inviteIfNeeded(_ peer: MCPeerID) {
        guard let session, let browser, let me, !session.connectedPeers.contains(peer) else { return }
        let now = Date()
        let waited = now.timeIntervalSince(foundAt[peer] ?? now)
        guard GroupPeerInvite.shouldInvite(advertising: advertising, myName: me.displayName, peerName: peer.displayName,
                                           waitedS: waited) else { return }
        if let at = invitedAt[peer], now.timeIntervalSince(at) < GroupPeerLink.reinviteS { return }
        invitedAt[peer] = now
        browser.invitePeer(peer, to: session, withContext: inviteContext?(), timeout: GroupPeerLink.inviteTimeoutS)
    }

    private func failed(_ error: Error) {
        let ns = error as NSError
        if ns.code == Int(GroupPeerLink.policyDenied) {
            localNetworkDenied = true
        } else if ns.code == GroupPeerLink.missingConfiguration {
            linkError = "this copy of TrailMind isn't set up for it (Bonjour service missing)"
        } else {
            linkError = ns.localizedDescription
        }
        onChanged?()
    }

    private func startProbe() {
        guard probe == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let probe = NWBrowser(for: .bonjour(type: "_\(GroupIPhone.serviceType)._tcp", domain: nil), using: parameters)
        probe.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            var denied = self.localNetworkDenied
            switch state {
            case .ready:
                denied = false
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == GroupPeerLink.policyDenied { denied = true }
            default:
                break
            }
            if denied != self.localNetworkDenied {
                self.localNetworkDenied = denied
                self.onChanged?()
            }
        }
        probe.start(queue: .main)
        self.probe = probe
    }

    // MARK: MCNearbyServiceBrowserDelegate

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, browser === self.browser, self.tagMatches?(info?[GroupPeerTag.key]) == true else { return }
            self.nearby.insert(peerID)
            if self.foundAt[peerID] == nil { self.foundAt[peerID] = Date() }
            self.inviteIfNeeded(peerID)
            self.onChanged?()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, browser === self.browser else { return }
            self.nearby.remove(peerID)
            self.foundAt[peerID] = nil
            self.onChanged?()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in self?.failed(error) }
    }

    // MARK: MCNearbyServiceAdvertiserDelegate

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, advertiser === self.advertiser, let session = self.session, self.acceptsInvite?(context) == true else {
                invitationHandler(false, nil)
                return
            }
            invitationHandler(true, session)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in self?.failed(error) }
    }

    // MARK: MCSessionDelegate

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.session else { return }
            switch state {
            case .connected:
                self.invitedAt[peerID] = nil
                self.linkError = nil
                self.onConnected?(peerID)
            case .notConnected:
                self.memberOfPeer[peerID] = nil
                // Lost: the phone whose turn it is invites again first.
                if self.nearby.contains(peerID) { self.foundAt[peerID] = Date() }
            default:
                break
            }
            self.onChanged?()
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session === self.session else { return }
            self.received += 1
            self.onData?(data, peerID)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {
        progress.cancel()
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
                 certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}
