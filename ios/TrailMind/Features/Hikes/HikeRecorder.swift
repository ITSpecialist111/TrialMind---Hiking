import Combine
import CoreLocation
import SwiftUI
import UIKit

/// Records a hike (TrackingService + TrackingState on Android). Recording keeps Core Location running in the background
/// with the blue location indicator, as Android's location foreground service does. Every accepted fix is written to
/// the database at once, so a crash or a killed app loses at most one fix. The exception is a fix taken while the phone
/// moves faster than anyone walks: those are held back until it is clear whether it was a brief burst or a drive, and a
/// drive pauses the hike (see `RecordingPipeline`).
final class HikeRecorder: ObservableObject {
    static let shared = HikeRecorder()

    /// The recording as it stands; route guidance reads it too (retrace, daylight pace).
    let track = HikeTrack()
    @Published private(set) var status: HikeTrack.Status = .idle
    @Published private(set) var hikeId: Int64? = nil
    @Published private(set) var hikeName = ""
    /// Changes with every saved point (distance, ascent and the live line).
    @Published private(set) var revision = 0
    /// The newest unfinished hike to offer to recover while nothing records.
    @Published private(set) var unfinished: HikeMeta? = nil

    private let pipeline = RecordingPipeline()
    private let storm = HikeStormWatch()
    private var seq = 0
    private var segment = 0
    private var lastCheckpointMs: Int64 = 0
    private var started = false
    private var listener: UUID?
    private var pendingStart: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var lastLinePush = Date.distantPast
    private var linePushScheduled = false
    private var offerPending = false
    private var offerDialogId: UUID?

    private init() {}

    var activeMs: Int64 { track.activeMs(nowMs()) }

    // MARK: Start-up

    func start() {
        guard !started else { return }
        started = true
        listener = LocationHub.shared.addListener { [weak self] fix in self?.onFix(fix) }
        LocationHub.shared.$authorization
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.authorizationChanged() }
            .store(in: &cancellables)
        Store.shared.$revision
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshUnfinished() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pushLiveTrack(force: true)
                self.refreshUnfinished()
                if self.offerPending { self.offerRecovery() }
            }
            .store(in: &cancellables)
        refreshUnfinished()
        offerPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.offerRecovery() }
    }

    // MARK: Start, pause, resume, finish

    /// "Start hike" on the map (MapScreen.startRecording).
    func startRecording() {
        withLocationPermission { [weak self] in
            guard let self else { return }
            HikeNotifications.shared.requestAuthorization()
            self.startNew(name: nil)
            if LocationHub.shared.latest != nil { MapController.shared.follow = true }
            AppModel.shared.toast("Recording. Tracking continues with the screen off; the blue location indicator shows while TrailMind records.")
            if Prefs.shared.checkInDueMs <= 0, let openCheckIn = FeatureHooks.openCheckIn {
                let route = Guidance.shared.core.active?.name
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AppModel.shared.choose("Set check-in for \(route ?? "my walk")", nil,
                                           options: [("Set check-in…", openCheckIn)], cancel: "Not now")
                }
            }
        }
    }

    /// A trip-group member started a group hike (FeatureHooks.startHike). False if a hike is already recording or
    /// recording can't start from here (iOS starts background location only from the foreground).
    func startFromHook(_ name: String) -> Bool {
        guard track.status == .idle, UIApplication.shared.applicationState != .background else { return false }
        let hub = LocationHub.shared
        if hub.authorization == .denied || hub.authorization == .restricted || (hub.hasPermission && !hub.fullAccuracy) { return false }
        withLocationPermission { [weak self] in
            HikeNotifications.shared.requestAuthorization()
            self?.startNew(name: name)
        }
        return true
    }

    private func startNew(name: String?) {
        guard track.status == .idle else { return }
        let now = nowMs()
        let prefs = Prefs.shared
        let group = prefs.groupHikes ? Store.shared.tripGroup().flatMap { $0.expiresMs > now ? $0 : nil } : nil
        let title = HikeText.hikeTitle(name: name, groupName: group?.name, stamp: HikeTime.dateTime(now))
        let routeId = prefs.activeRouteId > 0 ? prefs.activeRouteId : nil
        let id = Store.shared.createHike(name: title, startMs: now, routeId: routeId)
        seq = 0
        segment = 0
        lastCheckpointMs = 0
        pipeline.reset()
        storm.resetAlerts()
        track.begin(id: id, name: title, start: now, restored: [], restoredActiveMs: 0, nowMs: now)
        began(id, title)
    }

    /// Continues an unfinished hike (TrackingService.resumeExisting): a new segment after the stored ones.
    func resumeHike(_ id: Int64) {
        withLocationPermission { [weak self] in
            guard let self, self.track.status == .idle, let h = Store.shared.hike(id), h.status != .done else { return }
            HikeNotifications.shared.requestAuthorization()
            let last = Store.shared.lastHikePointInfo(id)
            self.seq = (last?.seq ?? -1) + 1
            self.segment = (last?.segment ?? -1) + 1
            let segments = Store.shared.hikeSegments(id)
            self.lastCheckpointMs = 0
            self.pipeline.reset()
            self.storm.resetAlerts()
            Store.shared.setHikeStatus(id, .recording)
            self.track.begin(id: id, name: h.name, start: h.startMs, restored: segments, restoredActiveMs: h.durationMs, nowMs: nowMs())
            self.began(id, h.name)
        }
    }

    private func began(_ id: Int64, _ name: String) {
        dismissOffer()
        startUpdates()
        published()
        unfinished = nil
        MapController.shared.clearShownTrack()
        pushLiveTrack(force: true)
        FeatureHooks.hikeStartedListeners.forEach { $0(id, name) }
    }

    /// Pauses: the GPS goes off (TrackingService.pause). `rewindMs` is time already counted as hiking that turned out
    /// to be a drive.
    func pause(rewindMs: Int64 = 0) {
        guard let id = track.hikeId, track.status == .recording else { return }
        flushHeld()
        stopUpdates()
        Store.shared.setHikeStatus(id, .paused)
        track.pause(rewindMs: rewindMs, nowMs: nowMs())
        checkpoint(force: true)
        published()
    }

    func resume() {
        guard let id = track.hikeId, track.status == .paused else { return }
        withLocationPermission { [weak self] in
            guard let self, self.track.hikeId == id, self.track.status == .paused else { return }
            self.segment += 1
            self.pipeline.reset()
            HikeNotifications.shared.cancel(.autoPause)
            Store.shared.setHikeStatus(id, .recording)
            self.track.resume(nowMs: nowMs())
            self.startUpdates()
            self.published()
        }
    }

    /// "Finish hike?" (MapScreen.confirmFinish).
    func confirmFinish() {
        AppModel.shared.choose("Finish hike?", "Recording stops and the hike is saved. You can export it as GPX afterwards.",
                               options: [("Finish", { HikeRecorder.shared.finish() })], cancel: "Keep recording")
    }

    /// Stops recording and saves the hike with its final statistics (TrackingService.finish), then shows it.
    func finish() {
        stopUpdates()
        HikeNotifications.shared.cancel(.autoPause)
        guard let id = track.hikeId else { return }
        flushHeld()
        let active = track.activeMs(nowMs())
        Store.shared.finalizeHike(id, endMs: nowMs(), activeDurationMs: active)
        track.end()
        published()
        pushLiveTrack(force: true)
        refreshUnfinished()
        FeatureHooks.hikeFinishedListeners.forEach { $0(id) }
        HikesFeature.openHike(id)
    }

    /// "Finish" on the recover card: saves the interrupted hike as it stands (its end is now).
    func finishUnfinished(_ h: HikeMeta) {
        guard track.status == .idle, Store.shared.hike(h.id)?.status != .done else { return }
        dismissOffer()
        let meta = Store.shared.finalizeHike(h.id, endMs: nowMs(), activeDurationMs: nil)
        refreshUnfinished()
        guard let meta else { return }
        FeatureHooks.hikeFinishedListeners.forEach { $0(meta.id) }
        HikesFeature.openHike(meta.id)
    }

    /// The auto-pause notification's Resume (the app comes to the front for it).
    func resumeFromNotification() {
        if track.status == .paused {
            resume()
        } else if track.status == .idle, let h = Store.shared.unfinishedHike() {
            resumeHike(h.id)
        }
        Navigator.shared.showMap()
    }

    /// The auto-pause notification's Finish, which works without opening the app.
    func finishFromNotification() {
        if track.status != .idle {
            finish()
        } else if let h = Store.shared.unfinishedHike(), h.status == .paused {
            finishUnfinished(h)
        }
    }

    // MARK: Fixes

    private func onFix(_ fix: Fix) {
        if let kPa = LocationHub.shared.pressureKPa { storm.onPressure(kPa * 10) }
        let verticalAccuracy = fix.location.verticalAccuracy >= 0 ? fix.location.verticalAccuracy : Double(fix.accuracyM) * 1.5
        storm.onFix(gpsAltitudeM: fix.gpsAltitudeM, accuracyM: verticalAccuracy, nowMs: nowMs())
        guard track.status == .recording, track.hikeId != nil else { return }
        let accuracy: Float? = fix.location.horizontalAccuracy >= 0 ? Float(fix.location.horizontalAccuracy) : nil
        switch pipeline.onFix(fix.trackPoint(), steadyMs: fix.timeMs, accuracyM: accuracy, speedMps: fix.speedMps,
                              autoPauseInVehicle: Prefs.shared.autoPauseInVehicle) {
        case .autoPause(let rewindMs):
            autoPause(rewindMs)
            return
        case .store(let points):
            points.forEach(store)
        }
        checkpoint(force: false)
        checkWeather()
    }

    private func store(_ p: TrackPoint) {
        guard let id = track.hikeId else { return }
        Store.shared.appendHikePoint(id, seq: seq, segment: segment, p)
        seq += 1
        track.add(p)
        revision &+= 1
        pushLiveTrack()
    }

    /// Writes the fixes held back during a fast stretch that turned out not to be a drive.
    private func flushHeld() {
        pipeline.flushHeld().forEach(store)
    }

    /// The hiker is in a vehicle (they forgot to pause at the car park): the drive's fixes are dropped, its first half
    /// minute comes off the hiking time, and the hike pauses, which also switches the GPS off.
    private func autoPause(_ rewindMs: Int64) {
        pause(rewindMs: rewindMs)
        HikeNotifications.shared.post(.autoPause, title: HikeText.autoPauseTitle, body: HikeText.autoPauseText,
                                      category: HikeNotifications.autoPauseCategory)
    }

    /// Saves the running statistics every 30 seconds, so an interrupted recording keeps sensible figures.
    private func checkpoint(force: Bool) {
        let now = nowMs()
        if !force && now - lastCheckpointMs < 30_000 { return }
        lastCheckpointMs = now
        guard let id = track.hikeId else { return }
        Store.shared.updateHikeLive(id, activeMs: track.activeMs(now), distanceM: track.distanceM, ascentM: track.ascentM,
                                    descentM: track.descentM, points: track.points.count)
    }

    /// The barometer's storm alarm: warns at most every 3 hours while sea-level pressure falls fast.
    private func checkWeather() {
        guard let change = storm.alertDue(nowMs: nowMs()) else { return }
        HikeNotifications.shared.post(.weather, title: HikeText.weatherTitle, body: HikeText.weatherWarning(changeHpa: change))
    }

    private func startUpdates() { LocationHub.shared.setRecording(true) }

    private func stopUpdates() { LocationHub.shared.setRecording(false) }

    // MARK: Permission

    /// Runs `then` once TrailMind may record: precise location while in use (MainActivity.withLocationPermission).
    private func withLocationPermission(_ then: @escaping () -> Void) {
        let hub = LocationHub.shared
        switch hub.authorization {
        case .notDetermined:
            pendingStart = then
            hub.requestPermission()
        case .denied, .restricted:
            pendingStart = nil
            locationNeeded()
        default:
            pendingStart = nil
            if hub.fullAccuracy { then() } else { preciseNeeded() }
        }
    }

    private func authorizationChanged() {
        let hub = LocationHub.shared
        if let then = pendingStart, hub.authorization != .notDetermined {
            pendingStart = nil
            if !hub.hasPermission { locationNeeded() } else if hub.fullAccuracy { then() } else { preciseNeeded() }
        }
        if track.status == .recording && !hub.hasPermission {
            HikeNotifications.shared.post(.locationOff, title: "Hike paused",
                                          body: "Location permission missing. Allow location for TrailMind in Settings, then tap Resume.")
            pause()
        }
    }

    private func locationNeeded() {
        AppModel.shared.choose("Location permission needed",
                               "TrailMind uses your location only on this device, to show you on the map, record hikes and guide you along routes. Nothing is uploaded.",
                               options: [("Settings", { AppModel.shared.openSettings() })], cancel: "Not now")
    }

    private func preciseNeeded() {
        AppModel.shared.choose("Precise location needed",
                               "Approximate location only: tracking needs precise location. Turn on Precise Location for TrailMind in Settings.",
                               options: [("Settings", { AppModel.shared.openSettings() })], cancel: "Not now")
    }

    // MARK: Recovery

    private func refreshUnfinished() {
        guard track.status == .idle else {
            if unfinished != nil { unfinished = nil }
            return
        }
        let h = Store.shared.unfinishedHike()
        if h != unfinished { unfinished = h }
        if let dialog = offerDialogId, AppModel.shared.dialog?.id == dialog, h == nil { dismissOffer() }
    }

    /// Offers once, at launch, to recover a hike whose recording was interrupted (the card on the map keeps offering).
    private func offerRecovery() {
        guard UIApplication.shared.applicationState == .active else { return }
        offerPending = false
        let prefs = Prefs.shared
        guard prefs.onboardingAccepted, track.status == .idle, let h = Store.shared.unfinishedHike(),
              prefs.unfinishedHikeOffered != h.id, AppModel.shared.dialog == nil else { return }
        prefs.unfinishedHikeOffered = h.id
        AppModel.shared.choose("Unfinished recording: \(h.name)", Self.recoverDetail(h), options: [
            ("Resume", { HikeRecorder.shared.resumeHike(h.id) }),
            ("Finish", { HikeRecorder.shared.finishUnfinished(h) }),
        ], cancel: "Later")
        offerDialogId = AppModel.shared.dialog?.id
    }

    private func dismissOffer() {
        if let id = offerDialogId, AppModel.shared.dialog?.id == id { AppModel.shared.dialog = nil }
        offerDialogId = nil
    }

    static func recoverDetail(_ h: HikeMeta) -> String {
        h.status == .paused ? "Recording was paused or interrupted." : "The app was closed while recording."
    }

    // MARK: Publishing

    private func published() {
        if status != track.status { status = track.status }
        if hikeId != track.hikeId { hikeId = track.hikeId }
        if hikeName != track.hikeName { hikeName = track.hikeName }
        revision &+= 1
    }

    /// The live line on the map, at most every two seconds and not while the app is in the background.
    private func pushLiveTrack(force: Bool = false) {
        if !force && UIApplication.shared.applicationState == .background { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastLinePush) < 2 {
            if !linePushScheduled {
                linePushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.linePushScheduled = false
                    self?.pushLiveTrack()
                }
            }
            return
        }
        lastLinePush = now
        MapController.shared.setLiveTrack(track.line)
    }
}
