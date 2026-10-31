import SwiftUI

/// Settings (Pages3.kt SettingsPage): your own map and lookup keys, appearance, Strava, recording, units and pace,
/// navigation alerts, emergency contact, fall alarm and SOS, a custom tile source, credits and privacy.
struct SettingsPage: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        PageScaffold("Settings") {
            ThreeWordsKeyCard()
            AppearanceCard()
            OsKeyCard()
            MapTilerKeyCard()
            if let openStrava = FeatureHooks.openStrava { StravaCard(open: openStrava) }
            if let openGroup = FeatureHooks.openGroup { GroupCard(open: openGroup) }
            TMCard(spacing: 6) {
                TMText("Recording", .title)
                TMToggle(label: "Pause the hike when I get in a vehicle", isOn: $prefs.autoPauseInVehicle)
                HelpRow(summary: "Leave vehicle journeys out of hikes.",
                        detail: "If the phone keeps moving faster than about 22 km/h (14 mph) for half a minute, TrailMind pauses the hike, " +
                            "leaves the drive out of your track and time, switches the GPS off and tells you. Tap Resume when you are back on foot. " +
                            "Turn it off if you cycle or ski.")
            }
            UnitsCard()
            NavigationCard()
            EmergencyContactCard()
            FallAndSosCard()
            CustomSourceCard()
            AboutCard()
            TMCard(spacing: 6) {
                TMText("Privacy", .title)
                TMText(SettingsText.privacy, .caption)
            }
        }
    }
}

/// Settings' longer texts.
enum SettingsText {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    static let privacy = "No accounts, ads or analytics: your routes, hikes, emergency contact and keys stay on this phone. Routes, hikes and " +
        "offline maps are left out of iCloud backups, and your keys never leave this iPhone's Keychain. " +
        "To show maps, terrain, place names, forecasts, routes and facilities, TrailMind sends the map area or points involved to that service: " +
        "Ordnance Survey, OpenStreetMap, Apple Maps (the Apple map and place search without an OS key), MapTiler (old maps, with your own key), " +
        "what3words (only on explicit lookup with your own key), Mapzen terrain tiles on Amazon Web Services, the Environment Agency (LiDAR), " +
        "Open-Meteo, BRouter, Waymarked Trails, Overpass, Strava (only if you set it up) or your custom map source. " +
        "Your location is texted only to the contact you choose, and only when you tap Send in Messages. " +
        "In a trip group it also goes, encrypted with the group's code, straight to the group's phones nearby, never to a server."

    static let credits = "Map data: © OpenStreetMap contributors (ODbL); Contains OS data © Crown copyright and database rights (OS OpenData under the Open Government Licence; OS Premium under your OS Data Hub plan). " +
        "Apple Maps and place search without an OS key: © Apple.\n" +
        "Old maps: Ordnance Survey, scanned by the National Library of Scotland (maps.nls.uk), CC BY 3.0, hosted by MapTiler.\n" +
        "Routes found with Waymarked Trails; their heights: ASTER GDEM is a product of METI and NASA.\n" +
        "Weather data by Open-Meteo.com (CC BY 4.0).\n" +
        "1 m LiDAR terrain for England, under the Open Government Licence: © Environment Agency copyright and/or database right 2022. All rights reserved.\n" +
        "Icons: Material Symbols (Apache 2.0).\n" +
        "Estimates use Naismith's rule with Langmuir corrections and Tobler's hiking function; they exclude breaks."

    static let safety = "Safety: TrailMind is an aid, not a replacement for a paper map, compass and the skills to use them. GPS, batteries and phone signal fail. " +
        "Check the weather, tell someone your plans, and in the UK call 999 or 112 and ask for Police, then Mountain Rescue."

    static let openMeteoLicenceURL = "https://creativecommons.org/licenses/by/4.0/"
    static let lidarLicenceURL = "https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/"
    static let what3wordsURL = "https://developer.what3words.com/"
    static let osDataHubURL = "https://osdatahub.os.uk/"

    static func open(_ url: String) {
        if let u = URL(string: url) { AppModel.shared.open(u) }
    }
}

/// A row of selectable chips for a setting (SettingsPage.chips).
struct SettingChips<Value: Equatable>: View {
    let items: [(String, Value)]
    let selected: Value
    let pick: (Value) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                TMChip(items[i].0, selected: items[i].1 == selected) { pick(items[i].1) }
            }
        }
    }
}

private struct ThreeWordsKeyCard: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var key = ""

    var body: some View {
        TMCard(spacing: 6) {
            TMText("what3words API", .title)
            HelpRow(summary: "Optional three-word location lookup.",
                    detail: "Use your own what3words API key with convert-to-coordinates and convert-to-3wa access. Pricing and allowances depend on your plan. " +
                        "Requests are made only when you search three words or tap Look up three words in Safety. Keys stay in this iPhone's Keychain and are not included in backups.")
            TMField(hint: "what3words API key", text: $key, secure: true)
            TMButton("Save what3words key", style: .tonal) {
                prefs.what3wordsKey = KotlinText.trim(key)
                AppModel.shared.toast("what3words key saved")
            }
            TMButton("Get a what3words key", style: .text) { SettingsText.open(SettingsText.what3wordsURL) }
        }
        .onAppear { key = prefs.what3wordsKey }
    }
}

private struct AppearanceCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        TMCard(spacing: 6) {
            TMText("Appearance", .title)
            HelpRow(summary: "Menu transparency",
                    detail: "On unfolded phones and wide windows, the rounded menu floats over the map. Text and controls stay opaque. Choose 100% opacity for maximum contrast.")
            TMText("Menu opacity: \(prefs.menuOpacityPercent)%", .label)
            Slider(value: Binding(get: { Double(prefs.menuOpacityPercent) }, set: { prefs.menuOpacityPercent = Int($0.rounded()) }),
                   in: 70...100, step: 1)
                .tint(p.primary)
                .frame(minHeight: 48)
                .accessibilityLabel("Menu opacity, 70 to 100 percent")
        }
    }
}

private struct StravaCard: View {
    @ObservedObject private var prefs = Prefs.shared
    let open: () -> Void

    var body: some View {
        let linked = prefs.hasStravaRefreshToken && !prefs.stravaNeedsReconnect
        let who = [prefs.stravaAthleteFirstName, prefs.stravaAthleteLastName].filter { !$0.isEmpty }.joined(separator: " ")
        let name = who.isEmpty ? (prefs.stravaAthleteUsername.isEmpty ? "your account" : prefs.stravaAthleteUsername) : who
        TMCard(spacing: 6) {
            TMText("Strava", .title)
            if linked {
                TMText("Linked as \(name). " + (prefs.stravaAuto ? "Finished hikes are posted automatically." : "Automatic posting is off."), .caption)
            } else if prefs.stravaNeedsReconnect {
                TMText("Strava stopped accepting TrailMind. Connect again to carry on posting.", .caption)
            } else {
                TMText("Post each finished hike to your Strava account automatically. This needs a Strava subscription; without one, every hike's page has Upload to Strava.", .caption)
            }
            TMButton(linked ? "Manage Strava" : "Set up Strava", icon: .upload, style: .tonal, action: open)
        }
    }
}

private struct GroupCard: View {
    let open: () -> Void

    var body: some View {
        TMCard(spacing: 6) {
            TMText("Trip group", .title)
            TMText(FeatureHooks.groupSummary?() ?? "See your party on the map and in an emergency, phone to phone with no signal needed.", .caption)
            TMButton("Open trip group", style: .tonal, action: open)
        }
    }
}

private struct UnitsCard: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        TMCard(spacing: 6) {
            TMText("Units & pace", .title)
            HelpRow(summary: "Choose units and walking estimates.",
                    detail: "Flat speed is your normal walking pace. The conditions/group factor increases estimated time for rough ground, bad weather or a slower party. Estimates are not guarantees; allow extra time for stops.")
            TMToggle(label: "Miles and feet", isOn: $prefs.imperial)
            TMText("Flat walking speed", .label)
            SettingChips(items: [3.5, 4.0, 4.5, 5.0, 5.5, 6.0].map { (Units.speedKmh($0 / 3.6, imperial: prefs.imperial), $0) },
                         selected: [3.5, 4.0, 4.5, 5.0, 5.5, 6.0].first { abs($0 - prefs.flatSpeedKmh) < 1e-6 } ?? -1) { prefs.flatSpeedKmh = $0 }
            TMText("Conditions / group factor", .label)
            SettingChips(items: [("Good ×1.0", 1.0), ("Wet ×1.15", 1.15), ("Rough ×1.3", 1.3), ("Snow/slow ×1.5", 1.5)],
                         selected: [1.0, 1.15, 1.3, 1.5].first { abs($0 - prefs.conditionsFactor) < 1e-6 } ?? -1) { prefs.conditionsFactor = $0 }
        }
    }
}

private struct NavigationCard: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        TMCard(spacing: 6) {
            TMText("Navigation", .title)
            TMText("Off-route alert distance", .label)
            SettingChips(items: [30, 60, 100, 150].map { (Units.distance(Double($0), imperial: prefs.imperial), $0) },
                         selected: prefs.offRouteThresholdM) { prefs.offRouteThresholdM = $0 }
            HelpRow(summary: "Alert when you leave the route.",
                    detail: "Alerts need 3 consecutive GPS fixes beyond this distance (after allowing for GPS accuracy), then vibrate and notify.")
            TMText("Daylight margin", .label)
            HelpRow(summary: "Allow time before sunset.",
                    detail: "Adds a daylight safety margin when checking your likely finish time. This does not account for local shade or poor visibility; carry a torch.")
            SettingChips(items: [0, 30, 60].map { ("\($0) min", $0) }, selected: prefs.daylightMarginMinutes) { prefs.daylightMarginMinutes = $0 }
            TMToggle(label: "Offline only (never use mobile data for maps)", isOn: Binding(get: { prefs.offlineOnly }, set: {
                prefs.offlineOnly = $0
                TileLoader.shared.clearErrors()
            }))
        }
    }
}

private struct EmergencyContactCard: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        TMCard(spacing: 8) {
            TMText("Emergency contact", .title)
            TMField(hint: "Contact name", text: $name)
            TMField(hint: "Phone number for location SMS", text: $phone, keyboard: .phonePad)
            TMButton("Save contact", style: .tonal) {
                prefs.emergencyContactName = KotlinText.trim(name)
                prefs.emergencyContact = KotlinText.trim(phone)
                AppModel.shared.toast("Saved")
            }
        }
        .onAppear {
            name = prefs.emergencyContactName
            phone = prefs.emergencyContact
        }
    }
}
