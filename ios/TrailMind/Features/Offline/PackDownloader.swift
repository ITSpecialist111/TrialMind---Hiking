import BackgroundTasks
import Foundation
import UIKit

/// Downloads offline packs one at a time (DownloadService on Android): resumable, since tiles already in the pack are
/// skipped; only from sources whose terms allow offline storage; with a polite pause between requests. A renewal
/// tapped in a notification waits behind the download that is running.
///
/// iPhone keeps an app running only briefly after you leave it, so a download carries on in the background where iOS
/// allows: while a hike records (TrailMind keeps running for the GPS) and, on iOS 26 and later, as a background task
/// whose progress iOS shows. Otherwise it pauses when iOS stops TrailMind and carries on when you come back.
final class PackDownloader {
    static let shared = PackDownloader()

    enum Stop { case user, background }

    private let lock = NSLock()
    private var queue: [Int64] = []
    private var busy = false
    private var stopRequest: Stop? = nil
    private var current: Int64? = nil
    private var currentName = ""
    private let worker = DispatchQueue(label: "trailmind.offline.download", qos: .utility)
    private var started = false
    // Main thread only.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject? = nil

    private static let resumeKey = "offline_resume_packs"
    static let purgeTaskId = "com.trailmind.ios.offline-purge"

    /// The pack being downloaded, if any.
    var activePackId: Int64? { lock.withLock { current } }
    var isBusy: Bool { lock.withLock { busy } }

    private static var permittedTasks: [String] {
        Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    }

    /// Continued-processing tasks are named after the app ("<bundle id>.offline.<pack>"); nil unless Info.plist allows them.
    private static var continuedPrefix: String? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        return permittedTasks.contains(bundle + ".offline.*") ? bundle + ".offline" : nil
    }

    /// Whether downloads can carry on in the background with iOS showing their progress.
    static var continuesInBackground: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return continuedPrefix != nil
    }

    /// What the Offline page says about downloading in the background, as Android states its own limits.
    static var backgroundNote: String {
        continuesInBackground
            ? "Downloads carry on in the background, with their progress shown by iOS. If iOS stops one, it carries on when you open TrailMind."
            : "iPhone pauses a download soon after you leave TrailMind, unless a hike is recording. It carries on when you come back."
    }

    // MARK: Start-up

    func start() {
        guard !started else { return }
        started = true
        registerBackgroundTasks()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActive()
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            DispatchQueue.global(qos: .utility).async { PackDownloader.schedulePurge() }
        }
    }

    private func registerBackgroundTasks() {
        if #available(iOS 26.0, *), let prefix = Self.continuedPrefix {
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: prefix + ".*", using: .main) { [weak self] task in
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attachContinued(task)
            }
        }
        if Self.permittedTasks.contains(Self.purgeTaskId) {
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.purgeTaskId, using: nil) { task in
                task.expirationHandler = {}
                // OS lets TrailMind keep Premium detail for 24 hours; delete what is due in the next quarter of an hour too.
                TileCache.purgeExpiredPremium(aheadMs: 15 * 60_000)
                OfflineNotifications.shared.reschedule()
                PackDownloader.schedulePurge()
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Asks iOS to run the Premium purge when the oldest 24-hour tile expires (PremiumPurgeJob). iOS chooses when it
    /// actually runs; TrailMind also purges whenever it opens, and never shows expired detail.
    static func schedulePurge() {
        guard permittedTasks.contains(purgeTaskId) else { return }
        guard let oldest = TileCache.oldestPremiumMs() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: purgeTaskId)
            return
        }
        let request = BGProcessingTaskRequest(identifier: purgeTaskId)
        request.earliestBeginDate = Date(timeIntervalSince1970: Double(oldest + TilePolicy.premiumCacheMs) / 1000)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Starting and pausing

    /// Starts a pack's download, or queues it behind the one running (DownloadService.start). Main thread.
    func download(_ id: Int64) {
        OfflineNotifications.shared.dismissRenewal(id)
        OfflineNotifications.shared.cancelPaused(id)
        setResume(id, false)
        let wasBusy: Bool = lock.withLock {
            if busy && id != current && !queue.contains(id) { queue.append(id) }
            let was = busy
            busy = true
            return was
        }
        if wasBusy { return }
        lock.withLock { stopRequest = nil }
        beginBackgroundTask()
        submitContinued(id)
        worker.async { self.drain(id) }
    }

    /// Pauses the pack being downloaded (the Pause button). A queued renewal was the user's own choice, so it still runs.
    func pause() {
        lock.withLock { if busy { stopRequest = .user } }
    }

    func stopRequested() -> Stop? { lock.withLock { stopRequest } }

    private func drain(_ first: Int64) {
        var next: Int64? = first
        while let id = next {
            run(id)
            OfflineNotifications.shared.reschedule()
            next = lock.withLock {
                if stopRequest == .background {
                    // iOS is stopping TrailMind: everything waiting carries on when it opens again.
                    let waiting = queue
                    queue.removeAll()
                    busy = false
                    stopRequest = nil
                    DispatchQueue.main.async { waiting.forEach { self.setResume($0, true) } }
                    return nil
                }
                stopRequest = nil
                if queue.isEmpty {
                    busy = false
                    return nil
                }
                return queue.removeFirst()
            }
        }
        DispatchQueue.main.async {
            // The new tiles show: the map asks for its tiles again.
            OfflinePacks.refreshMap()
            guard !self.isBusy else { return }
            self.finishBackgroundWork()
            if UIApplication.shared.applicationState == .active { self.resumeInterrupted() }
        }
    }

    /// Called by run() when a pack starts and when it stops.
    func began(_ id: Int64, name: String) {
        lock.withLock {
            current = id
            currentName = name
        }
    }

    func ended() {
        lock.withLock { current = nil }
    }

    /// iOS stopped this pack's download while TrailMind was away: carry it on when TrailMind is in front again.
    func interrupted(_ id: Int64) {
        DispatchQueue.main.async { self.setResume(id, true) }
    }

    // MARK: Background

    private func becameActive() {
        // A download iOS was about to stop carries straight on.
        let carryOn: Int64? = lock.withLock {
            guard busy, stopRequest == .background else { return nil }
            stopRequest = nil
            return current
        }
        if let id = carryOn { OfflineNotifications.shared.cancelPaused(id) }
        if isBusy { beginBackgroundTask() }
        resumeInterrupted()
    }

    private func resumeInterrupted() {
        let ids = UserDefaults.standard.array(forKey: Self.resumeKey) as? [NSNumber] ?? []
        guard !ids.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        let packs = Store.shared.packs()
        for n in ids {
            let id = n.int64Value
            guard let p = packs.first(where: { $0.id == id }), p.kind == .download, p.status != .complete else { continue }
            download(id)
        }
    }

    private func setResume(_ id: Int64, _ on: Bool) {
        var ids = Set((UserDefaults.standard.array(forKey: Self.resumeKey) as? [NSNumber] ?? []).map(\.int64Value))
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.map { NSNumber(value: $0) }, forKey: Self.resumeKey)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Offline map download") { [weak self] in
            self?.backgroundTimeUp()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// iOS is about to suspend TrailMind. While a hike records it keeps running for the GPS, and so does the download;
    /// a continued-processing task has its own time. Otherwise the download pauses until TrailMind is opened again.
    private func backgroundTimeUp() {
        if !LocationHub.shared.recording && continuedTask == nil { stopForBackground() }
        endBackgroundTask()
    }

    private func stopForBackground() {
        let stopped: (id: Int64, name: String)? = lock.withLock {
            guard busy, stopRequest == nil, let id = current else { return nil }
            stopRequest = .background
            return (id, currentName)
        }
        if let stopped { OfflineNotifications.shared.postPaused(stopped.id, name: stopped.name) }
    }

    private func finishBackgroundWork() {
        endBackgroundTask()
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: true)
        }
        continuedTask = nil
    }

    private func submitContinued(_ id: Int64) {
        guard #available(iOS 26.0, *) else { return }
        guard let prefix = Self.continuedPrefix else { return }
        let name = Store.shared.pack(id)?.name ?? "Offline map"
        let request = BGContinuedProcessingTaskRequest(identifier: "\(prefix).\(id)", title: "Downloading offline map", subtitle: name)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26.0, *)
    private func attachContinued(_ task: BGContinuedProcessingTask) {
        guard isBusy else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if UIApplication.shared.applicationState != .active && !LocationHub.shared.recording { self.stopForBackground() }
                task.setTaskCompleted(success: false)
                if self.continuedTask === task { self.continuedTask = nil }
            }
        }
        if let p = OfflinePacks.shared.progress {
            task.progress.totalUnitCount = max(p.total, 1)
            task.progress.completedUnitCount = min(p.done + p.failed, max(p.total, 1))
        }
    }

    /// Keeps iOS's progress display in step (BGContinuedProcessingTask must report progress, or iOS ends it).
    func reportProgress(_ p: PackProgress, name: String) {
        DispatchQueue.main.async {
            guard #available(iOS 26.0, *), let task = self.continuedTask as? BGContinuedProcessingTask else { return }
            task.progress.totalUnitCount = max(p.total, 1)
            task.progress.completedUnitCount = min(p.done + p.failed, max(p.total, 1))
            task.updateTitle(p.note ?? "Downloading offline map", subtitle: name)
        }
    }
}
