import SwiftUI
import UIKit

/// What the trip-group radio is doing, plus the reception log used for range tests in the field (GroupDiagnosticsPage.kt).
struct GroupDiagnosticsPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var service = GroupService.shared
    @ObservedObject private var finder = GroupService.shared.finder

    init() {}

    var body: some View {
        PageScaffold("Bluetooth diagnostics") {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    block("This phone", phoneLines)
                    block("Radio", radioLines)
                    if !service.members.isEmpty { block("Members heard", memberLines) }
                    block("UWB (Nearby Interaction)", uwbLines)
                }
            }
            if GroupFinder.supported {
                TMButton("Test UWB on this phone", style: .tonal) { finder.runSelfTest() }
            }
            ActionRow {
                TMButton("Share log (CSV)", style: .tonal) { shareLog() }
                TMButton("Clear log", style: .text) {
                    service.clearLog()
                    AppModel.shared.toast("Log cleared")
                }
            }
            TMText("The log keeps the last 5,000 frames heard, with signal strength, radio and distance from you. It stays on this " +
                   "phone unless you share it.", .caption)
        }
    }

    private func block(_ title: String, _ lines: [String]) -> some View {
        TMCard(spacing: 6) {
            TMText(title, .title)
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(p.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func yes(_ b: Bool) -> String { b ? "yes" : "no" }

    private var phoneLines: [String] {
        let bt = service.bluetooth
        return [
            "\(GroupDiagnosticsPage.model) · iOS \(UIDevice.current.systemVersion)",
            "Bluetooth: \(bt.stateText)",
            "Extended adverts (hearing Android): \(yes(bt.extendedScanning))",
            "LE Coded (long range): not on iPhone",
            "Sending Bluetooth adverts: iOS doesn't allow it",
            "iPhone link (Wi-Fi and Bluetooth): " + (service.link.error ?? (service.link.running ? "running" : "off")),
        ]
    }

    private var radioLines: [String] {
        let link = service.link
        let bt = service.bluetooth
        var lines: [String] = []
        if let plan = service.plan {
            lines.append("Profile: \(modeName(plan.mode)) · sends every \(plan.mode == .boost ? "2" : "5") s and on moving 10 m")
        } else {
            lines.append("Profile: off")
        }
        lines.append("iPhone link: " + (link.running ? "on as \(link.name ?? "?")" + (link.advertising ? ", advertising" : ", listening only") : "off"))
        lines.append("iPhones: \(link.nearbyCount) of the group nearby, \(link.connectedPeers.count) connected")
        lines.append("Sent \(link.sent) messages" + (link.sendFailures > 0 ? " (\(link.sendFailures) failed)" : "") + ", received \(link.received)")
        let scanFor = bt.scanStartedAt.map { GroupText.age(Int64(-$0.timeIntervalSinceNow)) } ?? "?"
        lines.append("Scan: " + (bt.scanning ? "on for \(scanFor)" : "off") + (bt.problem.map { " · \($0)" } ?? ""))
        lines.append("Heard \(bt.received) Bluetooth adverts from Android phones")
        lines.append("Opened \(service.opened) · not ours or unreadable \(service.unreadable)")
        lines.append("Clock: this iPhone's (iOS reports no GPS time) · tag epoch \(GroupKeys.epoch(service.nowS()))")
        lines.append("Log: \(service.logCount) frames")
        return lines
    }

    private var memberLines: [String] {
        service.members.map { peer in
            let name = String(service.nameOf(peer).prefix(14)).padding(toLength: 14, withPad: " ", startingAt: 0)
            let direct = peer.lastDirectMs > 0 ? GroupText.age((nowMs() - peer.lastDirectMs) / 1_000) + " ago" : "never"
            let via = service.viaIPhone(peer.memberId) ? "iPhone link" : "\(peer.rssi.map(String.init) ?? "?") dBm \(peer.coded ? "coded" : "1M   ")"
            let hops = peer.position.map { " · hops \($0.hops)" } ?? ""
            let caps = peer.position?.capabilities ?? 0
            let uwb = caps & GroupIPhone.capNearbyInteraction != 0 ? " · UWB (iPhone)"
                : (caps & (GroupFrames.capUwb | GroupFrames.capUwbStatic) != 0 ? " · UWB (Android)" : "")
            return "\(name) \(via) direct \(direct)\(hops)\(uwb)"
        }
    }

    private var uwbLines: [String] {
        var lines = ["State: " + (GroupFinder.supported ? (Prefs.shared.groupUwbFindable ? "ready" : "ready, not findable") : "no UWB that apps can use")]
        if GroupFinder.supported { lines.append("Distance yes · direction \(yes(GroupFinder.direction))") }
        if let s = finder.state {
            let who = service.members.first { $0.memberId == s.memberId }.map(service.nameOf) ?? GroupText.memberHex(s.memberId)
            lines.append("Session: \(s.role == .found ? "found" : "finding") \(who) · \(phaseName(s.phase))" + (s.note.map { " · \($0)" } ?? ""))
            if let m = s.measurement {
                lines.append("Last: " + (m.distanceM.map { fmt("%.2f m", $0) } ?? "?") +
                             (m.azimuthDeg.map { fmt(" · azimuth %.0f°", $0) } ?? "") +
                             (m.elevationDeg.map { fmt(" · elevation %.0f°", $0) } ?? ""))
            }
        }
        if let test = finder.selfTest { lines.append("Test: " + test) }
        return lines
    }

    private func modeName(_ mode: RadioMode) -> String {
        switch mode {
        case .onScreen: return "on_screen"
        case .recording: return "recording"
        case .saver: return "saver"
        case .boost: return "boost"
        }
    }

    private func phaseName(_ phase: GroupFinder.Phase) -> String {
        switch phase {
        case .asking: return "asking"
        case .starting: return "starting"
        case .ranging: return "ranging"
        case .ended: return "ended"
        }
    }

    private func shareLog() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        AppModel.shared.shareFile("trailmind-group-" + f.string(from: Date()) + ".csv", service.logCsv())
    }

    /// The hardware model ("iPhone17,1"), as Android shows the manufacturer and model.
    private static let model: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.isEmpty ? UIDevice.current.model : machine
    }()
}
