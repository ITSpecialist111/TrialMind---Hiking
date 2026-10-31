import SwiftUI
import UIKit

/// Shows the fall alarm over everything in TrailMind, sheets and dialogs included, in a window of its own (Android's
/// full-screen FallAlertActivity). While it shows it is the key window, so Messages and the phone open above it.
final class FallAlarmWindow {
    static let shared = FallAlarmWindow()
    private var window: UIWindow?

    var isShowing: Bool { window.map { !$0.isHidden } ?? false }

    func show() {
        if isShowing { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ??
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AnyView(PaletteProvider { FallAlarmView() }.tint(Color(argb: 0xFF1F5B45))))
        w.rootViewController = host
        w.makeKeyAndVisible()
        window = w
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    func hide() {
        guard let w = window else { return }
        window = nil
        w.isHidden = true
        // Presentations and the keyboard go back to TrailMind's own window.
        w.windowScene?.windows.first(where: { $0 !== w && !$0.isHidden && $0.windowLevel == .normal })?.makeKey()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// The alarm screen (FallAlertActivity.render): the countdown, then the SOS text ready to send, then sent; with I'm OK,
/// the SOS text, 999 and your grid reference.
struct FallAlarmView: View {
    @Environment(\.palette) private var p
    @ObservedObject private var alarm = FallAlarm.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var safetyPrefs = SafetyPrefs.shared
    @StateObject private var fix = SafetyFixWatcher()

    var body: some View {
        let state = alarm.state
        let name = alarm.contactName
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch state.stage {
                case .countdown:
                    Text(FallAlarmText.possibleFall).tm(.label, p, color: p.danger)
                    TMText(FallAlarmText.areYouOk, .display)
                    let left = state.secondsLeft(alarm.now)
                    Text(state.countdownText(alarm.now))
                        .tm(.display, p, color: p.danger)
                        .monospacedDigit()
                        .accessibilityLabel("\(left) seconds left")
                    TMText(FallAlarmText.countdownBody(name, opensText: alarm.opensTextItself))
                case .textReady, .sending:
                    TMText(state.readyTitle, .headline)
                    TMText(FallAlarmText.readyBody(name))
                case .sent:
                    TMText(FallAlarmText.sentTitle(name), .headline)
                    TMText(FallAlarmText.sentBody(SafetyFormat.clock(state.sentMs)))
                case .none:
                    TMText("No fall alarm", .headline)
                }

                if state.stage != .none {
                    TMButton(FallAlarmText.okButton(name, tellContact: alarm.tellsContact), style: .filled, fill: true) { alarm.ok() }
                }
                switch state.stage {
                case .countdown:
                    TMButton(FallAlarmText.sendNow, icon: .sos, style: .danger, fill: true) { alarm.sendNow() }
                case .textReady, .sending:
                    TMButton(FallAlarmText.textContact(name), icon: .sos, style: .danger, fill: true) { alarm.openText() }
                default:
                    EmptyView()
                }
                if safetyPrefs.emergencySmsRegistered {
                    TMButton("Text 999", style: .outlined, fill: true) { SafetyMessages.shared.compose("999", alarm.emergencyMessage()) }
                }
                TMButton("Call 999", style: .outlined, fill: true) { SafetyUI.call("999") }
                TMText(FallAlarmText.signalNote, .caption)
                if let f = fix.fix, let grid = OsGrid.fromWgs84(f.latLon)?.format(10) {
                    Text(FallAlarmText.gridLine(grid)).tm(.title, p).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.stage != .countdown {
                    TMButton(state.stage == .none ? "Close" : "Back to TrailMind", style: .text) { alarm.putAway() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(p.bg.ignoresSafeArea())
        .onChange(of: state.stage) { _, stage in if stage == .none { FallAlarmWindow.shared.hide() } }
    }
}
