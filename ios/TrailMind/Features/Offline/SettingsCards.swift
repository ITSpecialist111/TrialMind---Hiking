import SwiftUI

/// Testing a saved key with one tile, worded as Android's SettingsPage.testKey and testMapTilerKey.
enum SettingsKeyTest {
    /// One overview tile over Great Britain (zoom 7, OpenData), then one Premium tile to learn the plan.
    @MainActor static func os() async -> String {
        guard let source = TileSources.builtIns().first(where: { $0.id == TileSources.osOutdoor }) else { return "" }
        let open = await OfflineNet.shared.fetchTile(source, TileKey(7, 63, 41))
        var premium: OfflineNet.Fetch? = nil
        if case .ok = open { premium = await OfflineNet.shared.fetchTile(source, TileKey(17, 64462, 41754)) }
        var premiumOk = false
        var premiumRefused = false
        if case .ok? = premium { premiumOk = true }
        if case .http(403)? = premium { premiumRefused = true }
        if premiumOk { Prefs.shared.osPremium = true } else if premiumRefused { Prefs.shared.osPremium = false }
        switch open {
        case .ok:
            if premiumOk { return "✓ Key works, with OS Premium: every zoom. Choose an OS map from the layers button." }
            if premiumRefused {
                return "✓ Key works for overview maps: zooms 7–16. Closer zooms show zoom 16 enlarged. Choose an OS map from the layers button."
            }
            return "✓ Key works. Choose an OS map from the layers button."
        case .http(let code):
            switch code {
            case 401, 403: return "✗ Key rejected (HTTP \(code)). Check the OS Maps API is added to your Data Hub project."
            case 429: return "✗ Rate limited (HTTP 429). Try again later."
            default: return "✗ OS server returned HTTP \(code)."
            }
        case .noKey: return "No key entered."
        case .noNetwork: return "No internet connection (or offline-only mode is on)."
        case .error(let message): return "✗ \(message)"
        }
    }

    @MainActor static func mapTiler() async -> String {
        guard let source = TileSources.historic().first(where: { $0.id == TileSources.nls1900s }) else { return "" }
        switch await OfflineNet.shared.fetchTile(source, TileKey(6, 31, 20)) {
        case .ok: return "✓ Key works. Choose an old map under Map layers → Old maps."
        case .http(let code):
            switch code {
            case 401, 403: return "✗ Key rejected (HTTP \(code)). Check you copied the whole key from MapTiler Cloud."
            case 429: return "✗ Over MapTiler's free allowance (HTTP 429). Try again later."
            default: return "✗ MapTiler returned HTTP \(code)."
            }
        case .noKey: return "No key entered."
        case .noNetwork: return "No internet connection (or offline-only mode is on)."
        case .error(let message): return "✗ \(message)"
        }
    }
}

struct OsKeyCard: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var key = ""
    @State private var status = ""

    var body: some View {
        TMCard(spacing: 10) {
            TMText("Ordnance Survey maps", .title)
            HelpRow(summary: "Use your own OS maps key.",
                    detail: "Create a free account and API project on the OS Data Hub, add the OS Maps API, and paste the project API key here. The key is stored only on this phone. " +
                        "Overview maps (zooms 7–16) stay saved; closer detail uses your plan's allowance and is kept for 24 hours.")
            TMField(hint: "OS Data Hub API key", text: $key, keyboard: .asciiCapable)
            ActionRow {
                TMButton("Save & test", fill: true) { save() }
                TMButton("Get a key", style: .tonal, fill: true) { SettingsText.open(SettingsText.osDataHubURL) }
            }
            if !status.isEmpty { TMText(status, .caption) }
        }
        .onAppear { key = prefs.osApiKey }
    }

    private func save() {
        prefs.osApiKey = KotlinText.trim(key)
        TileLoader.shared.clearErrors()
        status = "Testing…"
        Task { @MainActor in
            status = await SettingsKeyTest.os()
            // The map asks for its tiles again with the new key (Android's setSource).
            OfflinePacks.refreshMap()
        }
    }
}

struct MapTilerKeyCard: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var key = ""
    @State private var status = ""

    var body: some View {
        TMCard(spacing: 10) {
            TMText("Old maps (MapTiler key)", .title)
            HelpRow(summary: "Historic maps with your MapTiler key.",
                    detail: "Scanned Ordnance Survey maps of Great Britain from 1885–1961, including every sheet of the Forest of Dean and the lower Wye, " +
                        "are served free by MapTiler Cloud with your own key. Create a free MapTiler account, copy a key from your account page and paste it here: " +
                        "the free plan is for personal, non-commercial use. The key is stored only on this phone. " +
                        "Then open Map layers → Old maps.")
            TMField(hint: "MapTiler key", text: $key, keyboard: .asciiCapable)
            ActionRow {
                TMButton("Save & test", fill: true) { save() }
                TMButton("Get a key", style: .tonal, fill: true) { SettingsText.open(TileSources.mapTilerCloudURL) }
            }
            if !status.isEmpty { TMText(status, .caption) }
        }
        .onAppear { key = prefs.mapTilerKey }
    }

    private func save() {
        prefs.mapTilerKey = KotlinText.trim(key)
        TileLoader.shared.clearErrors()
        status = "Testing…"
        Task { @MainActor in
            status = await SettingsKeyTest.mapTiler()
            OfflinePacks.refreshMap()
        }
    }
}

/// The fall alarm and SOS text options (Android has them on the Safety page's Frontier and SOS cards). iPhone can't
/// send a text by itself, so "without asking" opens the text ready to send.
struct FallAndSosCard: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let contact = KotlinText.trim(prefs.emergencyContact)
        TMCard(spacing: 6) {
            TMText("Fall alarm and SOS", .title)
            TMToggle(label: "Detect falls while recording", isOn: $prefs.frontierFallDetectionEnabled)
                .disabled(!prefs.frontierEnabled)
            if !prefs.frontierEnabled {
                TMText("Frontier safety features are off on the Safety page, so falls aren't watched for.", .caption)
            }
            TMToggle(label: "Sound the fall alarm", isOn: $prefs.fallAlarmSound)
            TMToggle(label: "Get the SOS text ready without asking me", isOn: $prefs.sosAutoSend)
                .disabled(contact.isEmpty)
            TMText(sosCaption(contact), .caption)
            HelpRow(summary: "What happens after a possible fall.",
                    detail: "While a hike records, TrailMind watches for a fall. After a possible fall it sounds an alarm and asks if you're OK. " +
                        "If you don't answer, it prepares a text to your emergency contact with your grid reference, a map link and your battery. " +
                        "iPhone can't send a text by itself, so you tap Send.")
            TMButton("Safety page", icon: .sos, style: .tonal) { Navigator.shared.open(.safety) }
        }
    }

    private func sosCaption(_ contact: String) -> String {
        if contact.isEmpty { return "Set an emergency contact to use this." }
        if SosText.isEmergencyNumber(contact) {
            return "Your emergency contact is an emergency number. TrailMind never texts it by itself: call 999 or 112 instead."
        }
        return prefs.sosAutoSend
            ? "On: if you don't answer the fall alarm, TrailMind opens the text to \(prefs.emergencyContactName.isEmpty ? "your contact" : prefs.emergencyContactName) ready to send. Tap Send."
            : "Off: TrailMind asks first, then gets the text ready and you tap Send in Messages."
    }
}

struct CustomSourceCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var prefs = Prefs.shared
    @State private var name = ""
    @State private var template = ""
    @State private var attribution = ""
    @State private var maxZoom = ""
    @State private var allow = false
    @State private var problem = ""

    var body: some View {
        TMCard(spacing: 8) {
            TMText("Custom tile source (advanced)", .title)
            TMText("An XYZ raster template such as https://example.com/{z}/{x}/{y}.png ({s}, {-y} and {key} are supported). You must follow the provider's terms. " +
                   "Hosts whose policies forbid bulk downloads (e.g. openstreetmap.org, OpenTopoMap) can be browsed but never downloaded.", .caption)
            TMText("Name", .label)
            TMField(hint: "e.g. My local map", text: $name)
            TMText("URL template", .label)
            TMField(hint: "https://…/{z}/{x}/{y}.png", text: $template, keyboard: .URL)
            TMText("Attribution (required by most licences)", .label)
            TMField(hint: "e.g. © Provider name", text: $attribution)
            TMText("Max zoom", .label)
            TMField(hint: "18", text: $maxZoom, keyboard: .numberPad)
            TMToggle(label: "Its licence allows me to store tiles offline", isOn: $allow)
            if !problem.isEmpty { TMText(problem, .caption, color: p.danger) }
            TMButton("Save source", style: .tonal, fill: true) { save() }
            if OfflineSources.custom(prefs) != nil {
                TMToggle(label: "Show it over the map", isOn: Binding(get: { prefs.offlineMapSourceId == TileSources.custom },
                                                                       set: { prefs.offlineMapSourceId = $0 ? TileSources.custom : "" }))
                TMText("iPhone's map layers hold the built-in maps, so your source lies over the base map, which shows wherever your source has no tiles.", .caption)
            }
        }
        .onAppear {
            name = prefs.customName
            template = prefs.customTemplate
            attribution = prefs.customAttribution
            maxZoom = String(prefs.customMaxZoom)
            allow = prefs.customOfflineAllowed
        }
    }

    private func save() {
        let t = KotlinText.trim(template)
        if !KotlinText.isBlank(t), let error = TilePolicy.validateTemplate(t) {
            problem = error
            return
        }
        prefs.customName = KotlinText.trim(name)
        prefs.customTemplate = t
        prefs.customAttribution = KotlinText.trim(attribution)
        prefs.customMaxZoom = Int(maxZoom).map { $0.clamped(1, TilePolicy.maxZoom) } ?? 18
        prefs.customOfflineAllowed = allow
        problem = !KotlinText.isBlank(t) && TilePolicy.isBulkDownloadForbidden(t) ? "Saved. This host forbids bulk downloads, so it's browse-only." : ""
        if KotlinText.isBlank(t) && prefs.offlineMapSourceId == TileSources.custom { prefs.offlineMapSourceId = "" }
        AppModel.shared.toast(KotlinText.isBlank(t) ? "Custom source removed" : "Saved – switch on Show it over the map to see it")
    }
}

struct AboutCard: View {
    var body: some View {
        TMCard(spacing: 6) {
            TMText("About", .title)
            TMText("TrailMind \(SettingsText.version) · personal offline-first hiking app.\n" + SettingsText.credits, .caption)
            ActionRow {
                TMButton("OS terms", style: .text) { SettingsText.open(TileSources.osTermsURL) }
                TMButton("Report an OS map error", style: .text) { SettingsText.open(TileSources.osErrorsURL) }
            }
            ActionRow {
                TMButton("OpenStreetMap copyright", style: .text) { SettingsText.open(TileSources.osmCopyrightURL) }
                TMButton("Report an OpenStreetMap issue", style: .text) { SettingsText.open(TileSources.osmFixTheMapURL) }
            }
            TMButton("Weather data licence (CC BY 4.0)", style: .text) { SettingsText.open(SettingsText.openMeteoLicenceURL) }
            TMButton("Old maps: National Library of Scotland", style: .text) { SettingsText.open(TileSources.nlsMapsURL) }
            TMButton("LiDAR licence (Open Government Licence)", style: .text) { SettingsText.open(SettingsText.lidarLicenceURL) }
            TMBanner(message: SettingsText.safety, danger: true)
            TMButton("Show safety introduction", style: .text) {
                Navigator.shared.push(PageRoute("onboarding") { OnboardingPage() })
            }
        }
    }
}
