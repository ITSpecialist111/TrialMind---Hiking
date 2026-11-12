import SwiftUI

/// The Trip group page (ui/GroupPage.kt): create or join, the group's status, members, invite, how long the trip lasts,
/// group hikes and sharing settings.
struct GroupPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var service = GroupService.shared
    @ObservedObject private var finder = GroupService.shared.finder
    @ObservedObject private var prefs = Prefs.shared

    init() {}

    var body: some View {
        PageScaffold("Trip group") {
            if let g = service.group {
                findCard
                statusCard(g)
                membersCard(g)
                inviteCard(g)
                tripCard(g)
                hikesCard
                sharingCard
                TMButton("Leave \(g.name)", icon: .close, style: .outlined) {
                    AppModel.shared.confirm("Leave \(g.name)?",
                                            "This phone stops sharing and deletes the group's code and what it knows about the members.",
                                            ok: "Leave", danger: true) {
                        service.leave()
                        AppModel.shared.toast("Left \(g.name)")
                    }
                }
                ListItemRow(title: "Bluetooth diagnostics", subtitle: "What the radio is doing, and a reception log for range tests",
                            icon: .tune) {
                    Navigator.shared.push(GroupsFeature.diagnosticsRoute)
                }
            } else {
                GroupIntroCard {}
            }
        }
    }

    @ViewBuilder private var findCard: some View {
        if let f = finder.state, f.active {
            let who = service.members.first { $0.memberId == f.memberId }.map(service.nameOf) ?? "A member"
            TMCard(color: p.primaryContainer, spacing: 8) {
                TMText(f.role == .found ? "\(who) is finding you with UWB" : "Finding \(who) with UWB", .title)
                ActionRow {
                    TMButton("Open", style: .tonal) { Navigator.shared.push(GroupsFeature.findRoute(f.memberId)) }
                    TMButton("Stop", style: .text) { finder.stop() }
                }
            }
        }
    }

    private func statusCard(_ g: TripGroup) -> some View {
        let readiness = service.readiness()
        let boostLeft = (service.boostUntilMs - nowMs()) / 60_000
        return TMCard(spacing: 8) {
            TMText(g.name, .title)
            TMText(service.statusLine(), .body, color: readiness == .ready ? p.primary : p.danger)
            if readiness == .off {
                TMText("Frontier safety features are off on the Safety page.", .caption)
            }
            if let error = service.link.error {
                TMBanner(message: "Other iPhones can't reach this one: \(error). Allow Local Network for TrailMind in Settings, and keep Wi-Fi and Bluetooth on.",
                         danger: true)
            }
            if service.plan != nil, let problem = service.bluetooth.problem {
                TMText(problem, .caption)
            }
            if service.link.error != nil || service.bluetooth.refused {
                TMButton("Open Settings", style: .tonal) { AppModel.shared.openSettings() }
            }
            TMButton(boostLeft > 0 ? "Finding the group · \(boostLeft + 1) min left" : "Find my group", icon: .myLocation,
                     style: boostLeft > 0 ? .tonal : .filled) {
                service.boost()
                AppModel.shared.toast("Listening hard for 30 minutes. This uses more battery.")
            }
            TMText("Find my group listens and broadcasts flat out for 30 minutes. A call for help from anyone in the group does the same.", .caption)
        }
    }

    private func membersCard(_ g: TripGroup) -> some View {
        let s = service.nowS()
        let here = LocationHub.shared.latest?.latLon
        let imperial = prefs.imperial
        let peers = FrontierCompat.stableSorted(service.members) { a, b in
            let helpA = a.position?.status.needsHelp == true
            let helpB = b.position?.status.needsHelp == true
            if helpA != helpB { return helpA }
            let inA = service.inRange(a)
            let inB = service.inRange(b)
            if inA != inB { return inA }
            return FrontierCompat.compare(service.nameOf(a).lowercased(), service.nameOf(b).lowercased()) < 0
        }
        let own = prefs.frontierHeartbeatsEnabled
            ? GroupText.ownSubtitle(service.ownFrame, nowS: s, paused: service.plan == nil) : "Your position isn't shared"
        return TMCard(spacing: 6) {
            TMText("Members", .title)
            MemberRow(initials: GroupText.initials(g.displayName), colour: service.ownColour(), title: "You · \(g.displayName)",
                      subtitle: own, help: false) {
                GroupFlows.askDisplayName { name in service.rename(name) }
            }
            if peers.isEmpty {
                TMText("No one heard yet. Others appear when their phone is in range with TrailMind open or a hike recording.", .caption)
            }
            ForEach(peers, id: \.memberId) { peer in
                MemberRow(initials: GroupText.initials(service.nameOf(peer)), colour: service.colourOf(peer), title: service.nameOf(peer),
                          subtitle: GroupText.subtitle(peer, nowS: s, here: here, imperial: imperial, inRange: service.inRange(peer)),
                          help: peer.position?.status.needsHelp == true,
                          find: finder.canFind(peer) ? { startFind(peer.memberId) } : nil) {
                    GroupFlows.showMember(peer.memberId)
                }
            }
        }
    }

    private func inviteCard(_ g: TripGroup) -> some View {
        TMCard(spacing: 8) {
            TMText("Invite", .title)
            TMText("Read the code out to the others, or send it. Anyone with it can see the group while in range, so share it only with your party.", .caption)
            Text(g.code.formatted)
                .font(.system(.title2, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(p.onSurface)
                // One line even in the narrow side pane, where it shrinks rather than breaking the code.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
                .accessibilityLabel("Code " + g.code.formatted.map { String($0) }.joined(separator: " "))
            ActionRow {
                TMButton("Send invite", icon: .share, style: .tonal) { GroupFlows.share(g) }
                TMButton("Copy code", style: .text) { AppModel.shared.copy("Trip group code", g.code.formatted) }
            }
        }
    }

    private func tripCard(_ g: TripGroup) -> some View {
        let ends = DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(g.expiresMs) / 1_000),
                                                 dateStyle: .medium, timeStyle: .short)
        return TMCard(spacing: 6) {
            TMText("Trip ends " + ends)
            TMText("Then this phone stops sharing and deletes the group. A hike that's still recording keeps it going.", .caption)
            TMButton("Add a day", icon: .add, style: .tonal) {
                service.extend()
                AppModel.shared.toast("The trip now ends a day later.")
            }
        }
    }

    private var hikesCard: some View {
        TMCard(spacing: 4) {
            TMText("Group hikes", .title)
            TMToggle(label: "Log hikes for everyone in the group", isOn: $prefs.groupHikes)
            if prefs.groupHikes {
                TMToggle(label: "Ask me before recording a group hike", isOn: $prefs.groupHikesAsk)
            }
            TMText("When someone in the group starts a hike, everyone else's TrailMind records its own copy, with its own track, time and distance. " +
                   "Your phone does the same when you start one. It only reaches members whose TrailMind is open (Android phones also while recording), " +
                   "and it never uploads anything: each hike is saved on the phone that recorded it. You still finish yours yourself.", .caption)
        }
    }

    private var sharingCard: some View {
        TMCard(spacing: 4) {
            TMText("Sharing", .title)
            TMToggle(label: "Share my position with the group", isOn: $prefs.frontierHeartbeatsEnabled)
            TMToggle(label: "Pass on other members' positions", isOn: $prefs.groupRelayEnabled)
            TMToggle(label: "Show the group on the map", isOn: $prefs.groupShowOnMap)
            TMToggle(label: "Alert me if someone needs help", isOn: $prefs.groupHelpAlerts)
            if GroupFinder.supported {
                TMToggle(label: "Let the group find me up close with UWB", isOn: $prefs.groupUwbFindable)
                TMText(prefs.groupUwbFindable
                       ? "UWB is on. Members' iPhones close by with UWB show a Find button for distance, and direction where the iPhone reports it."
                       : "Members can't find this iPhone up close.", .caption)
            }
            TMText("Passing on positions lets the group reach further than one phone: each phone between two hikers adds a hop. " +
                   "Range depends on phones, pockets and ground, from tens of metres in woods to more in the open. Carry the phone high on your body.",
                   .caption)
            TMText("On iPhone there's no long-range (LE Coded) Bluetooth, and iOS can't send the Bluetooth adverts Android phones listen for, " +
                   "so Android members don't see iPhones. iPhones link to each other over Wi-Fi and Bluetooth and hear Android members " +
                   "while TrailMind is open; iOS pauses sharing soon after you leave TrailMind or lock the screen.", .caption)
        }
    }

    private func startFind(_ memberId: Int) {
        finder.find(memberId)
        Navigator.shared.push(GroupsFeature.findRoute(memberId))
    }
}

/// One member: a disc with their initials in their colour (red when they need help), name and status line, and Find
/// beside them when there is room, or under the text in a narrow pane.
private struct MemberRow: View {
    @Environment(\.palette) private var p
    let initials: String
    let colour: UInt32
    let title: String
    let subtitle: String
    let help: Bool
    var find: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        if let find {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    // Room for about twenty characters of text a line before Find moves under it.
                    details.frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
                    findButton(find)
                }
                VStack(alignment: .leading, spacing: 4) {
                    details
                    findButton(find).padding(.leading, 48)
                }
            }
        } else {
            details
        }
    }

    private var details: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(initials)
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(help ? p.danger : Color(argb: colour)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).tm(.body, p).multilineTextAlignment(.leading)
                    Text(subtitle).tm(.caption, p, color: help ? p.danger : nil).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
    }

    private func findButton(_ find: @escaping () -> Void) -> some View {
        TMButton("Find", style: .tonal, action: find)
            .fixedSize()
            .accessibilityLabel("Find \(title) with UWB")
    }
}

/// Explains trip groups and offers Create and Join (groupIntroCard): on the Safety page and the empty Trip group page.
struct GroupIntroCard: View {
    var done: () -> Void

    var body: some View {
        TMCard(spacing: 8) {
            TMText("See your party on the map, with no signal", .title)
            TMText("Each phone in the group shares its position straight to the others, sealed with the group's code, and passes on the " +
                   "others' positions so the group reaches further than one phone can. It works while TrailMind is open, with no mobile " +
                   "signal (Android phones also share while a hike records).")
            TMText("Range depends on phones, pockets and ground: tens of metres in woods, more in the open, and further along a strung-out group.",
                   .caption)
            TMText("iPhones link straight to each other and hear Android members' Bluetooth while TrailMind is open. iOS can't send the " +
                   "Bluetooth adverts Android phones listen for, so Android members won't see iPhones.", .caption)
            ActionRow {
                TMButton("Create group", icon: .add, style: .filled) { GroupFlows.startCreate(done) }
                TMButton("Join with code", style: .tonal) { GroupFlows.startJoin(done) }
            }
        }
    }
}

/// The trip group on the Safety page (SafetyPage.groupCard): its status and anyone calling for help, or the intro card.
struct GroupSafetyCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var service = GroupService.shared

    init() {}

    var body: some View {
        if let g = service.group {
            TMCard(spacing: 8) {
                TMText("Trip group · \(g.name)", .title)
                TMText(service.statusLine(), .body, color: service.readiness() == .ready ? p.primary : p.danger)
                ForEach(service.members.filter { $0.position?.status.needsHelp == true }, id: \.memberId) { peer in
                    TMBanner(message: "\(service.nameOf(peer)) needs help. Open the trip group to see where.", danger: true)
                }
                TMButton("Open trip group", style: .tonal) { Navigator.shared.push(GroupsFeature.groupRoute) }
            }
        } else {
            GroupIntroCard { Navigator.shared.push(GroupsFeature.groupRoute) }
        }
    }
}
