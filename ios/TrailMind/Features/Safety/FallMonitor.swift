import Combine
import CoreMotion
import Foundation

/// Watches for a fall while a hike records (sensor/FallMonitor.kt): the accelerometer and gyroscope at 50 Hz through the
/// core FallDetector, whose thresholds are Android's: free fall under 0.2 g, an impact over 4.5 g within half a second of
/// it, then 90 seconds without moving. It runs while the hike's GPS runs (not while paused) and Frontier fall detection
/// is on, and keeps running with the screen off because the recording keeps TrailMind running.
final class FallMonitor: ObservableObject {
    static let shared = FallMonitor()

    private let manager = SafetyMotion.manager
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "fall-monitor"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    // Touched only on `queue`.
    private let detector = FallDetector()
    private var gyro: (x: Float, y: Float, z: Float) = (0, 0, 0)
    private var altitudeM: Float? = nil

    @Published private(set) var active = false
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var started = false

    /// The phone has the accelerometer and gyroscope pair fall detection needs.
    var available: Bool { manager.isAccelerometerAvailable && manager.isGyroAvailable }

    func start() {
        guard !started else { return }
        started = true
        let prefs = Prefs.shared
        prefs.$frontierEnabled.merge(with: prefs.$frontierFallDetectionEnabled).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        // The barometer's pressure altitude goes with each sample, for the fall's height change.
        LocationHub.shared.$pressureKPa
            .sink { [weak self] kPa in
                guard let self else { return }
                let altitude = kPa.map { Float(Barometry.altitudeM($0 * 10)) }
                self.queue.addOperation { self.altitudeM = altitude }
            }
            .store(in: &bag)
        // Recording starts and stops (and pauses, which stop the GPS) are seen within two seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let prefs = Prefs.shared
        setActive(LocationHub.shared.recording && prefs.frontierEnabled && prefs.frontierFallDetectionEnabled)
    }

    private func setActive(_ on: Bool) {
        if on == active || (on && !available) { return }
        active = on
        if !on {
            manager.stopAccelerometerUpdates()
            manager.stopGyroUpdates()
            queue.addOperation { self.detector.reset() }
            return
        }
        manager.gyroUpdateInterval = 1.0 / 50
        manager.accelerometerUpdateInterval = 1.0 / 50
        manager.startGyroUpdates(to: queue) { [weak self] data, _ in
            guard let self, let r = data?.rotationRate else { return }
            self.gyro = (Float(r.x), Float(r.y), Float(r.z))
        }
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            // Core Motion reports in g; the detector takes m/s², as Android's sensor gives.
            let g: Float = 9.80665
            let a = data.acceleration
            let sample = ImuSample(timestampMs: Int64(data.timestamp * 1000), accelerationX: Float(a.x) * g,
                                   accelerationY: Float(a.y) * g, accelerationZ: Float(a.z) * g,
                                   gyroscopeX: self.gyro.x, gyroscopeY: self.gyro.y, gyroscopeZ: self.gyro.z,
                                   altitudeMeters: self.altitudeM)
            if let fall = self.detector.add(sample) {
                DispatchQueue.main.async { FrontierStatus.shared.recordFall(fall) }
            }
        }
    }
}
