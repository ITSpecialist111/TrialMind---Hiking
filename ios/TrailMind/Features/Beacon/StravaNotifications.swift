import Foundation
import UIKit
import UserNotifications

/// Strava's notifications (StravaManager.notifyPosted / markReconnect), quiet ones as on Android's low-importance Strava
/// channel. Tapping "Posted" opens the activity; tapping "connect again" opens the Strava page. iOS has one notification
/// delegate per app, so this one handles only Strava's notifications (by their identifier) and passes everything else to
/// the delegate that was there before. Strava's notifications have no actions, so it adds no category (setting the
/// categories replaces everyone else's).
final class StravaNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StravaNotifications()

    private static let prefix = "trailmind.strava."
    private static let postedId = "trailmind.strava.posted"
    private static let reconnectId = "trailmind.strava.reconnect"

    /// The delegate before this one, kept alive here (the notification centre only holds its delegate weakly).
    private var previous: UNUserNotificationCenterDelegate?
    private var installed = false

    /// Becomes the notification centre's delegate, keeping the one before.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        if let current = center.delegate, current !== self { previous = current }
        center.delegate = self
    }

    /// Strava is linked: ask once to show notifications, and drop any "connect again" still showing.
    func linked() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.reconnectId])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func posted(_ hikeName: String, _ activityId: Int64) {
        show(Self.postedId, title: "Posted to Strava", body: hikeName, info: ["url": StravaPolicy.activityUrl(activityId)])
    }

    func reconnect() {
        show(Self.reconnectId, title: "Strava needs you to connect again", body: "Hikes are waiting to be posted. Tap to reconnect.",
             info: ["open": "strava"])
    }

    private func show(_ id: String, title: String, body: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "trailmind.strava"
        content.userInfo = info
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func isMine(_ notification: UNNotification) -> Bool { notification.request.identifier.hasPrefix(Self.prefix) }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if !isMine(notification), let previous,
           previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil {
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard isMine(response.notification) else {
            if let previous, previous.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) != nil {
                return
            }
            completionHandler()
            return
        }
        let info = response.notification.request.content.userInfo
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            if tapped {
                if let link = info["url"] as? String, let url = URL(string: link) {
                    AppModel.shared.open(url)
                } else if info["open"] as? String == "strava" {
                    StravaPage.open()
                }
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        if let notification, isMine(notification) { return }
        _ = previous?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}
