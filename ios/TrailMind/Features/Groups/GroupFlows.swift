import Foundation
import UIKit

/// The trip group's dialogs and map actions (ui/GroupPage.kt's create, join, invite and member details;
/// MapScreen.fitGroup, showMember and focusMember; MainActivity's invite links).
enum GroupFlows {
    private static let disclosure = "TrailMind will share your precise location, battery level and safety status with everyone who " +
        "has this group's code, directly between phones: iPhones link to each other over Wi-Fi and Bluetooth, and listen " +
        "for Android members' Bluetooth. This happens while TrailMind is open; iOS pauses it soon after you leave " +
        "TrailMind or lock the screen, even while a hike records.\n\nMembers' phones may pass your position on to others " +
        "in the group who are out of range. Nothing goes to TrailMind or any server. Group positions are deleted when " +
        "the trip ends or you leave.\n\niOS will now ask to allow Bluetooth and devices on your local network."

    /// A dialog shown straight after another is dismissed needs the first one gone (SwiftUI alerts don't chain).
    static func next(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    /// Explains what a trip group shares, then asks for location and notifications (Bluetooth and Local Network are
    /// asked for by iOS when the group starts).
    static func ensureReady(_ then: @escaping () -> Void) {
        let go = {
            LocationHub.shared.requestPermission()
            GroupAlerts.shared.requestAuthorization()
            then()
        }
        if Prefs.shared.groupDisclosureAccepted {
            go()
            return
        }
        AppModel.shared.choose("Share your location with your group", disclosure, options: [("Continue", {
            Prefs.shared.groupDisclosureAccepted = true
            next(go)
        })], cancel: "Not now")
    }

    static func askDisplayName(_ then: @escaping (String) -> Void) {
        AppModel.shared.prompt("Your name in the group", initial: Prefs.shared.groupDisplayName, hint: "Shown on the others' maps") { name in
            then(FrontierCompat.isBlank(name) ? "Hiker" : name)
        }
    }

    private static func confirmLeaving(_ action: String, _ then: @escaping () -> Void) {
        guard let current = GroupService.shared.group else { return then() }
        AppModel.shared.confirm("Leave \(current.name)?",
                                "TrailMind is in one trip group at a time. \(action) leaves \(current.name) and deletes what this phone knows about its members.",
                                ok: "Continue") { next(then) }
    }

    static func startCreate(_ then: @escaping () -> Void) {
        confirmLeaving("A new group") {
            let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            AppModel.shared.prompt("Name this trip", initial: "Trip " + date, hint: "Trip name") { tripName in
                next {
                    askDisplayName { me in
                        next {
                            ensureReady {
                                GroupService.shared.create(name: tripName, displayName: me) { _ in then() }
                            }
                        }
                    }
                }
            }
        }
    }

    static func startJoin(code: GroupCode? = nil, name: String? = nil, _ then: @escaping () -> Void) {
        guard let code else {
            AppModel.shared.prompt("Join a trip group", hint: "Code, e.g. K7QM-2XRA-9PTW-4HNE", keyboard: .asciiCapable) { text in
                next {
                    if let parsed = GroupCode.parse(text) {
                        startJoin(code: parsed, name: name, then)
                    } else {
                        AppModel.shared.choose("That code isn't right",
                                               "Check it with whoever made the group: 16 letters and numbers, like K7QM-2XRA-9PTW-4HNE. Case and dashes don't matter.",
                                               options: [("Try again", { next { startJoin(name: name, then) } })])
                    }
                }
            }
            return
        }
        if GroupService.shared.group?.code == code { return then() }
        confirmLeaving("Joining this one") {
            askDisplayName { me in
                next {
                    ensureReady {
                        GroupService.shared.join(code: code, name: name ?? "Trip group", displayName: me) { _ in then() }
                    }
                }
            }
        }
    }

    /// Handles trailmind://group/join?code=…&name=… from an invite. Returns false for other trailmind:// links.
    static func openInvite(_ url: URL) -> Bool {
        guard let invite = GroupInvite.parse(url.absoluteString) else { return false }
        guard let code = invite.code else {
            AppModel.shared.toast("This trip group invite isn't complete. Ask for the code instead.")
            return true
        }
        Navigator.shared.open(.safety)
        AppModel.shared.confirm("Join \(invite.name ?? "this trip group")?",
                                "Phones in a trip group show each other on the map, with no signal needed.", ok: "Join") {
            next {
                startJoin(code: code, name: invite.name) { Navigator.shared.push(GroupsFeature.groupRoute) }
            }
        }
        return true
    }

    static func share(_ g: TripGroup) {
        AppModel.shared.share([GroupInvite.text(name: g.name, code: g.code)], subject: "TrailMind trip group")
    }

    // MARK: Members on the map

    /// Shows the map when a page covers it (the narrow layout).
    static func revealMap() {
        let nav = Navigator.shared
        if !nav.mapHasPane && (nav.tab != .map || nav.canGoBack) { nav.showMap() }
    }

    /// Fits everyone in the group seen in the last 15 minutes, and you, on the map.
    static func fitGroup() {
        let service = GroupService.shared
        let s = service.nowS()
        var points = service.members.compactMap { peer -> LatLon? in
            guard let pos = peer.position, PeerTable.freshness(pos, nowS: s) != .lastSeen else { return nil }
            return LatLon(pos.lat, pos.lon)
        }
        if let fix = LocationHub.shared.latest { points.append(fix.latLon) }
        let map = MapController.shared
        if points.isEmpty {
            AppModel.shared.toast("No one in the group has been heard in the last 15 minutes.")
        } else if points.count == 1 {
            revealMap()
            map.centerOn(points[0], zoom: max(map.zoom, 15))
        } else {
            revealMap()
            map.fit(BoundingBox.of(points)?.expandedByMetres(150))
        }
    }

    /// A member's details, with Go to (bearing and distance) and Show on map.
    static func showMember(_ memberId: Int) {
        let service = GroupService.shared
        guard let peer = service.members.first(where: { $0.memberId == memberId }) else { return }
        let lines = GroupText.memberDetails(peer, nowS: service.nowS(), nowMs: nowMs(), here: LocationHub.shared.latest?.latLon,
                                            imperial: Prefs.shared.imperial, inRange: service.inRange(peer),
                                            link: service.viaIPhone(memberId) ? "iPhone link" : nil)
        let name = service.nameOf(peer)
        var options: [(String, () -> Void)] = []
        if let pos = peer.position {
            let there = LatLon(pos.lat, pos.lon)
            options.append(("Go to", {
                if let goTo = FeatureHooks.goTo { goTo(name, there) } else { MapController.shared.setTarget(name, there) }
                revealMap()
                MapController.shared.centerOn(there, zoom: max(MapController.shared.zoom, 14))
            }))
            options.append(("Show on map", {
                revealMap()
                MapController.shared.centerOn(there, zoom: max(MapController.shared.zoom, 15))
            }))
        }
        AppModel.shared.choose(name, lines.joined(separator: "\n"), options: options, cancel: "Close")
    }

    /// Centres a member (from their call-for-help alert); the group may still be loading when the app starts.
    static func focusMember(_ memberId: Int, attempt: Int = 0) {
        guard let pos = GroupService.shared.members.first(where: { $0.memberId == memberId })?.position else {
            if attempt < 5 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focusMember(memberId, attempt: attempt + 1) } }
            return
        }
        revealMap()
        MapController.shared.centerOn(LatLon(pos.lat, pos.lon), zoom: max(MapController.shared.zoom, 15))
        showMember(memberId)
    }
}
