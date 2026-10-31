import BackgroundTasks
import Foundation
import Network

/// Posts the hikes waiting for Strava when TrailMind isn't running (strava/StravaUploadJob.kt): an iOS background task
/// that needs a network. iOS decides when it actually runs (often when the phone is idle); coming back to the app and
/// signal returning while it runs also send what's waiting, so this is the fallback.
enum StravaBackground {
    /// Listed in Info.plist under BGTaskSchedulerPermittedIdentifiers.
    static let taskId = "com.trailmind.ios.strava"
    private static var registered = false

    /// Registers the task. Must happen before launching finishes, and only once (iOS ends an app that registers twice).
    static func register(run: @escaping (_ done: @escaping () -> Void) -> Void, stop: @escaping () -> Void) {
        guard !registered else { return }
        registered = true
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            let completion = TaskCompletion(task)
            task.expirationHandler = {
                stop()
                completion.finish(success: false)
            }
            run { completion.finish(success: true) }
        }
    }

    /// Runs after `afterMs`, when the phone has a network. Replaces any run already planned.
    static func submit(afterMs: Int64) {
        let request = BGProcessingTaskRequest(identifier: taskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(afterMs, 0)) / 1000)
        // Fails in the simulator, or when Background App Refresh is off: then posting waits for the app to be opened.
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId)
    }

    /// Tells iOS the task is over exactly once, whether it finished or ran out of time first.
    private final class TaskCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var task: BGTask?

        init(_ task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            let pending = task
            task = nil
            lock.unlock()
            pending?.setTaskCompleted(success: success)
        }
    }
}

/// Whether Strava can be reached now: a network with internet that isn't a satellite link, which only carries texts and
/// small updates (Android's satellite check). Also notices signal coming back, so waiting posts go straight away.
final class StravaNetwork: @unchecked Sendable {
    static let shared = StravaNetwork()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?
    private var onReturn: (() -> Void)?

    func start(onReturn: @escaping () -> Void) {
        lock.lock()
        self.onReturn = onReturn
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: DispatchQueue(label: "com.trailmind.strava.network", qos: .utility))
    }

    /// Until the first report comes in, assume there is a network and let the request find out.
    var usable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return path.map(Self.usable) ?? true
    }

    private func update(_ new: NWPath) {
        lock.lock()
        let before = path.map(Self.usable) ?? false
        path = new
        let callback = onReturn
        lock.unlock()
        if Self.usable(new) && !before { callback?() }
    }

    private static func usable(_ path: NWPath) -> Bool {
        guard path.status == .satisfied else { return false }
        if #available(iOS 26.0, *) { return !path.isUltraConstrained }
        return true
    }
}
