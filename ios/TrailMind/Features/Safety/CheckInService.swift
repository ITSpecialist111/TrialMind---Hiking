import SwiftUI
import UIKit

/// Return-time check-ins (location/CheckIn.kt): a reminder at the planned return time and a follow-up half an hour later,
/// each with "I'm OK, +30 min", "I'm back" and "Text" your contact. iOS shows both from a schedule set now, as Android's
/// alarms do, so they come even if TrailMind has been closed. TrailMind reminds you on this phone only: it never texts
/// anyone by itself.
final class CheckInService {
    static let shared = CheckInService()
    private static let halfHourMs: Int64 = 30 * 60_000

    private var started = false
    private var timer: Timer?
    private var contactSeen = ""

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.arm()
        }
        LocationHub.shared.addListener { [weak self] _ in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.check() }
        contactSeen = Prefs.shared.emergencyContact
        arm()
    }

    /// Sets a check-in, replacing any before it (CheckIn.set).
    func set(route: String, dueMs: Int64, routeId: Int64) {
        let prefs = Prefs.shared
        SafetyNotifications.shared.cancel([.checkInDue, .checkInOverdue])
        prefs.checkInRoute = route
        prefs.checkInRouteId = routeId
        prefs.checkInStage = 0
        prefs.checkInDueMs = dueMs
        arm()
    }

    func clear() {
        let prefs = Prefs.shared
        prefs.checkInDueMs = 0
        prefs.checkInRoute = ""
        prefs.checkInRouteId = 0
        prefs.checkInStage = 0
        SafetyNotifications.shared.cancel([.checkInDue, .checkInOverdue])
    }

    /// Catches up on reminders that fell due, then schedules those still to come (CheckIn.arm). Scheduling the same
    /// reminder again replaces it, so this is safe to run whenever TrailMind comes to the front.
    func arm() {
        let prefs = Prefs.shared
        contactSeen = prefs.emergencyContact
        let due = prefs.checkInDueMs
        guard due > 0 else { return }
        check()
        let now = nowMs()
        if prefs.checkInStage == 0 && due > now { schedule(.checkInDue, overdue: false, atMs: due) }
        let followUp = TripReadiness.followUpMs(due)
        if prefs.checkInStage < 2 && followUp > now { schedule(.checkInOverdue, overdue: true, atMs: followUp) }
    }

    /// Moves the stage on for reminders that have come due (CheckIn.check); iOS has already shown them.
    func check() {
        let prefs = Prefs.shared
        if let stage = CheckInSchedule.check(dueMs: prefs.checkInDueMs, stage: prefs.checkInStage, nowMs: nowMs()) {
            prefs.checkInStage = stage
        }
        // The reminders offer "Text" only with a contact to text: schedule them again when that changes.
        if prefs.emergencyContact != contactSeen && prefs.checkInDueMs > 0 { arm() }
    }

    private func schedule(_ id: SafetyNotifications.Id, overdue: Bool, atMs: Int64) {
        let prefs = Prefs.shared
        let due = prefs.checkInDueMs
        let category = KotlinText.isBlank(prefs.emergencyContact) ? SafetyNotifications.Category.checkIn
            : SafetyNotifications.Category.checkInWithText
        SafetyNotifications.shared.post(id, title: CheckInText.title(overdue: overdue),
                                        body: CheckInText.body(overdue: overdue, dueTime: SafetyFormat.clock(due)),
                                        category: category, at: Date(timeIntervalSince1970: Double(atMs) / 1000),
                                        userInfo: ["due": NSNumber(value: due)])
    }

    // MARK: Notification actions (reminders from an earlier check-in are ignored)

    /// "I'm OK, +30 min": the check-in moves to half an hour from now.
    func extend(due: Int64) {
        let prefs = Prefs.shared
        guard due == prefs.checkInDueMs, prefs.checkInDueMs > 0 else { return }
        set(route: prefs.checkInRoute, dueMs: nowMs() + Self.halfHourMs, routeId: prefs.checkInRouteId)
    }

    /// "I'm back": the check-in is over.
    func back(due: Int64) {
        guard due == Prefs.shared.checkInDueMs else { return }
        clear()
    }

    /// "Text" the contact: Messages opens with your position, battery and route for you to send.
    func textContact(due: Int64) {
        SafetyUI.whenReady { SafetyMessages.shared.compose(Prefs.shared.emergencyContact, self.smsText()) }
    }

    /// The running-late text (CheckIn.smsText): the route, where you are if the phone knows from the last 15 minutes,
    /// the time and the battery.
    func smsText() -> String {
        let now = nowMs()
        return TripReadiness.sms(routeName: Prefs.shared.checkInRoute, location: SafetyLocation.whereNow(now)?.latLon,
                                 time: SafetyFormat.clockForText(now), batteryPercent: SafetyFormat.batteryPercent())
    }

    /// The Safety page's status line.
    var statusLine: String {
        let prefs = Prefs.shared
        let due = prefs.checkInDueMs
        return SafetyText.checkIn(dueTime: due > 0 ? SafetyFormat.clock(due) : nil, route: prefs.checkInRoute)
    }
}

/// The check-in dialog (ui/CheckInUi.kt pickCheckIn): the suggested return time, half an hour or an hour later, or a time
/// chosen on the clock.
enum CheckInUI {
    /// For the walk on hand: the check-in already set, else the followed route, else "my walk" (SafetyPage's button).
    static func pickForCurrentWalk(onChange: (() -> Void)? = nil) {
        let prefs = Prefs.shared
        let due = prefs.checkInDueMs
        let followed = prefs.activeRouteId > 0 ? Store.shared.route(prefs.activeRouteId) : nil
        let route = KotlinText.isBlank(prefs.checkInRoute) ? (followed?.name ?? "my walk") : prefs.checkInRoute
        let routeId = due > 0 ? prefs.checkInRouteId : (followed?.id ?? 0)
        pick(route: route, planningMinutes: 60, routeId: routeId, onChange: onChange)
    }

    static func pick(route: String, planningMinutes: Double, routeId: Int64, onChange: (() -> Void)? = nil) {
        let suggested = CheckInSchedule.suggestedMs(activeDueMs: Prefs.shared.checkInDueMs, nowMs: nowMs(),
                                                    planningMinutes: planningMinutes)
        let choices = CheckInText.choices(SafetyFormat.clock(suggested))
        let offsets = CheckInSchedule.choiceOffsetsMs
        var options: [(String, () -> Void)] = (0..<3).map { i in
            (choices[i], { set(route: route, dueMs: suggested + offsets[i], routeId: routeId, onChange: onChange) })
        }
        options.append((choices[3], {
            SafetyUI.afterDialog {
                SafetyUI.sheet { close in
                    CheckInTimeSheet(route: route, suggestedMs: suggested, close: close) { dueMs in
                        set(route: route, dueMs: dueMs, routeId: routeId, onChange: onChange)
                    }
                }
            }
        }))
        AppModel.shared.choose(CheckInText.dialogTitle(route), nil, options: options)
    }

    private static func set(route: String, dueMs: Int64, routeId: Int64, onChange: (() -> Void)?) {
        CheckInService.shared.set(route: route, dueMs: dueMs, routeId: routeId)
        onChange?()
        // showCheckInStatus: say when the reminders can't come.
        SafetyNotifications.shared.requestAuthorization { allowed in
            if allowed {
                AppModel.shared.toast(CheckInText.set(SafetyFormat.clock(dueMs)))
            } else {
                SafetyUI.afterDialog {
                    AppModel.shared.confirm("Check-in notifications are off",
                                            "Allow notifications for TrailMind in Settings to receive this alert.", ok: "Fix") {
                        AppModel.shared.openSettings()
                    }
                }
            }
        }
    }
}

/// "Choose return time": a clock to pick the time on; a time already past today means tomorrow.
private struct CheckInTimeSheet: View {
    @Environment(\.palette) private var p
    let route: String
    let suggestedMs: Int64
    let close: () -> Void
    let done: (Int64) -> Void
    @State private var time: Date

    init(route: String, suggestedMs: Int64, close: @escaping () -> Void, done: @escaping (Int64) -> Void) {
        self.route = route
        self.suggestedMs = suggestedMs
        self.close = close
        self.done = done
        _time = State(initialValue: Date(timeIntervalSince1970: Double(suggestedMs) / 1000))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TMText("Choose return time", .headline)
                TMText(CheckInText.dialogTitle(route), .caption)
                DatePicker("Return time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                ActionRow {
                    TMButton("Set check-in", icon: nil, style: .filled) {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        let due = CheckInSchedule.pickedMs(hour: parts.hour ?? 0, minute: parts.minute ?? 0, suggestedMs: suggestedMs,
                                                           nowMs: nowMs(), calendar: .current)
                        close()
                        SafetyUI.afterDialog { done(due) }
                    }
                    TMButton("Cancel", style: .text) { close() }
                }
            }
            .padding(20)
        }
    }
}
