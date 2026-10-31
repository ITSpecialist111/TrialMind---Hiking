import Foundation
import UIKit
import UserNotifications

/// Offline maps' notifications (the Offline maps and Downloads channels on Android): the question before 24-hour
/// Premium detail expires, with Renew and Let it expire (only the user's tap renews it; TrailMind never does on its
/// own), a finished download's summary, and a download iOS paused in the background. iOS has one notification delegate
/// per app: this handles only offline maps' notifications and passes everything else to the delegate set before it.
final class OfflineNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OfflineNotifications()

    private static let prefix = "trailmind.offline."
    private static let renewCategory = "trailmind.offline.renew"
    private static let retryCategory = "trailmind.offline.retry"
    private static let renewAction = "trailmind.offline.renew-now"
    private static let expireAction = "trailmind.offline.let-expire"
    private static let retryAction = "trailmind.offline.try-again"
    private static let doneId = "trailmind.offline.done"

    private let center = UNUserNotificationCenter.current()
    private weak var previous: UNUserNotificationCenterDelegate?
    private var installed = false
    private let renewals = DispatchQueue(label: "trailmind.offline.renewals", qos: .utility)
    private let lock = NSLock()
    private var reschedulePending = false

    /// Becomes the notification delegate (keeping the one before it) and adds offline maps' actions to the categories
    /// other features have registered.
    func install() {
        guard !installed else { return }
        installed = true
        if let current = center.delegate, current !== self { previous = current }
        center.delegate = self
        // Renewing starts a download, which iOS lets an app begin only from the foreground.
        let renew = UNNotificationAction(identifier: Self.renewAction, title: "Renew", options: [.foreground])
        let expire = UNNotificationAction(identifier: Self.expireAction, title: "Let it expire", options: [])
        let retry = UNNotificationAction(identifier: Self.retryAction, title: "Try again", options: [.foreground])
        let mine: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: Self.renewCategory, actions: [renew, expire], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.retryCategory, actions: [retry], intentIdentifiers: [], options: []),
        ]
        let ids = Set(mine.map(\.identifier))
        center.getNotificationCategories { existing in
            self.center.setNotificationCategories(existing.filter { !ids.contains($0.identifier) }.union(mine))
        }
    }

    /// Asks once for permission to notify (Android's requestNotificationPermissionIfNeeded before a download).
    func requestAuthorization() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    private func renewId(_ packId: Int64) -> String { "\(Self.prefix)renew.\(packId)" }
    private func pausedId(_ packId: Int64) -> String { "\(Self.prefix)paused.\(packId)" }

    private func remove(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func dismissRenewal(_ packId: Int64) { remove(renewId(packId)) }

    func cancelPaused(_ packId: Int64) { remove(pausedId(packId)) }

    private func post(_ id: String, title: String, body: String, packId: Int64, category: String? = nil, at: Date? = nil,
                      sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.threadIdentifier = "trailmind.offline"
        content.userInfo = ["pack": NSNumber(value: packId)]
        if let category { content.categoryIdentifier = category }
        let trigger = at.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false) }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// A download finished, paused on a problem or failed (DownloadService's summary), with Try again when it paused.
    func postFinished(_ packId: Int64, name: String, summary: String, retry: Bool) {
        post(Self.doneId, title: "Offline map: \(name)", body: summary, packId: packId, category: retry ? Self.retryCategory : nil,
             sound: false)
    }

    /// iOS is stopping TrailMind in the background with a download unfinished.
    func postPaused(_ packId: Int64, name: String) {
        post(pausedId(packId), title: "Offline map: \(name)",
             body: "Paused because iPhone stops TrailMind soon after you leave it. Open TrailMind to carry on downloading.",
             packId: packId, category: Self.retryCategory, sound: false)
    }

    // MARK: Renewal questions (PremiumRenewal)

    /// Asks the questions that are due and schedules the rest for their time: two hours before the detail expires, or
    /// 20:00 the evening before rather than overnight (RenewalPrompt). iOS can't wake TrailMind at a set time, so each
    /// question is handed to iOS to deliver then. Reads tile files on its own queue.
    func reschedule() {
        let first: Bool = lock.withLock {
            if reschedulePending { return false }
            reschedulePending = true
            return true
        }
        guard first else { return }
        renewals.async {
            self.lock.withLock { self.reschedulePending = false }
            self.rescheduleNow()
        }
    }

    private func notificationsAllowed() -> Bool {
        let done = DispatchSemaphore(value: 0)
        var allowed = false
        center.getNotificationSettings { settings in
            allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            done.signal()
        }
        done.wait()
        return allowed
    }

    private func rescheduleNow() {
        let packs = Store.shared.packs()
        let now = nowMs()
        let (custom, askedBefore) = DispatchQueue.main.sync { (OfflineSources.custom(Prefs.shared), Prefs.shared.renewAsked) }
        var asked = askedBefore
        let allowed = notificationsAllowed()
        let downloading = PackDownloader.shared.activePackId
        for pack in packs {
            guard let detail = OfflinePacks.shared.premiumDetail(pack, custom: custom, packs: packs, now: now), detail.expiresAtMs > now else {
                dismissRenewal(pack.id)
                continue
            }
            // Tiles from one download expire within a few hours of each other, so one question covers them all.
            if PackPlan.alreadyAsked(expiresAtMs: detail.expiresAtMs, askedFor: asked[pack.id]) { continue }
            if downloading == pack.id || !allowed { continue }
            let at = RenewalPrompt.at(detail.expiresAtMs, TimeZone.current)
            let label = PackPlan.premiumLabel(sourceId: pack.sourceId, premiumMaxZoom: pack.premiumMaxZoom)
            let when = max(at, now)
            // How many tiles a renewal would fetch at the time the question is asked.
            let toFetch = at > now ? (OfflinePacks.shared.premiumDetail(pack, custom: custom, packs: packs, now: at)?.toFetch ?? detail.toFetch)
                : detail.toFetch
            post(renewId(pack.id), title: "\(label) expires \(OfflineText.atTime(detail.expiresAtMs, from: when))",
                 body: PackPlan.renewalBody(packName: pack.name, toFetch: toFetch), packId: pack.id, category: Self.renewCategory,
                 at: at > now ? Date(timeIntervalSince1970: Double(at) / 1000) : nil)
            asked[pack.id] = detail.expiresAtMs
        }
        let ids = Set(packs.map(\.id))
        asked = asked.filter { ids.contains($0.key) }
        let result = asked
        DispatchQueue.main.async { if Prefs.shared.renewAsked != result { Prefs.shared.renewAsked = result } }
    }

    // MARK: UNUserNotificationCenterDelegate

    private func isOurs(_ n: UNNotification) -> Bool { n.request.identifier.hasPrefix(Self.prefix) }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if !isOurs(notification), let previous,
           previous.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) != nil {
            return
        }
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
        let packId = (response.notification.request.content.userInfo["pack"] as? NSNumber)?.int64Value
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case Self.renewAction, Self.retryAction:
                if let packId { PackDownloader.shared.download(packId) }
                Navigator.shared.open(.offline)
            case Self.expireAction:
                break
            case UNNotificationDefaultActionIdentifier:
                Navigator.shared.open(.offline)
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
