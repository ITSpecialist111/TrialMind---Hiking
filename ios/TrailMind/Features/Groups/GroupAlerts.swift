import Foundation
import UserNotifications

/// Trip-group alerts (Android's "Trip group alerts" channel): a member's call for help, with where they are. Tapping it
/// shows them on the map with their details. Notifications this feature doesn't own go on to whichever delegate was
/// there before, so the other features' notifications keep working.
final class GroupAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GroupAlerts()

    static let helpId = "trailmind.group.help"
    private static let memberKey = "trailmind.group.member"

    private weak var previous: UNUserNotificationCenterDelegate?
    /// Called with the member id when the user taps a help alert.
    var onOpenMember: ((Int) -> Void)?

    func install() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            previous = center.delegate
            center.delegate = self
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func postHelp(title: String, text: String, memberId: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text + "\n\nTap to see them on the map and get a bearing."
        content.sound = .default
        content.userInfo = [GroupAlerts.memberKey: memberId]
        content.threadIdentifier = "trailmind.group"
        let request = UNNotificationRequest(identifier: GroupAlerts.helpId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func cancelHelp() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [GroupAlerts.helpId])
        center.removeDeliveredNotifications(withIdentifiers: [GroupAlerts.helpId])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier == GroupAlerts.helpId {
            completionHandler([.banner, .list, .sound])
        } else if previous?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) == nil {
            completionHandler([.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == GroupAlerts.helpId {
            if let memberId = response.notification.request.content.userInfo[GroupAlerts.memberKey] as? Int {
                DispatchQueue.main.async { self.onOpenMember?(memberId) }
            }
            completionHandler()
        } else if previous?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil {
            completionHandler()
        }
    }
}
