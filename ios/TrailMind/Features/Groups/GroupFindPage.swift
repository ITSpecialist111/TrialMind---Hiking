import SwiftUI

/// Distance and direction to one member with UWB, or who is finding this phone (ui/GroupFindPage.kt).
struct GroupFindPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var service = GroupService.shared
    @ObservedObject private var finder = GroupService.shared.finder
    @ObservedObject private var prefs = Prefs.shared
    let memberId: Int

    init(memberId: Int) {
        self.memberId = memberId
    }

    private var mine: GroupFinder.State? {
        guard let s = finder.state, s.memberId == memberId else { return nil }
        return s
    }

    private var peer: PeerTable.Peer? { service.members.first { $0.memberId == memberId } }
    private var name: String { peer.map(service.nameOf) ?? "your group member" }

    var body: some View {
        let found = mine?.role == .found
        PageScaffold(found ? "\(name) is finding you" : "Find \(name)") {
            // Ticks so a measurement turns stale when results stop, which nothing reports.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                findCard(mine, found: found)
            }
            TMCard(spacing: 6) {
                TMText("How it works", .title)
                TMText("Ultra-wideband (UWB) measures the distance between two iPhones to within about 10 cm, up to about 50 m when nothing " +
                       "is between them. Bodies, rock and trees shorten that. Both iPhones need TrailMind open on screen, with Nearby " +
                       "Interaction allowed; flight mode turns UWB off. iPhones can't find Android phones this way.", .caption)
                if !found {
                    TMText(GroupFinder.direction
                           ? "Hold the phone upright in front of you and turn slowly until the arrow points up."
                           : "This phone measures distance only: walk and watch the number fall.", .caption)
                }
            }
        }
    }

    private func findCard(_ s: GroupFinder.State?, found: Bool) -> some View {
        let m = s?.measurement
        let fresh = s.map { $0.measuredAt > 0 && ProcessInfo.processInfo.systemUptime - $0.measuredAt < GroupFinder.staleS } ?? false
        let arrow = !found && GroupFinder.direction
        return TMCard(spacing: 12) {
            TMText(status(s, fresh: fresh))
            if let s, s.active {
                if arrow {
                    UwbArrow(azimuthDeg: fresh ? m?.azimuthDeg : nil)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                }
                Text(m?.distanceM.map { GroupText.uwbDistance($0, imperial: prefs.imperial) } ?? "—")
                    .tm(.display, p)
                    .opacity(fresh ? 1 : 0.4)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.updatesFrequently)
                if arrow {
                    Text(GroupText.direction(azimuthDeg: m?.azimuthDeg, elevationDeg: m?.elevationDeg, measured: m != nil, fresh: fresh))
                        .tm(.body, p)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                TMButton("Stop", style: .outlined) { finder.stop() }
            } else if let peer, finder.canFind(peer) {
                TMButton(s == nil ? "Find \(name)" : "Try again", style: .filled) { finder.find(memberId) }
            }
        }
    }

    private func status(_ s: GroupFinder.State?, fresh: Bool) -> String {
        guard let s else {
            guard let peer else { return "\(name) isn't in your group any more." }
            return finder.canFind(peer)
                ? "Both phones have UWB. Find them to see how far away they are."
                : "\(name)'s phone needs to be an iPhone with UWB, in range, with TrailMind open."
        }
        if !s.active { return s.note ?? "Stopped." }
        if s.role == .found { return fresh ? "\(name) is finding you with UWB." : "\(name) is finding you with UWB. Waiting for their phone." }
        switch s.phase {
        case .asking: return "Asking \(name)'s phone to answer…"
        case .starting: return s.note ?? "Starting UWB…"
        default:
            if let note = s.note { return note }
            return fresh ? "Measuring with UWB." : "Lost the UWB signal. Move closer, or somewhere nothing is between you."
        }
    }
}

/// An arrow that points at the member: up is straight ahead, turned by the UWB azimuth (UwbArrowView).
struct UwbArrow: View {
    @Environment(\.palette) private var p
    let azimuthDeg: Double?

    var body: some View {
        GeometryReader { geo in
            let r = max(min(geo.size.width, geo.size.height) / 2 - 8, 1)
            ZStack {
                Circle().stroke(p.outline, lineWidth: 2).frame(width: 2 * r, height: 2 * r)
                if let azimuth = azimuthDeg {
                    UwbArrowShape().fill(p.primary).frame(width: 2 * r, height: 2 * r).rotationEffect(.degrees(azimuth))
                } else {
                    Circle().fill(p.muted.opacity(0.35)).frame(width: r * 0.36, height: r * 0.36)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel(azimuthDeg.map { "Direction arrow, \(kRound($0)) degrees" } ?? "Waiting for a direction")
    }
}

private struct UwbArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r * 0.85))
        path.addLine(to: CGPoint(x: cx + r * 0.32, y: cy - r * 0.2))
        path.addLine(to: CGPoint(x: cx + r * 0.11, y: cy - r * 0.2))
        path.addLine(to: CGPoint(x: cx + r * 0.11, y: cy + r * 0.6))
        path.addLine(to: CGPoint(x: cx - r * 0.11, y: cy + r * 0.6))
        path.addLine(to: CGPoint(x: cx - r * 0.11, y: cy - r * 0.2))
        path.addLine(to: CGPoint(x: cx - r * 0.32, y: cy - r * 0.2))
        path.closeSubpath()
        return path
    }
}
