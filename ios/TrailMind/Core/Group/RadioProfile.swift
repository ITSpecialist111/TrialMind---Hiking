import Foundation

enum RadioMode { case onScreen, recording, saver, boost }
enum ScanDuty { case lowPower, balanced, lowLatency }

struct RadioPlan: Hashable {
    var mode: RadioMode
    /// Advertising interval in Bluetooth units of 0.625 ms.
    var advertiseInterval: Int
    var scan: ScanDuty
    /// Restart the scan this often, so Android keeps its duty cycle (it lowers it after 10 minutes); nil to leave it.
    var scanRefreshMs: Int64?
    var relay: Bool
    var relayHelpOnly: Bool
}

/// How hard the trip-group radio works. Advertising costs little and scanning costs a lot, so every profile advertises
/// often and scans only as much as it needs: flat out while TrailMind is on screen or someone needs help, and at the
/// rate Android allows with the screen off while a hike records.
enum RadioProfile {
    static let saverBatteryPercent = 20
    static let boostMs: Int64 = 30 * 60_000

    /// Nil while TrailMind is neither on screen nor recording: the radio is off.
    static func plan(uiVisible: Bool, recording: Bool, boost: Bool, batteryPercent: Int?, powerSave: Bool, relay: Bool) -> RadioPlan? {
        if !uiVisible && !recording { return nil }
        let saver = powerSave || (batteryPercent.map { $0 <= saverBatteryPercent } ?? false)
        if boost {
            return RadioPlan(mode: .boost, advertiseInterval: 400, scan: .lowLatency, scanRefreshMs: 9 * 60_000, relay: relay, relayHelpOnly: false)
        }
        if saver {
            return RadioPlan(mode: .saver, advertiseInterval: 1600, scan: .lowPower, scanRefreshMs: nil, relay: relay, relayHelpOnly: true)
        }
        if uiVisible {
            return RadioPlan(mode: .onScreen, advertiseInterval: 800, scan: .lowLatency, scanRefreshMs: nil, relay: relay, relayHelpOnly: false)
        }
        return RadioPlan(mode: .recording, advertiseInterval: 800, scan: .balanced, scanRefreshMs: nil, relay: relay, relayHelpOnly: false)
    }
}
