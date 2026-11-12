import SwiftUI

/// The emergency contact (Android's Settings → Emergency contact card): picked from Contacts or typed in. Check-in
/// reminders offer to text this person and the SOS text is for them. It stays on this phone.
enum EmergencyContactUI {
    /// Picks a number from Contacts and saves it straight away.
    static func pick() {
        SafetyContactPicker.shared.pick { name, number in save(name: name, number: number) }
    }

    /// The editor, to type a name and number or pick them from Contacts first.
    static func edit() {
        SafetyUI.sheet { close in EmergencyContactSheet(close: close) }
    }

    static func save(name: String, number: String) {
        let prefs = Prefs.shared
        prefs.emergencyContactName = KotlinText.trim(name)
        prefs.emergencyContact = KotlinText.trim(number)
        AppModel.shared.toast("Saved")
        // The reminders and alarm notifications name the contact in their Text button.
        SafetyNotifications.shared.registerCategories()
        CheckInService.shared.arm()
    }
}

/// Name and number, as Android's Settings card has them, with Contacts to fill them in.
private struct EmergencyContactSheet: View {
    let close: () -> Void
    @State private var name = Prefs.shared.emergencyContactName
    @State private var number = Prefs.shared.emergencyContact

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TMText("Emergency contact", .headline)
                TMText("Check-in reminders offer to text this person, and the SOS text is for them. The number stays on this phone.", .caption)
                TMButton("Choose from Contacts", style: .tonal) {
                    SafetyContactPicker.shared.pick { pickedName, pickedNumber in
                        name = pickedName
                        number = pickedNumber
                    }
                }
                TMText("Contact name", .label)
                TMField(hint: "Contact name", text: $name)
                TMText("Phone number for location texts", .label)
                TMField(hint: "Phone number", text: $number, keyboard: .phonePad)
                if SosText.isEmergencyNumber(number) {
                    TMBanner(message: "This is an emergency number. TrailMind never opens a text to it by itself: use Text 999 on the Safety page.")
                }
                ActionRow {
                    TMButton("Save contact", style: .filled) {
                        EmergencyContactUI.save(name: name, number: number)
                        close()
                    }
                    TMButton("Cancel", style: .text) { close() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
