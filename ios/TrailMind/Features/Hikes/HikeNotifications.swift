import AudioToolbox
import Foundation
import UIKit
import UserNotifications

/// Local notifications for recording and guidance (the Android "Navigation alerts" channel): off route, daylight,
/// weather, and the auto-pause in a vehicle with Resume and Finish actions. iOS has one notification delegate per app,
/// so this one handles only TrailMind hike notifications and passes everything else to the delegate set before it.
final class HikeNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HikeNotifications()

    enum Id: String, CaseIterable {
        case offRoute = "trailmind.hike.off-route"
        case daylight = "trailmind.hike.daylight"
        case dusk = "trailmind.hike.dusk"
        case weather = "trailmind.hike.weather"
        case autoPause = "trailmind.hike.auto-pause"
        case locationOff = "trailmind.hike.location-off"
    }

    static let autoPauseCategory = "trailmind.hike.auto-pause"
    static let resumeAction = "trailmind.hike.resume"
    static let finishAction = "trailmind.hike.finish"
    private static let prefix = "trailmind.hike."

    private let center = UNUserNotificationCenter.current()
    private weak var previous: UNUserNotificationCenterDelegate?
    private var installed = false

    /// Becomes the notification delegate (keeping the one before it) and adds the auto-pause actions to any categories
    /// other features have registered.
    func install() {
        guard !installed else { return }
        installed = true
        if let current = center.delegate, current !== self { previous = current }
        center.delegate = self
        // Resume needs the app in front: iOS only starts background location from the foreground.
        let resume = UNNotificationAction(identifier: Self.resumeAction, title: "Resume", options: [.foreground])
        let finish = UNNotificationAction(identifier: Self.finishAction, title: "Finish", options: [])
        let category = UNNotificationCategory(identifier: Self.autoPauseCategory, actions: [resume, finish], intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.autoPauseCategory }
            all.insert(category)
            self.center.setNotificationCategories(all)
        }
    }

    /// Asks once for permission to alert (Android's requestNotificationPermissionIfNeeded).
    func requestAuthorization() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func post(_ id: Id, title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "trailmind.hike"
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id.rawValue, content: content, trigger: nil))
    }

    func cancel(_ id: Id) {
        center.removeDeliveredNotifications(withIdentifiers: [id.rawValue])
        center.removePendingNotificationRequests(withIdentifiers: [id.rawValue])
    }

    private func isOurs(_ n: UNNotification) -> Bool { n.request.identifier.hasPrefix(Self.prefix) }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if !isOurs(notification), let previous,
           previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil {
            return
        }
        // Alerts show even with TrailMind open, as Android's high-importance channels do.
        completionHandler([.banner, .list, .sound])
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
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case Self.resumeAction:
                HikeRecorder.shared.resumeFromNotification()
            case Self.finishAction:
                HikeRecorder.shared.finishFromNotification()
            case UNNotificationDefaultActionIdentifier:
                Navigator.shared.showMap()
            default:
                break
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        if let notification, isOurs(notification) { return }
        _ = previous?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}

/// Vibration for alerts (NavigationController.vibrate): taps you can feel in a pocket, with the app open or recording
/// in the background.
enum HikeHaptics {
    enum Pattern {
        /// Three long pulses (0, 400, 200, 400, 200, 400 on Android).
        case offRoute
        /// One short pulse (0, 80).
        case rejoined
        /// Two long pulses (0, 400, 200, 400).
        case daylight
    }

    static func play(_ pattern: Pattern) {
        let count: Int
        let heavy: Bool
        switch pattern {
        case .offRoute: count = 3; heavy = true
        case .rejoined: count = 1; heavy = false
        case .daylight: count = 2; heavy = true
        }
        let active = UIApplication.shared.applicationState == .active
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                if active {
                    if heavy {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } else if heavy {
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
            }
        }
    }
}

/// The phone's own date and time formats (Android's DateFormat helpers), and the walking pace setting.
enum HikeTime {
    private static func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.dateStyle = date
        f.timeStyle = time
        return f
    }

    private static let timeFormat = formatter(.none, .short)
    private static let dateFormat = formatter(.short, .none)
    private static let dateTimeFormat = formatter(.medium, .short)

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// "17:30" (DateFormat.getTimeFormat / getTimeInstance(SHORT)).
    static func time(_ ms: Int64) -> String { timeFormat.string(from: date(ms)) }

    /// "31/10/2026" (DateFormat.getDateFormat).
    static func shortDate(_ ms: Int64) -> String { dateFormat.string(from: date(ms)) }

    /// "31 Oct 2026 at 09:18" (DateFormat.getDateTimeInstance(MEDIUM, SHORT), the hike list's fmtDate).
    static func dateTime(_ ms: Int64) -> String { dateTimeFormat.string(from: date(ms)) }

    static var clock: HikeClock { HikeClock(zone: .current, time: time, date: shortDate) }

    /// Prefs.pace: the walking pace and conditions, or the defaults if either is out of range.
    static var pace: PaceSettings {
        let prefs = Prefs.shared
        return (try? PaceSettings(flatSpeedKmh: prefs.flatSpeedKmh, conditionsFactor: prefs.conditionsFactor)) ?? PaceSettings()
    }
}
