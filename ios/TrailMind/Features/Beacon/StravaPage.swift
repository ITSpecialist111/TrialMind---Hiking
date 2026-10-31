import SwiftUI

/// Links TrailMind to the user's Strava account, and sets whether finished hikes are posted by themselves
/// (ui/StravaPage.kt). Strava's sign-in needs a client secret that mustn't ship inside an app, so each user brings their
/// own Strava application (free, two minutes), the same way they bring their own OS Data Hub and MapTiler keys.
struct StravaPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var strava = StravaService.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var store = Store.shared
    @State private var note: String?
    @State private var clientId = Prefs.shared.stravaClientId
    @State private var secret = ""

    static let routeId = "strava"
    private static let waiting = "Sign in on Strava"

    static func open() {
        Navigator.shared.push(PageRoute(routeId) { StravaPage() })
    }

    var body: some View {
        PageScaffold("Strava") {
            if strava.linked {
                linkedCards
            } else if strava.needsReconnect {
                TMBanner(message: "Strava stopped accepting TrailMind, so hikes can't be posted. Connect again to carry on. " +
                         "Hikes already on Strava aren't affected.", danger: true)
                setupCard(reconnect: true)
            } else {
                setupCard(reconnect: false)
            }
        }
        .onChange(of: strava.linked) { _, linked in
            if linked && note?.hasPrefix(Self.waiting) == true { note = nil }
        }
    }

    // MARK: Linked

    @ViewBuilder private var linkedCards: some View {
        let who = strava.athlete()
        TMCard(spacing: 8) {
            Text("Linked to Strava").tm(.label, p)
            TMText(who?.display ?? "Your Strava account", .headline)
            TMText("TrailMind posts your hikes to this account. Hikes you've already uploaded stay as they are.", .caption)
            if let note, !note.hasPrefix(Self.waiting) { TMText(note, .caption, color: p.primary) }
        }
        let waitingCount = waitingPosts
        if waitingCount > 0 { TMBanner(message: StravaText.waiting(waitingCount), icon: .upload) }
        TMCard(spacing: 6) {
            TMText("Posting", .title)
            TMToggle(label: "Post each hike to Strava automatically", isOn: $prefs.stravaAuto)
            Text("Post hikes as").tm(.label, p)
            FlowLayout(spacing: 8) {
                ForEach(StravaActivityKind.allCases, id: \.code) { kind in
                    TMChip(kind.label, selected: prefs.stravaKind == kind.code) { prefs.stravaKind = kind.code }
                }
            }
            TMText(StravaText.postingHelp, .caption)
        }
        TMCard(spacing: 8) {
            if let who {
                TMButton("View my Strava profile", style: .tonal) {
                    if let url = URL(string: "https://www.strava.com/athletes/\(who.id)") { AppModel.shared.open(url) }
                }
            }
            TMButton("Disconnect from Strava", icon: .close, style: .outlined) {
                AppModel.shared.confirm("Disconnect from Strava?",
                                        "TrailMind stops posting your hikes and tells Strava to forget it. Hikes already on Strava stay there. " +
                                            "Your application's Client ID and secret stay saved so you can connect again.",
                                        ok: "Disconnect", danger: true) {
                    strava.disconnect()
                    note = nil
                    AppModel.shared.toast("Disconnected from Strava")
                }
            }
            TMButton("Forget my Strava application", style: .text) {
                AppModel.shared.confirm("Forget the application?", "Disconnects, and deletes the Client ID and secret from this phone.",
                                        ok: "Forget", danger: true) {
                    strava.disconnect(forget: true)
                    note = nil
                    clientId = ""
                    secret = ""
                }
            }
        }
    }

    /// Hikes queued or being processed; read again whenever the store or a post changes.
    private var waitingPosts: Int {
        _ = store.revision
        _ = strava.revision
        return store.stravaWaitingCount()
    }

    // MARK: Setting up

    private func setupCard(reconnect: Bool) -> some View {
        TMCard(spacing: 8) {
            TMText(reconnect ? "Connect to Strava again" : "Post your hikes to Strava", .title)
            TMBanner(message: "Automatic posting needs a Strava subscription: since June 2026 Strava only lets subscribers create the application it relies on. " +
                     "Without one, use Upload to Strava on any hike's page: one tap saves the GPX to Files and opens Strava's upload page.",
                     icon: .upload)
            TMText("Link TrailMind to your Strava account once, and every hike you finish is posted by itself, with no files to save or upload. " +
                   "Strava only lets an app post for you if the app is registered with it, and the secret that proves it must stay private, " +
                   "so TrailMind uses your own free Strava application. It takes about two minutes:", .caption)
            TMText("1. Open strava.com/settings/api and sign in (Google sign-in works there). It asks for a subscription before you can create an application.\n" +
                   "2. Create an application: any name (TrailMind will do), any category, any website (https://localhost is fine), " +
                   "and set Authorization Callback Domain to  \(StravaOAuth.callbackDomain)\n" +
                   "3. Copy its Client ID and Client Secret into the boxes below.\n" +
                   "4. Tap Connect with Strava, sign in and approve, leaving \"Upload your activities\" ticked.", .body)
            TMButton("Open Strava API settings", style: .tonal) { StravaWeb.openInBrowser("https://www.strava.com/settings/api") }
            Text("Client ID").tm(.label, p)
            TMField(hint: "Client ID (a number)", text: $clientId, keyboard: .numberPad)
            Text("Client Secret").tm(.label, p)
            // The saved secret isn't shown; leaving the box blank keeps it.
            TMField(hint: prefs.hasStravaSecret ? "Client Secret (saved: leave blank to keep it)" : "Paste your Client Secret",
                    text: $secret, keyboard: .asciiCapable)
            TMButton("Connect with Strava", icon: .upload) { connect() }
            if let shown = strava.linkNote ?? note {
                TMText(shown, .caption, color: shown.hasPrefix(Self.waiting) ? p.primary : p.danger)
            }
            TMText("The secret is kept encrypted on this phone and is only ever sent to Strava. Strava's rules let an application you create " +
                   "serve your own account, which is exactly this. Nothing about your hikes goes anywhere but your Strava.", .caption)
        }
    }

    private func connect() {
        guard let url = strava.beginConnect(clientId, secret, error: { note = $0 }) else { return }
        note = "\(Self.waiting) and approve. You'll come straight back here."
        StravaSignIn.shared.start(url) { outcome in
            switch outcome {
            case .redirect(let link):
                strava.handleRedirect(link.absoluteString) { AppModel.shared.toast($0) }
            case .cancelled:
                if note?.hasPrefix(Self.waiting) == true { note = nil }
            case .failed(let message):
                note = "Couldn't open Strava's sign-in: \(message)"
            }
        }
    }
}
