import Combine
import SwiftUI

/// "Start hike", or the recording card with its time, distance, climb and pace and the Pause/Resume and Finish
/// buttons, at the foot of the map (MapScreen.updateTracking). It gives way to the route planner's card while planning.
struct RecordBar: View {
    @Environment(\.palette) private var p
    @ObservedObject private var recorder = HikeRecorder.shared
    @State private var planning = false

    var body: some View {
        VStack(spacing: 0) {
            if planning {
                EmptyView()
            } else if recorder.status == .idle {
                startButton
            } else {
                HStack {
                    Spacer(minLength: 0)
                    HikeRecordingCard(recorder: recorder)
                        .frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { planning = MapController.shared.tapOverride != nil }
        .onReceive(MapController.shared.$revision.map { _ in MapController.shared.tapOverride != nil }.removeDuplicates()) { planning = $0 }
    }

    private var startButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button { HikeRecorder.shared.startRecording() } label: {
                HStack(spacing: 8) {
                    TMIconView(icon: .play, size: 22, color: p.onPrimary)
                    Text("Start hike").font(.system(.subheadline, weight: .medium))
                }
                .foregroundStyle(p.onPrimary)
                .padding(.leading, 26)
                .padding(.trailing, 28)
                .frame(minHeight: 56)
                .background(Capsule().fill(p.primary).shadow(color: .black.opacity(0.25), radius: 8, y: 4))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Start hike")
            Spacer(minLength: 0)
        }
    }
}

/// The frosted card shown while a hike records or is paused.
private struct HikeRecordingCard: View {
    @Environment(\.palette) private var p
    @ObservedObject var recorder: HikeRecorder
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let paused = recorder.status == .paused
        GlassCard(padding: 12, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in stats(paused: paused) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                FabButton(icon: paused ? .play : .pause, description: paused ? "Resume" : "Pause",
                          bg: p.primaryContainer, fg: p.onPrimaryContainer) {
                    if paused { recorder.resume() } else { recorder.pause() }
                }
                FabButton(icon: .stop, description: "Finish", bg: p.danger, fg: .white) { recorder.confirmFinish() }
            }
            if let openCheckIn = FeatureHooks.openCheckIn {
                // Check-in as a small chip, so the recording card stays short and the map stays visible.
                FlowLayout(spacing: 6) {
                    TMChip(prefs.checkInDueMs > 0 ? "Check-in \(HikeTime.time(prefs.checkInDueMs)) · Edit" : "Set check-in") { openCheckIn() }
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func stats(paused: Bool) -> some View {
        let imperial = prefs.imperial
        let active = recorder.activeMs
        let time = StatView(label: paused ? "Paused" : "Time", value: Units.duration(active))
        let distance = StatView(label: "Distance", value: Units.distance(recorder.track.distanceM, imperial: imperial))
        let ascent = StatView(label: "Ascent", value: "↑" + Units.elevation(recorder.track.ascentM, imperial: imperial))
        let pace = StatView(label: "Pace", value: HikeText.averagePace(distanceM: recorder.track.distanceM, activeMs: active, imperial: imperial))
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { time; distance; ascent; pace }
            HStack(alignment: .top, spacing: 14) { time; distance; ascent }
        }
    }
}

/// The "Following" card for the route being followed: distance, time and climb to go, off-route warnings with the way
/// back, the next waypoint and the daylight check (MapScreen.updateNav).
struct GuidanceCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var guidance = Guidance.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if let route = guidance.core.active {
            card(route)
        }
    }

    private func card(_ route: GuidedRoute) -> some View {
        let core = guidance.core
        let imperial = prefs.imperial
        let offRoute = core.offRoute
        let here = LocationHub.shared.latest?.latLon
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Following").tm(.label, p, color: p.primary)
                    Text(route.name).font(.system(.callout, weight: .medium)).foregroundStyle(p.onSurface).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HikeCardIconButton(icon: .close, description: "Stop following") {
                    AppModel.shared.confirm("Stop following?", "The route will be removed from the map.", ok: "Stop") {
                        Guidance.shared.stopFollowing()
                    }
                }
            }
            if let fix = core.fix {
                let stats = HikeText.guidanceStats(fix, remainingMinutes: core.remainingMinutes, imperial: imperial)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<4, id: \.self) { i in StatView(label: HikeText.guidanceStatLabels[i], value: stats[i]) }
                }
                if let status = HikeText.guidanceStatus(fix, offRoute: offRoute, here: here, imperial: imperial) {
                    if offRoute {
                        TMText(status, .title, color: p.danger)
                    } else {
                        TMText(status, .caption)
                    }
                }
                if let next = HikeText.nextWaypoint(fix, imperial: imperial) { TMText(next, .caption) }
                if let line = guidance.daylightLine() {
                    let warn = core.routeStarted && core.daylight?.afterSafeSunset == true
                    Button { Guidance.shared.showDaylightCheck() } label: {
                        Text(line).tm(.caption, p, color: warn ? p.danger : p.onSurface)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the daylight check")
                }
            } else {
                TMText(HikeText.waiting(totalM: route.guide.totalM, planningMinutes: route.estimate.planningMinutes, imperial: imperial), .caption)
            }
        }
        .padding(14)
        .background {
            if offRoute {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.dangerContainer)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.outline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            } else {
                Color.clear.glassBackground(p, radius: 20)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The "Go to" card: straight-line distance and bearing to the target from where you are (MapScreen.updateTarget).
struct GoToCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var state = GoToState.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if let target = state.target {
            let place = HikeText.place(target.position)
            GlassCard(padding: 14, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Go to").tm(.label, p, color: p.accent)
                    Text(place).tm(.title, p).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HikeCardIconButton(icon: .close, description: "Clear target") { Guidance.shared.clearTarget() }
                }
                if !target.title.isBlank && target.title != place && target.title != Units.latLon(target.position.lat, target.position.lon) {
                    TMText(target.title, .caption)
                }
                TMText(HikeText.goToDetail(here: state.here, target: target.position, imperial: prefs.imperial), .caption)
            }
        }
    }
}

/// What the go-to card shows: the map's target and, only while there is one, your position.
final class GoToState: ObservableObject {
    static let shared = GoToState()
    @Published private(set) var target: MapPin? = MapController.shared.target
    @Published private(set) var here: LatLon? = LocationHub.shared.latest?.latLon
    private var cancellables = Set<AnyCancellable>()

    private init() {
        MapController.shared.$target
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.here = LocationHub.shared.latest?.latLon
                self?.target = t
            }
            .store(in: &cancellables)
        LocationHub.shared.$latest
            .map { $0?.latLon }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in
                guard let self, self.target != nil else { return }
                self.here = p
            }
            .store(in: &cancellables)
    }
}

/// Offers to resume or finish a hike whose recording was interrupted (MapScreen.updateRecover).
struct RecoverCard: View {
    @Environment(\.palette) private var p
    @ObservedObject private var recorder = HikeRecorder.shared

    var body: some View {
        if recorder.status == .idle, let h = recorder.unfinished {
            TMCard(color: p.warnContainer, padding: 14, spacing: 8) {
                TMText("Unfinished recording: \(h.name)", .title)
                TMText(HikeRecorder.recoverDetail(h), .caption)
                ActionRow {
                    TMButton("Resume", icon: .play, style: .filled) { HikeRecorder.shared.resumeHike(h.id) }
                    TMButton("Finish", icon: .stop, style: .tonal) { HikeRecorder.shared.finishUnfinished(h) }
                }
            }
        }
    }
}

/// A small muted icon button inside a card over the map (MapScreen.miniIcon), with a full-size touch target.
struct HikeCardIconButton: View {
    @Environment(\.palette) private var p
    let icon: TMIcon
    let description: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TMIconView(icon: icon, size: 20, color: p.muted)
                .frame(width: 36, height: 36)
                .background(Circle().fill(p.surfaceVariant.opacity(0.6)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(description)
        .padding(-4)
    }
}
