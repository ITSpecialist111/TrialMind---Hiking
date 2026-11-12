import Foundation

/// The fall alarm's stages, numbered as Android's FallAlert.Stage (the number is kept in Prefs.fallStage, which the trip
/// group reads too). iPhone never uses `sending`: iOS lets no app send a text by itself, so the SOS text is always made
/// ready for the user to send in Messages.
enum FallAlarmStage: Int {
    case none = 0, countdown, textReady, sending, sent
}

/// The running fall alarm or SOS (frontier/FallAlert.kt): when it started, what the text says and where it went.
struct FallAlarmState: Hashable {
    static let countdownMs: Int64 = 60_000
    static let noResponse = "Possible fall, no response"
    static let fallHelp = "Fall, I need help"
    static let help = "I need help"

    var stage: FallAlarmStage = .none
    /// When the alarm started (0 = none). Notification actions carry it, so ones from an earlier alarm are ignored.
    var alertMs: Int64 = 0
    var situation = ""
    /// Messages reported that sending failed.
    var failed = false
    /// When the SOS text was sent: the time written in it.
    var sentMs: Int64 = 0
    /// The number the SOS text went to, which "I'm OK" tells, even if the contact is changed meanwhile.
    var recipient = ""

    var deadlineMs: Int64 { alertMs + Self.countdownMs }

    /// The alarm is running and needs the user (FallAlert.start ignores a second fall while one is).
    var running: Bool { stage == .countdown || stage == .textReady || stage == .sending }

    /// After a detected fall: the countdown starts, unless an alarm is already running. True if it started.
    mutating func start(_ nowMs: Int64) -> Bool {
        if running { return false }
        begin(nowMs)
        stage = .countdown
        return true
    }

    /// The user asks for help now: the SOS text is made ready (FallAlert.sendNow).
    mutating func sendNow(_ nowMs: Int64, situation: String = FallAlarmState.fallHelp) {
        if stage == .sending { return }
        if stage == .none || stage == .sent { begin(nowMs) }
        self.situation = situation
        failed = false
        stage = .textReady
    }

    /// The countdown ran out with no answer (FallAlert.onAlarm). True if that moved the alarm on.
    mutating func countdownEnded() -> Bool {
        guard stage == .countdown else { return false }
        situation = Self.noResponse
        stage = .textReady
        return true
    }

    /// Messages reports the SOS text sent to `number`; `textMs` is the time written in it.
    mutating func textSent(to number: String, textMs: Int64) {
        guard stage == .textReady || stage == .sending else { return }
        recipient = number
        sentMs = textMs
        failed = false
        stage = .sent
    }

    /// Messages could not send it: the text stays ready to try again.
    mutating func textFailed() {
        if stage == .textReady { failed = true }
    }

    /// "I'm OK": the alarm stops and everything about it is cleared.
    mutating func ok() {
        self = FallAlarmState()
    }

    /// The heading while the SOS text is ready (FallAlertActivity's TEXT_READY titles).
    var readyTitle: String {
        if failed { return "Your SOS text didn't send" }
        if situation == Self.noResponse { return "No answer to the fall alarm" }
        return "Send your SOS text"
    }

    /// Whole seconds left on the countdown, never below zero.
    func secondsLeft(_ nowMs: Int64) -> Int64 { max((deadlineMs - nowMs) / 1_000, 0) }

    /// The countdown as the alarm shows it: "1:00", "0:09".
    func countdownText(_ nowMs: Int64) -> String {
        let left = secondsLeft(nowMs)
        return "\(left / 60):" + String(left % 60).padStart(2, "0")
    }

    private mutating func begin(_ nowMs: Int64) {
        alertMs = nowMs
        situation = Self.noResponse
        failed = false
        sentMs = 0
        recipient = ""
    }
}

/// When check-in reminders fall due (location/CheckIn.kt): at the planned return time, then a follow-up half an hour later.
enum CheckInSchedule {
    static let extendMs: Int64 = 30 * 60_000
    /// The check-in dialog's first three choices: the suggested time, then half an hour and an hour later.
    static let choiceOffsetsMs: [Int64] = [0, 30 * 60_000, 60 * 60_000]

    /// The stage once the reminders due by `nowMs` have gone (0 none yet, 1 the return-time reminder, 2 overdue), or nil
    /// when nothing changes (CheckIn.check).
    static func check(dueMs: Int64, stage: Int, nowMs: Int64) -> Int? {
        if dueMs <= 0 || stage >= 2 || nowMs < (stage == 1 ? TripReadiness.followUpMs(dueMs) : dueMs) { return nil }
        let overdue = stage == 1 || nowMs >= TripReadiness.followUpMs(dueMs)
        return overdue ? 2 : 1
    }

    /// The time the check-in dialog suggests: the check-in already set, or the walk's planning time and a half from now.
    static func suggestedMs(activeDueMs: Int64, nowMs: Int64, planningMinutes: Double) -> Int64 {
        activeDueMs > nowMs ? activeDueMs : TripReadiness.defaultReturnMs(nowMs, planningMinutes: planningMinutes)
    }

    /// A return time picked on the clock, on the suggested day, or the next day if that time has passed.
    static func pickedMs(hour: Int, minute: Int, suggestedMs: Int64, nowMs: Int64, calendar: Calendar) -> Int64 {
        let base = Date(timeIntervalSince1970: Double(suggestedMs) / 1000)
        var parts = calendar.dateComponents([.year, .month, .day], from: base)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        parts.nanosecond = 0
        var date = calendar.date(from: parts) ?? base
        if Int64((date.timeIntervalSince1970 * 1000).rounded()) <= nowMs {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
