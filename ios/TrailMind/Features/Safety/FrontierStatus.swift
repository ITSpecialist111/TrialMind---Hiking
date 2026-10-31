import Combine
import Foundation
import UIKit

/// Frontier group safety's state on this phone (frontier/FrontierCoordinator.kt): local location heartbeats every 30
/// seconds while sharing is on, the emergency status a detected fall sets, and the status lines the Safety page shows.
/// Android also watches for satellite networks and sends this telemetry over satellite data; iOS gives apps neither, so
/// that part stays on Android.
final class FrontierStatus: ObservableObject {
    static let shared = FrontierStatus()
    static let heartbeatIntervalMs: Int64 = 30_000
    static let heartbeatRetentionMs: Int64 = 10 * 60_000

    @Published private(set) var lastHeartbeatMs: Int64 = 0
    @Published private(set) var status: EmergencyStatus
    let deviceId: String

    private var listener: UUID?
    private var bag = Set<AnyCancellable>()
    private var started = false

    init() {
        let prefs = Prefs.shared
        status = EmergencyStatus.fromWire(prefs.frontierEmergencyStatus)
        if KotlinText.isBlank(prefs.frontierDeviceId) {
            prefs.frontierDeviceId = FrontierCompat.hex((0..<4).map { _ in UInt8.random(in: 0...255) })
        }
        deviceId = prefs.frontierDeviceId
    }

    func start() {
        guard !started else { return }
        started = true
        let prefs = Prefs.shared
        prefs.$frontierEnabled.merge(with: prefs.$frontierHeartbeatsEnabled).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &bag)
        applySettings()
    }

    /// Heartbeats while Frontier and position sharing are on (FrontierCoordinator.applySettings).
    func applySettings() {
        let prefs = Prefs.shared
        if prefs.frontierEnabled && prefs.frontierHeartbeatsEnabled {
            if listener == nil { listener = LocationHub.shared.addListener { [weak self] fix in self?.onFix(fix) } }
        } else if let id = listener {
            LocationHub.shared.removeListener(id)
            listener = nil
        }
        objectWillChange.send()
    }

    /// A detected fall: the emergency status, a heartbeat that carries it, and the alarm (FrontierCoordinator.recordFall).
    func recordFall(_ fall: DetectedFall) {
        let prefs = Prefs.shared
        guard prefs.frontierEnabled && prefs.frontierFallDetectionEnabled else { return }
        status = .fallDetected
        prefs.frontierEmergencyStatus = status.wireValue
        if let fix = LocationHub.shared.latest { store(fix, nowMs()) }
        FallAlarm.shared.trigger()
    }

    func clearEmergency() {
        status = .ok
        Prefs.shared.frontierEmergencyStatus = EmergencyStatus.ok.wireValue
        if let fix = LocationHub.shared.latest { store(fix, nowMs()) }
    }

    var statusText: String { SafetyText.frontierStatus(enabled: Prefs.shared.frontierEnabled) }

    func heartbeatText(_ now: Int64 = nowMs()) -> String {
        let prefs = Prefs.shared
        return SafetyText.heartbeat(enabled: prefs.frontierEnabled, heartbeats: prefs.frontierHeartbeatsEnabled,
                                    lastHeartbeatMs: lastHeartbeatMs, nowMs: now)
    }

    var emergencyText: String { SafetyText.emergency(status) }

    private func onFix(_ fix: Fix) {
        let now = nowMs()
        if now - lastHeartbeatMs < Self.heartbeatIntervalMs { return }
        lastHeartbeatMs = now
        store(fix, now)
        Store.shared.pruneMeshHeartbeats(receivedBeforeMs: now - Self.heartbeatRetentionMs)
    }

    private func store(_ fix: Fix, _ now: Int64) {
        let battery = SafetyFormat.batteryPercent()
        let row = HeartbeatRow(hikerId: deviceId, latitude: fix.lat, longitude: fix.lon, altitudeM: kRound(fix.altitudeM ?? 0),
                               batteryPercent: battery < 0 ? 0 : battery.clamped(0, 100),
                               timestampS: fix.timeMs > 0 ? fix.timeMs / 1_000 : now / 1_000, status: status.wireValue, triageCode: 0)
        Store.shared.upsertMeshHeartbeat(row, receivedMs: now)
    }
}
