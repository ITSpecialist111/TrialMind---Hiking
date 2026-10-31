import Foundation
import UIKit

/// Links TrailMind to the user's Strava account and posts each finished hike to it (strava/StravaManager.kt).
///
/// The user registers their own Strava API application once (strava.com/settings/api) and pastes its Client ID and
/// secret in; Strava's sign-in then runs in a secure browser sheet and comes back to TrailMind, which keeps the tokens in
/// the Keychain. Each hike gets one row in the database, so a retry, a restart or a second tap can never post it twice,
/// and a hike recorded without signal is posted when there is some.
///
/// Settings belong to the main thread (they publish to SwiftUI). The posting queue runs on its own serial queue, which
/// is Android's queue lock, and reads and writes settings through `onMain`; the main thread never waits for that queue.
final class StravaService: ObservableObject {
    static let shared = StravaService()

    /// Bumped whenever a post or the link changes, so pages showing them refresh.
    @Published private(set) var revision = 0
    /// What the last attempt to link ended in, kept so the Strava page can show a failure after the toast has gone.
    @Published private(set) var linkNote: String?

    private let prefs = Prefs.shared
    private let store = Store.shared
    /// Posting, queueing and unlinking take turns here (Android's queueLock).
    private let work = DispatchQueue(label: "com.trailmind.strava", qos: .utility)
    private let stopLock = NSLock()
    private var stopRequested = false
    /// The run planned in the app (StravaUploadJob's next run while TrailMind is running). Only touched on `work`.
    private var nextRun: DispatchWorkItem?
    /// The last run found no usable network, so signal coming back starts the next one. Only touched on `work`.
    private var waitingForNetwork = false
    private var started = false

    /// Wires up background posting, the network watch and notifications, and lets anything waiting have its turn.
    /// Called once at launch: iOS needs the background task registered before launching finishes.
    func start() {
        guard !started else { return }
        started = true
        StravaBackground.register(run: { [weak self] done in self?.runForBackgroundTask(done) ?? done() },
                                  stop: { [weak self] in self?.setStopping(true) })
        StravaNetwork.shared.start { [weak self] in self?.networkReturned() }
        StravaNotifications.shared.install()
        // Coming back to TrailMind gives anything due its turn (the in-app timer doesn't run while iOS suspends it).
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        }
        resume()
    }

    // MARK: - The link (main thread)

    /// The Client ID and secret of the user's own Strava application are saved.
    var hasApp: Bool { !KotlinText.isBlank(prefs.stravaClientId) && prefs.hasStravaSecret }

    /// Signed in to Strava, and Strava still accepts it.
    var linked: Bool { prefs.hasStravaRefreshToken && !prefs.stravaNeedsReconnect }

    /// Signed in once, but Strava has refused the saved link since (revoked, or uploading was switched off).
    var needsReconnect: Bool { prefs.hasStravaRefreshToken && prefs.stravaNeedsReconnect }

    /// Who is linked, for "Linked as …".
    func athlete() -> StravaAthlete? {
        StravaAthlete.saved(id: prefs.stravaAthleteId, username: prefs.stravaAthleteUsername,
                            firstName: prefs.stravaAthleteFirstName, lastName: prefs.stravaAthleteLastName)
    }

    /// Starts the sign-in with the application's `clientId` and `clientSecret` (a blank secret keeps the one saved), and
    /// returns the page to sign in on, or nil with the problem in `error`.
    func beginConnect(_ clientId: String, _ clientSecret: String, error: (String) -> Void) -> URL? {
        linkNote = nil
        switch StravaConnect.check(clientId: clientId, clientSecret: clientSecret, savedClientId: prefs.stravaClientId,
                                   hasSavedSecret: prefs.hasStravaSecret) {
        case .invalid(let message):
            error(message)
            return nil
        case .ready(let id, let secret, let otherApp):
            // A different application means the old sign-in is no use.
            if otherApp { clearLink() }
            prefs.stravaClientId = id
            if !secret.isEmpty { prefs.stravaClientSecret = secret }
            var random = SystemRandomNumberGenerator()
            let state = StravaRequests.stateText((0..<16).map { _ in UInt8.random(in: 0...255, using: &random) })
            prefs.stravaPendingState = state
            return URL(string: StravaOAuth.authorizeUrl(StravaClient.baseUrl, id, state))
        }
    }

    /// Strava sent the user back to the app. `done` gets what to tell them, on the main thread.
    func handleRedirect(_ url: String, done: @escaping (String) -> Void) {
        let finish: (String) -> Void = { message in
            DispatchQueue.main.async {
                self.linkNote = message
                done(message)
            }
        }
        let pending = prefs.stravaPendingState
        switch StravaOAuth.parseRedirect(url, pending.isEmpty ? nil : pending) {
        case .invalid(let reason):
            finish(reason)
        case .refused(let reason):
            prefs.stravaPendingState = ""
            finish(reason)
        case .granted(let granted):
            // The state is good for one answer.
            prefs.stravaPendingState = ""
            guard granted.canUpload else {
                finish(StravaText.noUploadPermission)
                return
            }
            let clientId = prefs.stravaClientId
            let secret = prefs.stravaClientSecret
            DispatchQueue.global(qos: .userInitiated).async {
                finish(self.completeLink(granted, clientId, secret))
            }
        }
    }

    /// Swaps the sign-in code for tokens and saves them. Runs on a background thread; returns what to tell the user.
    private func completeLink(_ granted: StravaOAuth.Redirect.Granted, _ clientId: String, _ secret: String) -> String {
        let reply = StravaClient.exchangeCode(clientId, secret, granted.code)
        guard case .ok(let body) = reply else { return StravaText.linkFailure(reply) ?? "" }
        let who: StravaAthlete? = onMain {
            storeTokens(body, scope: granted.scopes.sorted().joined(separator: ","))
            if let athlete = StravaReplies.athlete(body) { storeAthlete(athlete) }
            prefs.stravaNeedsReconnect = false
            return athlete()
        }
        StravaNotifications.shared.linked()
        changed()
        resume()
        return StravaText.linked(who)
    }

    /// Unlinks, and tells Strava so it drops TrailMind from the user's connected apps. Hikes already posted stay on
    /// Strava; hikes still waiting to be posted are let go, so they can't end up on whichever account is linked next.
    /// With `forget`, the application's Client ID and secret go too.
    func disconnect(forget: Bool = false) {
        work.async {
            // On the posting queue, so a post in progress can't store a token after this has cleared them.
            let token = self.tokenForRevoking()
            self.onMain {
                self.clearLink()
                if forget {
                    self.prefs.stravaClientId = ""
                    self.prefs.stravaClientSecret = ""
                }
            }
            self.store.dropWaitingStravaPosts()
            self.changed()
            if !KotlinText.isBlank(token) {
                DispatchQueue.global(qos: .utility).async { StravaClient.deauthorize(token) }
            }
        }
    }

    /// An access token lasts six hours, and Strava can't drop an app on an expired one, so renew it first if need be.
    private func tokenForRevoking() -> String {
        let link = self.link()
        guard StravaQueuePolicy.revokeNeedsRefresh(link.tokens, nowS: nowMs() / 1000) else { return link.accessToken }
        if case .ok(let body) = StravaClient.refresh(link.clientId, link.clientSecret, link.refreshToken) {
            let fresh = BeaconJSON.optString(body, "access_token")
            if !KotlinText.isBlank(fresh) { return fresh }
        }
        return link.accessToken
    }

    /// Main thread.
    private func clearLink() {
        linkNote = nil
        prefs.stravaAccessToken = ""
        prefs.stravaRefreshToken = ""
        prefs.stravaExpiresAtS = 0
        prefs.stravaScope = ""
        prefs.stravaAthleteId = 0
        prefs.stravaAthleteUsername = ""
        prefs.stravaAthleteFirstName = ""
        prefs.stravaAthleteLastName = ""
        prefs.stravaNeedsReconnect = false
        prefs.stravaPendingState = ""
    }

    /// Main thread. A refresh token is only replaced by a new one that isn't blank.
    private func storeTokens(_ body: [String: Any], scope: String? = nil) {
        let tokens = StravaReplies.tokens(body, nowS: nowMs() / 1000)
        prefs.stravaAccessToken = tokens.accessToken
        if let refresh = tokens.refreshToken { prefs.stravaRefreshToken = refresh }
        prefs.stravaExpiresAtS = tokens.expiresAtS
        if let scope { prefs.stravaScope = scope }
    }

    /// Main thread.
    private func storeAthlete(_ a: StravaReplies.AthleteFields) {
        prefs.stravaAthleteId = a.id
        prefs.stravaAthleteUsername = a.username
        prefs.stravaAthleteFirstName = a.firstName
        prefs.stravaAthleteLastName = a.lastName
    }

    // MARK: - What other pages use (main thread)

    /// Where a hike is with Strava, in the words of its page (FeatureHooks.stravaStatus); nil when there's nothing to say.
    func status(_ hikeId: Int64) -> String? {
        let row = store.stravaPost(hikeId)
        let unfinished = store.hike(hikeId).map { $0.status != .done } ?? false
        return StravaQueuePolicy.status(state: row.flatMap { StravaPostState(rawValue: $0.state) }, message: row?.message,
                                        activityId: row?.activityId, linked: linked, needsReconnect: needsReconnect,
                                        live: unfinished)
    }

    /// "Upload to Strava" on a hike's page (FeatureHooks.stravaUploadHike): posted through Strava's API when linked,
    /// otherwise the GPX is saved for Strava's own upload page, the way in that needs no subscription.
    func uploadHike(_ hikeId: Int64) {
        if linked { postFromHikePage(hikeId) } else { StravaHandUpload.start(hikeId) }
    }

    /// "Post now" / "Try again" on a hike's page (FeatureHooks.stravaPostNow).
    func postNowFromHikePage(_ hikeId: Int64) {
        if linked {
            postFromHikePage(hikeId)
        } else if needsReconnect {
            AppModel.shared.choose("Strava needs you to connect again",
                                   "Strava stopped accepting TrailMind, so this hike can't be posted by itself.",
                                   options: [("Connect again", { StravaPage.open() }),
                                             ("Upload by hand", { StravaHandUpload.start(hikeId) })])
        } else {
            StravaHandUpload.start(hikeId)
        }
    }

    /// Queues a finished hike whatever its length (a retry keeps any upload Strava already has), and says so.
    private func postFromHikePage(_ hikeId: Int64) {
        if let hike = store.hike(hikeId), hike.status != .done {
            AppModel.shared.toast("You can post it once it's finished.")
            return
        }
        if store.stravaPost(hikeId)?.state == StravaPostState.posted.rawValue {
            AppModel.shared.toast("This hike is already on Strava.")
            return
        }
        postNow(hikeId)
        AppModel.shared.toast(StravaNetwork.shared.usable ? "Posting to Strava…" : "It goes to Strava as soon as the phone has signal.")
    }

    // MARK: - Posting

    /// A hike has just been finished: post it if the user links Strava and wants that, and it was a real hike.
    func onHikeFinished(_ hikeId: Int64) {
        let wanted = onMain { linked && prefs.stravaAuto }
        guard wanted else { return }
        work.async {
            guard let hike = self.store.hike(hikeId) else { return }
            if StravaPolicy.worthPosting(hike.distanceM, hike.pointCount) {
                self.enqueue(hikeId)
            } else {
                self.store.saveStravaPost(StravaPostRow(hikeId: hikeId, state: StravaPostState.skipped.rawValue, uploadId: nil,
                                                        activityId: nil, message: StravaQueuePolicy.tooShortMessage, attempts: 0,
                                                        nextTryMs: 0, updatedMs: nowMs()))
                self.changed()
            }
        }
    }

    /// The user asked to post this hike (or to try again), whatever its length.
    func postNow(_ hikeId: Int64) {
        guard onMain({ linked }) else { return }
        work.async { self.enqueue(hikeId) }
    }

    /// On `work`.
    private func enqueue(_ hikeId: Int64) {
        guard store.hike(hikeId) != nil else { return }
        let now = nowMs()
        let earlier = store.stravaPost(hikeId)
        if earlier?.state == StravaPostState.posted.rawValue { return }
        // A hike already uploaded and being processed keeps its upload, so asking again can't upload it twice.
        let waiting = earlier?.state == StravaPostState.queued.rawValue || earlier?.state == StravaPostState.processing.rawValue
        store.saveStravaPost(StravaPostRow(hikeId: hikeId, state: StravaPostState.queued.rawValue,
                                           uploadId: waiting ? earlier?.uploadId : nil, activityId: nil, message: nil,
                                           attempts: 0, nextTryMs: now, updatedMs: now))
        changed()
        plan(0)
    }

    /// At start-up and on coming back to the app: anything still waiting gets its turn.
    func resume() {
        work.async {
            if self.link().linked && self.store.stravaNextTry() != nil { self.plan(0) }
        }
    }

    /// StravaUploadJob.schedule: run after `delayMs`, replacing any run already planned, both in the app and as an iOS
    /// background task for when TrailMind isn't running. On `work`.
    private func plan(_ delayMs: Int64) {
        nextRun?.cancel()
        let run = DispatchWorkItem { [weak self] in self?.runJob() }
        nextRun = run
        work.asyncAfter(wallDeadline: .now() + .milliseconds(Int(max(delayMs, 0))), execute: run)
        StravaBackground.submit(afterMs: delayMs)
    }

    /// One run of the queue in the app, with a little extra time to finish if TrailMind goes to the background. On `work`.
    private func runJob() {
        nextRun = nil
        setStopping(false)
        let time = BackgroundTime { [weak self] in self?.setStopping(true) }
        defer { time.end() }
        planAfter(runQueue())
    }

    /// iOS woke TrailMind for its background task: run the queue, plan the next run, then let iOS know.
    private func runForBackgroundTask(_ done: @escaping () -> Void) {
        work.async {
            self.nextRun?.cancel()
            self.nextRun = nil
            self.setStopping(false)
            self.planAfter(self.runQueue())
            done()
        }
    }

    private func planAfter(_ next: Int64?) {
        if let next { plan(next) } else { StravaBackground.cancel() }
    }

    /// Signal is back: if the last run was waiting for it, go now rather than at the next check.
    private func networkReturned() {
        work.async {
            guard self.waitingForNetwork else { return }
            self.waitingForNetwork = false
            self.plan(0)
        }
    }

    /// Sends what is due. Returns how long until something else is due, or nil when nothing is waiting (or nothing can be
    /// sent until the user reconnects). On `work`.
    private func runQueue() -> Int64? {
        let link = self.link()
        guard link.hasApp && link.linked else { return nil }
        let now = nowMs()
        if !StravaNetwork.shared.usable {
            waitingForNetwork = true
            return StravaQueuePolicy.offlineWaitMs
        }
        waitingForNetwork = false
        for row in store.stravaDue(now) {
            if !self.link().linked || stopping { break }
            process(row)
        }
        return StravaQueuePolicy.nextWaitMs(nextTryMs: store.stravaNextTry(), now: nowMs())
    }

    private func process(_ first: StravaPostRow) {
        var row = first
        guard let hike = store.hike(row.hikeId) else { return }
        let token: String
        switch accessToken() {
        case .token(let access): token = access
        case .reconnect: return
        case .later(let reply):
            later(row, reply)
            return
        }
        var reply: StravaReply
        var uploadId = row.uploadId
        if let existing = uploadId {
            reply = StravaClient.uploadStatus(token, existing)
            guard case .ok = reply else {
                later(row, reply)
                return
            }
        } else {
            let segments = store.hikeSegments(hike.id)
            if segments.reduce(0, { $0 + $1.count }) < 2 {
                save(row, .skipped, message: "This hike has no track to post.")
                return
            }
            let kind = StravaActivityKind.of(onMain { prefs.stravaKind })
            let gpx = StravaRequests.hikeGpx(name: hike.name, segments: segments, kind: kind)
            let upload = { (access: String) in
                StravaClient.upload(access, gpx: gpx, fileName: StravaRequests.uploadFileName(hike.id),
                                    name: StravaPolicy.activityName(hike.name), kind: kind,
                                    externalId: StravaPolicy.externalId(hike.startMs, hike.id))
            }
            guard let sent = retryOnceIfRefused(upload(token), again: upload) else { return }
            reply = sent
            guard case .ok(let body) = reply else {
                later(row, reply)
                return
            }
            guard let id = StravaReplies.uploadId(body) else {
                save(row, .failed, message: "Strava didn't say what became of the upload.")
                return
            }
            uploadId = id
            save(row, .processing, uploadId: id)
            // From here every later save keeps the upload's id, so a failed check can't make the file go up again.
            row.uploadId = id
        }
        guard let uploaded = uploadId else { return }
        // Strava processes a file in a couple of seconds; check on it for a while before leaving it for later.
        for _ in 0..<StravaPolicy.pollTries {
            guard case .ok(let body) = reply else {
                later(row, reply)
                return
            }
            switch StravaReplies.uploadResult(body) {
            case .ready(let activityId):
                finished(row, hike, activityId)
                return
            case .duplicate:
                save(row, .posted, uploadId: uploaded, message: "Already on Strava.")
                return
            case .failed(let message):
                save(row, .failed, uploadId: uploaded, message: message)
                return
            case .processing:
                break
            }
            if !pause(StravaPolicy.pollMs) { return }
            reply = StravaClient.uploadStatus(token, uploaded)
        }
        // Still processing: ask again soon, without counting it as a failure.
        save(row, .processing, uploadId: uploaded, nextTryMs: nowMs() + StravaQueuePolicy.processingRecheckMs)
    }

    private func finished(_ row: StravaPostRow, _ hike: HikeMeta, _ activityId: Int64) {
        store.saveStravaPost(StravaPostRow(hikeId: row.hikeId, state: StravaPostState.posted.rawValue, uploadId: row.uploadId,
                                           activityId: activityId, message: nil, attempts: row.attempts, nextTryMs: 0,
                                           updatedMs: nowMs()))
        changed()
        StravaNotifications.shared.posted(hike.name, activityId)
    }

    /// Saves the post with `state`, keeping its upload id unless given one, its attempt count, and no activity.
    private func save(_ row: StravaPostRow, _ state: StravaPostState, uploadId: Int64? = nil, message: String? = nil,
                      nextTryMs: Int64 = 0) {
        store.saveStravaPost(StravaPostRow(hikeId: row.hikeId, state: state.rawValue, uploadId: uploadId ?? row.uploadId,
                                           activityId: nil, message: message, attempts: row.attempts, nextTryMs: nextTryMs,
                                           updatedMs: nowMs()))
        changed()
    }

    /// A call that didn't succeed: wait and try again, or give up, depending on why.
    private func later(_ row: StravaPostRow, _ reply: StravaReply) {
        let now = nowMs()
        switch StravaQueuePolicy.later(attempts: row.attempts, reply: reply, now: now) {
        case .save(let state, let message, let attempts, let nextTryMs):
            store.saveStravaPost(StravaPostRow(hikeId: row.hikeId, state: state.rawValue, uploadId: row.uploadId, activityId: nil,
                                               message: message, attempts: attempts, nextTryMs: nextTryMs, updatedMs: now))
        case .reconnect:
            markReconnect()
        }
        changed()
    }

    // MARK: - Tokens

    private enum Auth {
        case token(String)
        case reconnect
        case later(StravaReply)
    }

    private func accessToken(force: Bool = false) -> Auth {
        let link = self.link()
        if KotlinText.isBlank(link.refreshToken) { return .reconnect }
        if let current = StravaQueuePolicy.currentAccessToken(link.tokens, nowS: nowMs() / 1000, force: force) {
            return .token(current)
        }
        let reply = StravaClient.refresh(link.clientId, link.clientSecret, link.refreshToken)
        switch reply {
        case .ok(let body):
            return .token(onMain {
                storeTokens(body)
                return prefs.stravaAccessToken
            })
        case .http:
            if StravaQueuePolicy.refreshNeedsReconnect(reply) {
                markReconnect()
                return .reconnect
            }
            return .later(reply)
        case .offline:
            return .later(reply)
        }
    }

    /// If Strava says the token is no good, gets a fresh one and sends the same request once more. Nil: the user must
    /// reconnect.
    private func retryOnceIfRefused(_ first: StravaReply, again: (String) -> StravaReply) -> StravaReply? {
        guard case .http(let code, _, _) = first, code == 401 else { return first }
        switch accessToken(force: true) {
        case .token(let access): return again(access)
        case .reconnect: return nil
        case .later(let reply): return reply
        }
    }

    private func markReconnect() {
        let already = onMain { () -> Bool in
            if prefs.stravaNeedsReconnect { return true }
            prefs.stravaNeedsReconnect = true
            return false
        }
        if already { return }
        changed()
        StravaNotifications.shared.reconnect()
    }

    // MARK: - Plumbing

    /// The link as saved, read on the main thread for the posting queue.
    private struct Link {
        var clientId: String
        var clientSecret: String
        var accessToken: String
        var refreshToken: String
        var expiresAtS: Int64
        var scope: String
        var needsReconnect: Bool

        var hasApp: Bool { !KotlinText.isBlank(clientId) && !clientSecret.isEmpty }
        var linked: Bool { !refreshToken.isEmpty && !needsReconnect }
        var tokens: StravaTokens {
            StravaTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAtS: expiresAtS, scope: scope)
        }
    }

    private func link() -> Link {
        onMain {
            Link(clientId: prefs.stravaClientId, clientSecret: prefs.stravaClientSecret, accessToken: prefs.stravaAccessToken,
                 refreshToken: prefs.stravaRefreshToken, expiresAtS: prefs.stravaExpiresAtS, scope: prefs.stravaScope,
                 needsReconnect: prefs.stravaNeedsReconnect)
        }
    }

    /// Runs `body` on the main thread and waits for it. Safe from `work`, as the main thread never waits for `work`.
    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func changed() {
        DispatchQueue.main.async { self.revision &+= 1 }
    }

    private var stopping: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    private func setStopping(_ value: Bool) {
        stopLock.lock()
        stopRequested = value
        stopLock.unlock()
    }

    /// Waits `ms` between checks on an upload; false when iOS wants the time back first.
    private func pause(_ ms: Int64) -> Bool {
        let until = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < until {
            if stopping { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !stopping
    }
}

/// A little more time when TrailMind goes to the background mid-post, so an upload in flight can finish. Begun and
/// ended on the main thread, in order; when iOS wants the time back, posting is told to stop and the time is handed
/// back before the expiry handler returns, as iOS requires.
private final class BackgroundTime {
    /// Main thread only.
    private var id = UIBackgroundTaskIdentifier.invalid

    init(onExpiry: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            id = UIApplication.shared.beginBackgroundTask(withName: "Strava posting") { [self] in
                onExpiry()
                endNow()
            }
        }
    }

    func end() {
        DispatchQueue.main.async { [self] in endNow() }
    }

    private func endNow() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
