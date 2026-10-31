import SwiftUI

/// The planner's frosted card on the map while a route is being planned (MapScreen.plannerCard): distance, climb and
/// time so far, snapping to paths, Undo, Clear, Back to start and Save. Nothing shows when no plan is open.
struct PlannerCard: View {
    @ObservedObject private var planner = RoutePlanner.shared

    init() {}

    var body: some View {
        if planner.active {
            PlannerCardContent(planner: planner)
        }
    }
}

private struct PlannerCardContent: View {
    @Environment(\.palette) private var p
    @ObservedObject var planner: RoutePlanner
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let plan = planner.plan
        let points = plan.controlPoints
        let line = plan.line
        let summary = TrackStats.summarize(line)
        let estimate = plan.estimate(prefs.routePace)
        let imperial = prefs.imperial
        GlassCard(padding: 12, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("Plan a route").tm(.title, p).frame(maxWidth: .infinity, alignment: .leading)
                PlannerIconButton(icon: .close, description: "Close planner") { planner.askToClose() }
            }
            HStack(alignment: .top, spacing: 8) {
                StatView(label: "Distance", value: Units.distance(summary.distanceM, imperial: imperial))
                StatView(label: "Ascent", value: Units.elevation(summary.ascentM, imperial: imperial))
                StatView(label: "Time", value: Units.minutes(estimate.planningMinutes))
            }
            TMToggle(label: "Snap to paths", isOn: Binding(get: { planner.snap }, set: { planner.setSnap($0) }))
            FlowLayout(spacing: 4) {
                TMButton("Undo", icon: .remove, style: .tonal) {
                    planner.flushPendingTaps()
                    planner.undo()
                }
                .disabled(points.isEmpty)
                TMButton("Clear", icon: .delete, style: .tonal) {
                    planner.flushPendingTaps()
                    planner.clear()
                }
                .disabled(points.isEmpty)
                TMButton("Back to start", icon: .route, style: .tonal) {
                    planner.flushPendingTaps()
                    planner.backToStart()
                }
                .disabled(points.count < 2 || plan.isLoop || planner.pending)
                TMButton("Save", icon: .folder) { planner.askToSave() }
                    .disabled(points.count < 2 || planner.pending || planner.saving)
            }
            TMText(RouteText.plannerStatus(pending: planner.pending, points: points.count), .caption)
            if let notice = planner.notice { TMText(notice, .caption) }
            TMText(BRouter.attribution, .caption)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A small muted icon button inside a card over the map (MapScreen.miniIcon), with a full-size touch target.
struct PlannerIconButton: View {
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
