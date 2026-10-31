import Combine
import ContactsUI
import CoreLocation
import CoreMotion
import MessageUI
import SwiftUI
import UIKit

/// Times and battery as the Safety feature writes them (Android's `clockTime` and `DateFormat` in the phone's locale).
enum SafetyFormat {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    /// "17:30" or "5:30 PM", as the phone shows times.
    static func clock(_ ms: Int64) -> String { clockFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

    /// The clock time for a text message: the narrow spaces iOS puts before AM/PM become plain ones, so the text stays a
    /// plain SMS.
    static func clockForText(_ ms: Int64) -> String {
        clock(ms).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func dateTime(_ ms: Int64) -> String { dateTimeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

    /// Battery charge in percent, or -1 when iOS doesn't say.
    static func batteryPercent() -> Int {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? -1 : Int((Double(level) * 100).rounded())
    }
}

/// Safety settings Android keeps that the shared Prefs doesn't have yet (same keys as Android).
final class SafetyPrefs: ObservableObject {
    static let shared = SafetyPrefs()
    private let d = UserDefaults.standard

    /// The user says this phone is registered for UK emergencySMS, so texting 999 works.
    @Published var emergencySmsRegistered: Bool { didSet { d.set(emergencySmsRegistered, forKey: "emergency_sms_registered") } }

    init() {
        emergencySmsRegistered = d.bool(forKey: "emergency_sms_registered")
    }
}

/// The phone's single motion manager for the Safety feature (Apple asks apps to share one).
enum SafetyMotion {
    static let manager = CMMotionManager()
}

/// Where you are for an SOS or a check-in text: the latest fix if under 15 minutes old, else the phone's last known
/// position if that fresh (FallAlert.where, CheckIn.smsText).
enum SafetyLocation {
    static let freshFixMs: Int64 = 15 * 60_000

    static func whereNow(_ now: Int64 = nowMs()) -> (latLon: LatLon, altitudeM: Int?)? {
        let hub = LocationHub.shared
        if let fix = hub.latest, (0...freshFixMs).contains(now - fix.timeMs) {
            return (fix.latLon, fix.altitudeM.map { kRound($0) })
        }
        guard hub.hasPermission, let loc = CLLocationManager().location else { return nil }
        let t = Int64((loc.timestamp.timeIntervalSince1970 * 1000).rounded())
        guard (0...freshFixMs).contains(now - t) else { return nil }
        return (LatLon(loc.coordinate.latitude, loc.coordinate.longitude), loc.verticalAccuracy >= 0 ? kRound(loc.altitude) : nil)
    }

    /// The location text the Safety page copies, shares and texts, or nil without a fix.
    static func shareText(_ fix: Fix?) -> String? {
        guard let fix else { return nil }
        let words = What3wordsLookup.shared.current(fix)?.words
        return SafetyText.location(lat: fix.lat, lon: fix.lon, accuracyM: Double(fix.accuracyM), altitudeM: fix.altitudeM,
                                   imperial: Prefs.shared.imperial, fixTime: SafetyFormat.dateTime(fix.timeMs), words: words)
    }

    static func copy() {
        guard let text = shareText(LocationHub.shared.latest) else { AppModel.shared.toast("No GPS fix yet"); return }
        AppModel.shared.copy("My location", text)
    }

    /// The share sheet with your location (FeatureHooks.shareLocation and the Safety page's Share).
    static func share() {
        guard let text = shareText(LocationHub.shared.latest) else { AppModel.shared.toast("No GPS fix yet"); return }
        AppModel.shared.share([text], subject: "My location")
    }

    /// Messages with your location for the emergency contact (or anyone, without one), ready to send.
    static func text() {
        let text = shareText(LocationHub.shared.latest) ?? SafetyText.noFixHelp
        SafetyMessages.shared.compose(Prefs.shared.emergencyContact, text)
    }
}

/// The latest fix and location permission, without the compass headings that LocationHub also publishes many times a
/// second, so pages that show only positions don't redraw for every degree the phone turns.
final class SafetyFixWatcher: ObservableObject {
    @Published private(set) var fix: Fix?
    @Published private(set) var authorization: CLAuthorizationStatus
    private var bag = Set<AnyCancellable>()

    init() {
        let hub = LocationHub.shared
        fix = hub.latest
        authorization = hub.authorization
        hub.$latest.sink { [weak self] in self?.fix = $0 }.store(in: &bag)
        hub.$authorization.sink { [weak self] in self?.authorization = $0 }.store(in: &bag)
    }

    var hasPermission: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
}

/// Messages' composer with a text ready. iOS lets no app send a text by itself: the user checks it and taps Send.
final class SafetyMessages: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = SafetyMessages()
    private var onFinish: ((MessageComposeResult) -> Void)?

    static var canText: Bool { MFMessageComposeViewController.canSendText() }

    func compose(_ number: String, _ body: String, onFinish: ((MessageComposeResult) -> Void)? = nil) {
        DispatchQueue.main.async {
            guard MFMessageComposeViewController.canSendText() else {
                AppModel.shared.toast("This iPhone can't send texts right now")
                return
            }
            let vc = MFMessageComposeViewController()
            let to = number.trimmingCharacters(in: .whitespacesAndNewlines)
            if !to.isEmpty { vc.recipients = [to] }
            vc.body = body
            vc.messageComposeDelegate = self
            self.onFinish = onFinish
            AppModel.shared.present(vc)
        }
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
        let done = onFinish
        onFinish = nil
        done?(result)
    }
}

/// Picks the emergency contact's number from Contacts. The picker runs outside the app, so it needs no permission.
final class SafetyContactPicker: NSObject, CNContactPickerDelegate {
    static let shared = SafetyContactPicker()
    private var onPick: ((_ name: String, _ number: String) -> Void)?

    func pick(_ onPick: @escaping (_ name: String, _ number: String) -> Void) {
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        self.onPick = onPick
        AppModel.shared.present(picker)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        guard let number = contact.phoneNumbers.first?.value.stringValue else { return }
        finish(contact, number)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        guard let number = (contactProperty.value as? CNPhoneNumber)?.stringValue else { return }
        finish(contactProperty.contact, number)
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onPick = nil }

    private func finish(_ contact: CNContact, _ number: String) {
        let fullName = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        var name = ""
        if contact.areKeysAvailable([fullName]) {
            name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        } else if contact.isKeyAvailable(CNContactGivenNameKey) && contact.isKeyAvailable(CNContactFamilyNameKey) {
            name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if name.isEmpty, contact.isKeyAvailable(CNContactOrganizationNameKey) { name = contact.organizationName }
        let done = onPick
        onPick = nil
        DispatchQueue.main.async { done?(name, number) }
    }
}

/// Small presentation helpers for the Safety feature's flows, which start from dialogs, notifications and other pages.
enum SafetyUI {
    /// Runs `work` once a dialog that is closing has gone, so what it presents next is not refused by UIKit.
    static func afterDialog(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Runs `work` when the app is in front with a window to present on (after a notification action opened it).
    static func whenReady(_ tries: Int = 24, _ work: @escaping () -> Void) {
        let ready = UIApplication.shared.applicationState == .active && UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).contains { $0.isKeyWindow && $0.rootViewController != nil }
        if ready || tries <= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenReady(tries - 1, work) }
        }
    }

    /// A SwiftUI sheet over whatever is on screen, in the TrailMind palette. `content` gets a closure that closes it.
    static func sheet<V: View>(large: Bool = false, @ViewBuilder _ content: @escaping (_ close: @escaping () -> Void) -> V) {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let close: () -> Void = { [weak host] in host?.dismiss(animated: true) }
        host.rootView = AnyView(PaletteProvider { SafetySheetBackground { content(close) } }.tint(Color(argb: 0xFF1F5B45)))
        if let sheet = host.sheetPresentationController {
            sheet.detents = large ? [.large()] : [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        AppModel.shared.present(host)
    }

    static func call(_ number: String) {
        if let url = URL(string: "tel:" + number) { UIApplication.shared.open(url) }
    }

    /// Asks for location the first time; once the user has answered, only Settings can change it.
    static func allowLocation(_ status: CLAuthorizationStatus) {
        if status == .notDetermined { LocationHub.shared.requestPermission() } else { AppModel.shared.openSettings() }
    }
}

private struct SafetySheetBackground<Content: View>: View {
    @Environment(\.palette) private var p
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(p.bg.ignoresSafeArea())
    }
}
