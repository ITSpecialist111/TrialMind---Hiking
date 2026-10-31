import Foundation
import UIKit
import UserNotifications

/// Strava's notifications (StravaManager.notifyPosted / markReconnect): quiet ones, as Android's low-importance Strava
/// channel. Tapping "Posted" opens the activity; tapping "connect again" opens the Strava page. Other features'
/// notifications are passed on to the delegate that was there before.
final class StravaNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StravaNotifications()

    static let category = "STRAVA"
    private static let prefix = "strava."
    private static let postedId = "strava.posted"
    private static let reconnectId = "strava.reconnect"

    private var previous: UNUserNotificationCenterDelegate?
    private var installed = false

    /// Becomes the notification centre's delegate, keeping the one before, and adds the Strava category to the others.
    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        previous = center.delegate
        center.delegate = self
        let mine = UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [], options: [])
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { $0.identifier != Self.category }.union([mine]))
        }
    }

    /// Strava is linked: ask once to show notifications, and drop any "connect again" still showing.
    func linked() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.reconnectId])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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
        content.categoryIdentifier = Self.category
        content.userInfo = info
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func isMine(_ notification: UNNotification) -> Bool {
        notification.request.identifier.hasPrefix(Self.prefix) || notification.request.content.categoryIdentifier == Self.category
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if isMine(notification) {
            completionHandler([.banner, .list, .sound])
        } else if previous?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) == nil {
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard isMine(response.notification) else {
            if previous?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil {
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let info = response.notification.request.content.userInfo
            DispatchQueue.main.async {
                if let link = info["url"] as? String, let url = URL(string: link) {
                    AppModel.shared.open(url)
                } else if info["open"] as? String == "strava" {
                    StravaPage.open()
                }
            }
        }
        completionHandler()
    }
}
