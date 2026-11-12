import Foundation

/// The fall alarm's wording (frontier/FallAlertActivity.kt and FallAlert.post), as iPhone says it: iOS lets no app send
/// a text by itself, so where Android may text the contact on its own, iPhone gets the text ready for a tap on Send.
enum FallAlarmText {
    /// Who the SOS text goes to: the contact's name, else their number, else "your emergency contact"
    /// (FallAlert.contactName).
    static func contactName(number: String, contactNumber: String, contactName: String) -> String {
        let name = number == contactNumber ? (KotlinText.isBlank(contactName) ? number : contactName) : number
        return KotlinText.isBlank(name) ? "your emergency contact" : name
    }

    static let possibleFall = "Possible fall detected"
    static let areYouOk = "Are you OK?"

    /// Under the countdown: what happens if nobody answers.
    static func countdownBody(_ name: String, opensText: Bool) -> String {
        opensText ? "If you don't answer, TrailMind opens a text to \(name) with your location, ready to send."
            : "If you don't answer, TrailMind gets a text to \(name) ready for you to send."
    }

    static func readyBody(_ name: String) -> String {
        "Your text to \(name) is ready with your location. Check it, then send it."
    }

    static func sentTitle(_ name: String) -> String { "SOS text sent to \(name)" }

    static func sentBody(_ time: String) -> String { "Sent at \(time) with your location." }

    /// "I'm OK", or, once the SOS text went, the version that also opens the all-clear for that person.
    static func okButton(_ name: String, tellContact: Bool) -> String { tellContact ? "I'm OK: tell \(name)" : "I'm OK" }

    static let sendNow = "Send SOS text now"

    static func textContact(_ name: String) -> String { "Text \(name)" }

    /// Calls and texts without signal, as an iPhone can make them.
    static let signalNote = "999 calls need mobile signal. With no signal, iPhone 14 or later can text 999 by satellite " +
        "where Apple offers Emergency SOS via satellite, including the UK: call 999 and follow the prompts."

    static func gridLine(_ grid: String) -> String { "Your grid reference: \(grid)" }

    // MARK: Notifications (FallAlert.post)

    static func countdownNotification(_ name: String) -> (title: String, body: String) {
        (areYouOk, "Possible fall. If you don't answer, TrailMind gets a text to \(name) ready for you.")
    }

    static func readyNotification(_ state: FallAlarmState, _ name: String) -> (title: String, body: String) {
        (state.readyTitle, "Text \(name) your location, or call 999 if you have signal for calls.")
    }

    /// The text for everyone the SOS text went to, when the user is OK after all (sent from Messages).
    static func allClear(sentTime: String) -> String { SafetyText.allClear(sentTime: sentTime) }
}

/// The check-in reminders' wording (location/CheckIn.kt postNotification and ui/CheckInUi.kt).
enum CheckInText {
    static func title(overdue: Bool) -> String { overdue ? "Overdue check-in: please respond" : "Check in: are you OK?" }

    static func body(overdue: Bool, dueTime: String) -> String {
        overdue ? "Still no check-in since \(dueTime). Please check in or contact someone."
            : "You planned to be back by \(dueTime). Are you OK?"
    }

    static let extendAction = "I'm OK, +30 min"
    static let backAction = "I'm back"

    static func textAction(contactName: String) -> String { "Text " + (KotlinText.isBlank(contactName) ? "contact" : contactName) }

    static func dialogTitle(_ route: String) -> String { "Set check-in for \(route)" }

    /// The check-in dialog's choices for a suggested return time.
    static func choices(_ time: String) -> [String] { ["Set for \(time)", "\(time) +30 min", "\(time) +1 hour", "Choose return time"] }

    static func set(_ time: String) -> String { "Check-in set for \(time)" }

    static let notificationsOff = "Check-in saved, but notifications are off. Allow notifications to receive reminders."
}
