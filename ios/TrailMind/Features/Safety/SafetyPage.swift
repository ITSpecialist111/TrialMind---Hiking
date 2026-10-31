import CoreLocation
import SwiftUI

/// Safety & location (ui/Pages3.kt SafetyPage): your grid reference to read out, what3words, Frontier group safety, the
/// trip group, the emergency contact, the SOS text, the check-in, texting your location, 999 and the UK emergency
/// guidance. iOS lets no app send a text by itself, so every text opens in Messages for the user to send.
struct SafetyPage: View {
    @Environment(\.palette) private var p
    @StateObject private var position = SafetyFixWatcher()
    @StateObject private var words = SafetyWordsModel()
    @StateObject private var ticker = SafetyTicker()
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var safetyPrefs = SafetyPrefs.shared
    @ObservedObject private var alarm = FallAlarm.shared
    @ObservedObject private var frontier = FrontierStatus.shared
    @ObservedObject private var notifications = SafetyNotifications.shared
    @ObservedObject private var pressure = PressureWatch.shared
    @ObservedObject private var lookup = What3wordsLookup.shared

    init() {}

    var body: some View {
        PageScaffold("Safety & location") {
            positionCard
            ActionRow {
                TMButton("Copy", style: .tonal, fill: true) { SafetyLocation.copy() }
                TMButton("Share", icon: .share, style: .tonal, fill: true) { SafetyLocation.share() }
            }
            wordsCard
            ListItemRow(title: "Satellites & telemetry", subtitle: "GPS accuracy, speed and sensors", icon: .myLocation) {
                Navigator.shared.push(SafetyFeature.telemetryRoute)
            }
            frontierCard
            groupCard
            contactCard
            sosCard
            checkInCard
            TMButton(SafetyText.textLocationButton(prefs.emergencyContact), icon: .sos, style: .outlined) { SafetyLocation.text() }
            TMButton("Call 999", icon: .sos, style: .danger) { SafetyUI.call("999") }
            if FeatureHooks.recordingNow?().recording == true, let retrace = FeatureHooks.retrace {
                TMButton("Retrace my steps", icon: .route, style: .tonal) { retrace() }
            }
            emergencyCard
            if KotlinText.isBlank(prefs.emergencyContact) {
                TMButton("Set emergency contact", icon: .tune, style: .text) { EmergencyContactUI.edit() }
            }
        }
        .onAppear {
            SafetyFeature.start()
            ticker.start()
            LocationHub.shared.requestBarometer()
            SafetyNotifications.shared.refreshPermission()
        }
        .onDisappear {
            ticker.stop()
            words.cancel()
        }
    }

    // MARK: Position

    private var positionCard: some View {
        let now = ticker.now
        return TMCard(spacing: 6) {
            TMText("Your grid reference", .label)
            if let f = position.fix {
                let figures = SafetyText.gridFigures(f.latLon)
                Text(figures?.ten ?? Units.latLon(f.lat, f.lon))
                    .tm(.display, p)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .accessibilityLabel("Grid reference " + (figures?.ten ?? Units.latLon(f.lat, f.lon)))
                if let figures {
                    TMText("6-figure " + nb(figures.six) + " · 8-figure " + nb(figures.eight), .caption)
                }
                TMText(SafetyText.fixDetail(lat: f.lat, lon: f.lon, accuracyM: Double(f.accuracyM), altitudeM: f.altitudeM,
                                            barometric: f.baroAltitudeM != nil, ageS: (now - f.timeMs) / 1_000,
                                            imperial: prefs.imperial, pressure: pressure.summary), .caption)
            } else {
                TMText("No fix", .display)
                if position.hasPermission {
                    TMText("Waiting for GPS. Move to open ground for a better signal.", .caption)
                } else {
                    TMText("Location permission is off.", .caption)
                    TMButton("Allow location", icon: .myLocation, style: .tonal) { SafetyUI.allowLocation(position.authorization) }
                }
            }
        }
    }

    // MARK: what3words

    private var wordsCard: some View {
        TMCard(spacing: 6) {
            TMText("what3words", .title)
            HelpRow(summary: "Three words for your current position.",
                    detail: "Lookup sends this GPS position to what3words. It needs internet and your API key. GPS uncertainty may span several 3 m squares. Read back all three words and also give your grid reference or coordinates. Sharing only includes a lookup still in the same square and less than a minute old; emergency actions never wait for the network.")
            Text(words.label(position.fix))
                .tm(.body, p)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TMButton(words.busy ? "Looking up..." : "Look up three words", icon: .search, style: .tonal) { words.lookUp() }
                .disabled(words.busy)
        }
    }

    // MARK: Frontier

    private var frontierCard: some View {
        let enabled = prefs.frontierEnabled
        let fallAvailable = FallMonitor.shared.available
        return TMCard(spacing: 8) {
            TMText("Frontier group safety", .title)
            TMText(frontier.statusText, .body, color: enabled ? p.primary : p.muted)
            TMText(frontier.heartbeatText(ticker.now) + " · " + frontier.emergencyText, .caption)
            TMToggle(label: "Frontier safety features", isOn: $prefs.frontierEnabled)
            TMToggle(label: "Share my position with my trip group", isOn: $prefs.frontierHeartbeatsEnabled)
                .disabled(!enabled)
            TMToggle(label: "Detect falls while recording", isOn: $prefs.frontierFallDetectionEnabled)
                .disabled(!enabled || !fallAvailable)
            if !fallAvailable {
                TMText("Fall detection is unavailable because this phone has no accelerometer and gyroscope pair.", .caption)
            }
            TMToggle(label: "Sound the fall alarm", isOn: $prefs.fallAlarmSound, detail: "Loud, even with the phone on silent")
                .disabled(!enabled)
            TMText(SafetyText.satelliteNote, .caption)
            if frontier.status != .ok {
                // Same as "I'm OK" on the fall alarm: it also stops the alarm and offers the all-clear if an SOS went.
                TMButton("Clear Frontier emergency", icon: .close, style: .outlined) { FallAlarm.shared.ok() }
            }
        }
    }

    // MARK: Trip group

    @ViewBuilder private var groupCard: some View {
        if let open = FeatureHooks.openGroup {
            if let summary = FeatureHooks.groupSummary?() {
                TMCard(spacing: 8) {
                    TMText("Trip group", .title)
                    TMText(summary, .body, color: p.primary)
                    TMButton("Open trip group", style: .tonal) { open() }
                }
            } else {
                TMCard(spacing: 8) {
                    TMText("See your party on the map, with no signal", .title)
                    TMText("Each phone in the group shares its position straight to the others, sealed with the group's code, and passes on the others' positions so the group reaches further than one phone can. It works while TrailMind is open or a hike is recording, with no mobile signal.")
                    TMText("Range depends on phones, pockets and ground: tens of metres in woods, more in the open, and further along a strung-out group.", .caption)
                    TMButton("Create or join a group", icon: .add, style: .tonal) { open() }
                }
            }
        }
    }

    // MARK: Emergency contact

    private var contactCard: some View {
        let contact = prefs.emergencyContact
        let blank = KotlinText.isBlank(contact)
        return TMCard(spacing: 8) {
            TMText("Emergency contact", .title)
            if blank {
                TMText("Not set. Check-in reminders and the SOS text go to this person.")
            } else {
                TMText(KotlinText.isBlank(prefs.emergencyContactName) ? contact : prefs.emergencyContactName + " · " + contact)
                TMText("Check-in reminders offer to text them, and the SOS text is for them.", .caption)
            }
            ActionRow {
                TMButton("Choose from Contacts", style: .tonal) { EmergencyContactUI.pick() }
                TMButton(blank ? "Type a number" : "Edit", style: .text) { EmergencyContactUI.edit() }
            }
        }
    }

    // MARK: SOS text

    private var sosCard: some View {
        let contact = prefs.emergencyContact
        let blank = KotlinText.isBlank(contact)
        let name = alarm.contactName
        return TMCard(spacing: 8) {
            TMText("SOS text", .title)
            TMText(SafetyText.sosIntro(name), .caption)
            if prefs.frontierEnabled && prefs.frontierFallDetectionEnabled {
                if notifications.allowed == false {
                    TMBanner(message: "Notifications are off, so the fall alarm can't alert you when TrailMind isn't on screen.", danger: true)
                    TMButton("Allow notifications", style: .text) { AppModel.shared.openSettings() }
                } else if notifications.allowed == nil {
                    TMButton("Allow alarm notifications", style: .text) { SafetyNotifications.shared.requestAuthorization() }
                }
            }
            if alarm.state.stage != .none {
                TMButton("Open the fall alarm", icon: .warning, style: .danger) { alarm.showScreen() }
            }
            TMToggle(label: "Open the SOS text straight away", isOn: $prefs.sosAutoSend)
                .disabled(blank)
            TMText(SafetyText.sosAutoCaption(contact: contact, opensText: alarm.opensTextItself), .caption)
            if !blank {
                let message = alarm.message(FallAlarmState.help, at: ticker.now)
                TMText("SOS text preview", .label)
                Text(message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(p.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(p.surfaceVariant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
                TMText(SafetyText.sosLength(message), .caption)
                TMButton("Text SOS to \(name)", icon: .sos, style: .outlined) {
                    SafetyMessages.shared.compose(contact, alarm.message(FallAlarmState.help))
                }
            }
            TMText(SafetyText.cannotSendNote, .caption)
            TMDivider()
            TMText("999 by text (emergencySMS)", .title)
            TMText("A text can get through where a call can't. Register this phone for emergencySMS before you go, and you can text 999 instead.", .caption)
            TMToggle(label: "Registered for emergencySMS", isOn: $safetyPrefs.emergencySmsRegistered)
            if safetyPrefs.emergencySmsRegistered {
                TMButton("Text 999", style: .tonal) { SafetyMessages.shared.compose("999", alarm.emergencyMessage()) }
            } else {
                TMButton("Register: text 'register' to 999", style: .tonal) { SafetyMessages.shared.compose("999", "register") }
            }
        }
    }

    // MARK: Check-in

    private var checkInCard: some View {
        let due = prefs.checkInDueMs
        return TMCard(spacing: 6) {
            TMText("Check-in", .title)
            TMText(SafetyText.checkIn(dueTime: due > 0 ? SafetyFormat.clock(due) : nil, route: prefs.checkInRoute))
            TMText("TrailMind reminds you on this phone at your return time and again half an hour later. It does not send a text for you; Text opens Messages for you to send it." +
                   (KotlinText.isBlank(prefs.emergencyContact) ? " Set an emergency contact to get the Text button." : ""), .caption)
            if due > 0 && notifications.allowed == false {
                TMBanner(message: "Check-in notifications are off. Allow notifications for TrailMind in Settings to receive this alert.")
                TMButton("Fix", style: .text) { AppModel.shared.openSettings() }
            }
            ActionRow {
                TMButton(due > 0 ? "Edit" : "Set check-in", style: .tonal, fill: true) { CheckInUI.pickForCurrentWalk() }
                if due > 0 {
                    TMButton("Cancel", icon: .close, style: .text, fill: true) { CheckInService.shared.clear() }
                }
            }
        }
    }

    // MARK: Emergency guidance

    private var emergencyCard: some View {
        TMCard(color: p.dangerContainer, spacing: 6) {
            TMText("In an emergency (UK)", .title)
            Text(Self.guidance)
                .tm(.caption, p, color: p.onSurface)
                .tint(p.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The UK guidance, with 999 and 112 as links that open the phone.
    private static let guidance: AttributedString = {
        var text = AttributedString(SafetyText.emergencyGuidance)
        for number in ["999", "112"] {
            if let range = text.range(of: number) {
                text[range].link = URL(string: "tel:" + number)
                text[range].underlineStyle = Text.LineStyle.single
            }
        }
        return text
    }()
}

/// Ticks once a second while a page shows ages and countdowns (Android's freshnessTick).
final class SafetyTicker: ObservableObject {
    @Published private(set) var now: Int64 = nowMs()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        now = nowMs()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.now = nowMs() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The Safety page's what3words look-up: one at a time, cancelled when the page goes (SafetyPage.wordsRequest).
final class SafetyWordsModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var error: String? = nil
    private var task: URLSessionTask?
    private var job = 0

    func lookUp() {
        guard let fix = LocationHub.shared.latest else {
            AppModel.shared.toast("Wait for a GPS fix first.")
            return
        }
        job += 1
        let current = job
        busy = true
        error = nil
        let started = What3wordsLookup.shared.locate(fix, key: Prefs.shared.what3wordsKey) { [weak self] result in
            guard let self, current == self.job else { return }
            self.busy = false
            self.task = nil
            if case .failure(let failure) = result { self.error = failure.message }
        }
        if busy { task = started }
    }

    func cancel() {
        job += 1
        task?.cancel()
        task = nil
        busy = false
    }

    /// The three words while they still name where you are, else why not.
    func label(_ fix: Fix?) -> String {
        if let address = What3wordsLookup.shared.current(fix) { return "///" + address.words }
        if let error { return error }
        return busy ? "Looking up..." : "Not looked up, moved square, or expired. Tap to refresh."
    }
}
