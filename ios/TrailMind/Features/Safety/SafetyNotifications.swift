import UIKit
import UserNotifications

/// Local notifications for check-in reminders and the fall alarm (Android's "Check-in reminders" and "Fall alarm and
/// SOS" channels). iOS has one notification delegate per app, so this one handles only notifications whose identifiers
/// start with "trailmind.safety." and passes everything else to the delegate set before it.
final class SafetyNotifications: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let shared = SafetyNotifications()
    static let prefix = "trailmind.safety."

    enum Id: String, CaseIterable {
        case checkInDue = "trailmind.safety.checkin.due"
        case checkInOverdue = "trailmind.safety.checkin.overdue"
        case fallCountdown = "trailmind.safety.fall.countdown"
        case fallReady = "trailmind.safety.fall.ready"
    }

    enum Category {
        static let checkIn = "trailmind.safety.checkin"
        static let checkInWithText = "trailmind.safety.checkin.contact"
        static let fallCountdown = "trailmind.safety.fall.countdown"
        static let fallReady = "trailmind.safety.fall.ready"
    }

    enum Action {
        static let checkInExtend = "trailmind.safety.checkin.extend"
        static let checkInBack = "trailmind.safety.checkin.back"
        static let checkInText = "trailmind.safety.checkin.text"
        static let fallOk = "trailmind.safety.fall.ok"
        static let fallSend = "trailmind.safety.fall.send"
        static let fallText = "trailmind.safety.fall.text"
    }

    /// Whether TrailMind may alert, as last read (nil until known).
    @Published private(set) var allowed: Bool? = nil

    private let center = UNUserNotificationCenter.current()
    private weak var previous: UNUserNotificationCenterDelegate?
    private var installed = false
    private var registeredTitle = ""

    /// Becomes the notification delegate, keeping the one before it, and adds the Safety actions to the categories other
    /// features have registered. Hikes registers its own at launch too, so this waits a moment before reading the list.
    func install() {
        guard !installed else { return }
        installed = true
        if let current = center.delegate, current !== self { previous = current }
        center.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.registerCategories(force: true) }
        refreshPermission()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermission()
        }
    }

    /// The action buttons, which name the emergency contact ("Text Sam"); registered again when the name changes.
    func registerCategories(force: Bool = false) {
        let prefs = Prefs.shared
        let fallName = FallAlarm.shared.contactName
        let title = prefs.emergencyContactName + "|" + fallName
        if !force && title == registeredTitle { return }
        registeredTitle = title
        let extend = UNNotificationAction(identifier: Action.checkInExtend, title: CheckInText.extendAction, options: [])
        let back = UNNotificationAction(identifier: Action.checkInBack, title: CheckInText.backAction, options: [])
        // Messages needs TrailMind in front to show the text, so these open the app.
        let textContact = UNNotificationAction(identifier: Action.checkInText,
                                               title: CheckInText.textAction(contactName: prefs.emergencyContactName), options: [.foreground])
        // Only the phone's owner may stop the alarm: the action asks for Face ID or the passcode on a locked phone.
        let ok = UNNotificationAction(identifier: Action.fallOk, title: "I'm OK", options: [.authenticationRequired])
        let send = UNNotificationAction(identifier: Action.fallSend, title: "Send SOS now", options: [.foreground])
        let text = UNNotificationAction(identifier: Action.fallText, title: FallAlarmText.textContact(fallName), options: [.foreground])
        let mine: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: Category.checkIn, actions: [extend, back], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.checkInWithText, actions: [extend, back, textContact], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.fallCountdown, actions: [ok, send], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.fallReady, actions: [text, ok], intentIdentifiers: [], options: []),
        ]
        center.getNotificationCategories { existing in
            let others = existing.filter { !$0.identifier.hasPrefix(Self.prefix) }
            self.center.setNotificationCategories(others.union(mine))
        }
    }

    /// Asks once for permission to alert; `then` runs on the main queue with the answer.
    func requestAuthorization(_ then: ((Bool) -> Void)? = nil) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async {
                        self.allowed = granted
                        then?(granted)
                    }
                }
            default:
                let ok = Self.canAlert(settings)
                DispatchQueue.main.async {
                    self.allowed = ok
                    then?(ok)
                }
            }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .notDetermined ? nil : Self.canAlert(settings)
            DispatchQueue.main.async { if self.allowed != ok { self.allowed = ok } }
        }
    }

    private static func canAlert(_ s: UNNotificationSettings) -> Bool {
        let status = s.authorizationStatus
        return (status == .authorized || status == .provisional || status == .ephemeral) && s.alertSetting != .disabled
    }

    /// Posts now (`at` nil) or at a time. Notifications already showing with the same id are replaced.
    func post(_ id: Id, title: String, body: String, category: String, at date: Date? = nil, userInfo: [String: Any] = [:],
              sound: UNNotificationSound? = .default) {
        registerCategories()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.categoryIdentifier = category
        content.threadIdentifier = "trailmind.safety"
        content.userInfo = userInfo
        var trigger: UNNotificationTrigger? = nil
        if let date {
            let seconds = date.timeIntervalSinceNow
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        }
        center.add(UNNotificationRequest(identifier: id.rawValue, content: content, trigger: trigger))
    }

    func cancel(_ ids: [Id]) {
        let names = ids.map(\.rawValue)
        center.removePendingNotificationRequests(withIdentifiers: names)
        center.removeDeliveredNotifications(withIdentifiers: names)
    }

    /// Ids still waiting to be shown; `done` runs on the main queue.
    func pending(_ done: @escaping (Set<String>) -> Void) {
        center.getPendingNotificationRequests { requests in
            let ids = Set(requests.map(\.identifier))
            DispatchQueue.main.async { done(ids) }
        }
    }

    private func isOurs(_ n: UNNotification) -> Bool { n.request.identifier.hasPrefix(Self.prefix) }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard isOurs(notification) else {
            if let previous, previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil {
                return
            }
            completionHandler([.banner, .list, .sound])
            return
        }
        let id = notification.request.identifier
        DispatchQueue.main.async {
            if id.hasPrefix("trailmind.safety.checkin") { CheckInService.shared.check() }
            if id.hasPrefix("trailmind.safety.fall") {
                FallAlarm.shared.refresh()
                // The alarm screen is already in front, sounding: no banner over it.
                if FallAlarmWindow.shared.isShowing { completionHandler([]); return }
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard isOurs(response.notification) else {
            if let previous, previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) != nil {
                return
            }
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let due = (info["due"] as? NSNumber)?.int64Value ?? -1
        let alertMs = (info["alertMs"] as? NSNumber)?.int64Value ?? -1
        DispatchQueue.main.async {
            switch action {
            case Action.checkInExtend: CheckInService.shared.extend(due: due)
            case Action.checkInBack: CheckInService.shared.back(due: due)
            case Action.checkInText: CheckInService.shared.textContact(due: due)
            case Action.fallOk: FallAlarm.shared.ok(alertMs: alertMs)
            case Action.fallSend: FallAlarm.shared.sendNowFromNotification(alertMs: alertMs)
            case Action.fallText: FallAlarm.shared.textFromNotification(alertMs: alertMs)
            case UNNotificationDefaultActionIdentifier:
                if id.hasPrefix("trailmind.safety.fall") {
                    FallAlarm.shared.showWhenReady()
                } else {
                    CheckInService.shared.check()
                    SafetyUI.whenReady { Navigator.shared.open(.safety) }
                }
            default: break
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        if let notification, isOurs(notification) { return }
        _ = previous?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
