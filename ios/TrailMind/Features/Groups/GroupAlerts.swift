import Foundation
import UserNotifications

/// Trip-group notifications: a member's call for help, with where they are (Android's "Trip group alerts" channel), and
/// the quiet notice while a member finds this phone up close with UWB ("Being found by your group"). Tapping the first
/// shows them on the map with their details; tapping the second opens the find. Notifications this feature doesn't own
/// go on to whichever delegate was there before, so the other features' notifications keep working.
final class GroupAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GroupAlerts()

    static let helpId = "trailmind.group.help"
    static let findId = "trailmind.group.find"
    private static let memberKey = "trailmind.group.member"

    private weak var previous: UNUserNotificationCenterDelegate?
    /// Called with the member id when the user taps a help alert.
    var onOpenMember: ((Int) -> Void)?
    /// Called with the member id when the user taps the notice that someone is finding this phone.
    var onOpenFind: ((Int) -> Void)?

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
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: GroupAlerts.helpId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func cancelHelp() { remove(GroupAlerts.helpId) }

    /// `name` started finding this phone with UWB (GroupFinder.notification on Android, shown while it runs). Quiet:
    /// no sound, and once per find rather than with every measurement.
    func postFind(name: String, memberId: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(name) is finding you with UWB"
        content.body = "Tap to see how far away they are. Keep TrailMind open on screen until they reach you."
        content.userInfo = [GroupAlerts.memberKey: memberId]
        content.threadIdentifier = "trailmind.group"
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: GroupAlerts.findId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    func cancelFind() { remove(GroupAlerts.findId) }

    private func remove(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    private static func memberId(_ notification: UNNotification) -> Int? {
        (notification.request.content.userInfo[memberKey] as? NSNumber)?.intValue
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch notification.request.identifier {
        case GroupAlerts.helpId:
            completionHandler([.banner, .list, .sound])
        case GroupAlerts.findId:
            completionHandler([.banner, .list])
        default:
            if previous?.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) == nil {
                completionHandler([.banner, .list, .sound])
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        switch notification.request.identifier {
        case GroupAlerts.helpId, GroupAlerts.findId:
            let help = notification.request.identifier == GroupAlerts.helpId
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let memberId = GroupAlerts.memberId(notification) {
                DispatchQueue.main.async {
                    if help { self.onOpenMember?(memberId) } else { self.onOpenFind?(memberId) }
                }
            }
            completionHandler()
        default:
            if previous?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil {
                completionHandler()
            }
        }
    }
}
