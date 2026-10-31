import Foundation
import UserNotifications

/// Trip-group notifications: a member's call for help, with where they are (Android's "Trip group alerts" channel), and
/// the quiet notice while a member finds this phone up close with UWB ("Being found by your group"), with Stop as on
/// Android. Tapping the first shows them on the map with their details; tapping the second opens the find.
/// Notifications this feature doesn't own go on to whichever delegate was there before, so the other features'
/// notifications keep working.
final class GroupAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GroupAlerts()

    static let helpId = "trailmind.group.help"
    static let findId = "trailmind.group.find"
    static let findCategory = "trailmind.group.find"
    static let stopFindAction = "trailmind.group.find.stop"
    private static let memberKey = "trailmind.group.member"

    private weak var previous: UNUserNotificationCenterDelegate?
    /// Called with the member id when the user taps a help alert.
    var onOpenMember: ((Int) -> Void)?
    /// Called with the member id when the user taps the notice that someone is finding this phone.
    var onOpenFind: ((Int) -> Void)?
    /// Called when the user taps Stop on that notice.
    var onStopFind: (() -> Void)?
    private var findCategoryReady = false
    /// Bumped whenever the find notice is cancelled, so one still waiting for its category isn't posted after that.
    private var findGeneration = 0

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
        let notice = GroupText.beingFound(name)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.text
        content.userInfo = [GroupAlerts.memberKey: memberId]
        content.threadIdentifier = "trailmind.group"
        content.categoryIdentifier = GroupAlerts.findCategory
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: GroupAlerts.findId, content: content, trigger: nil)
        let generation = findGeneration
        withFindCategory { [weak self] in
            guard let self, self.findGeneration == generation else { return }
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    func cancelFind() {
        findGeneration += 1
        remove(GroupAlerts.findId)
    }

    /// Adds the notice's Stop action to the categories the other features registered (setNotificationCategories
    /// replaces them all), when the first notice goes up rather than at launch, where it could race their registration.
    private func withFindCategory(_ then: @escaping () -> Void) {
        if findCategoryReady { return then() }
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            if !existing.contains(where: { $0.identifier == GroupAlerts.findCategory }) {
                let stop = UNNotificationAction(identifier: GroupAlerts.stopFindAction, title: "Stop", options: [])
                let category = UNNotificationCategory(identifier: GroupAlerts.findCategory, actions: [stop], intentIdentifiers: [],
                                                      options: [])
                center.setNotificationCategories(existing.union([category]))
            }
            DispatchQueue.main.async {
                self.findCategoryReady = true
                then()
            }
        }
    }

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
            let memberId = GroupAlerts.memberId(notification)
            let action = response.actionIdentifier
            // Stop may come with TrailMind in the background: iOS keeps it running until the completion handler.
            DispatchQueue.main.async {
                if action == GroupAlerts.stopFindAction {
                    self.onStopFind?()
                } else if action == UNNotificationDefaultActionIdentifier, let memberId {
                    if help { self.onOpenMember?(memberId) } else { self.onOpenFind?(memberId) }
                }
                completionHandler()
            }
        default:
            if previous?.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler) == nil {
                completionHandler()
            }
        }
    }
}
