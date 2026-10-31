import Combine
import SwiftUI

/// Trip groups: see your party on the map with no signal (frontier/group on Android).
enum GroupsFeature {
    private static var started = false
    private static var pendingInvite: URL?
    private static var cancellables = Set<AnyCancellable>()

    static var groupRoute: PageRoute { PageRoute("trip-group") { GroupPage() } }
    static func findRoute(_ memberId: Int) -> PageRoute { PageRoute("trip-group-find-\(memberId)") { GroupFindPage(memberId: memberId) } }
    static var diagnosticsRoute: PageRoute { PageRoute("trip-group-diagnostics") { GroupDiagnosticsPage() } }

    /// Starts the group (if this phone is in one), sets the cross-feature hooks and handles invite links and alerts.
    static func start() {
        guard !started else { return }
        started = true
        GroupAlerts.shared.install()
        GroupAlerts.shared.onOpenMember = { memberId in GroupFlows.focusMember(memberId) }
        // MainActivity's ACTION_GROUP_FIND: the Safety tab with the find on top.
        GroupAlerts.shared.onOpenFind = { memberId in Navigator.shared.open(.safety, findRoute(memberId)) }
        GroupAlerts.shared.onStopFind = { GroupService.shared.finder.stop() }

        FeatureHooks.groupSummary = {
            let service = GroupService.shared
            guard service.group != nil else { return nil }
            return service.summary() ?? "Group"
        }
        FeatureHooks.fitGroup = { GroupFlows.fitGroup() }
        FeatureHooks.openGroup = { Navigator.shared.push(groupRoute) }
        FeatureHooks.groupSafetyCard = { AnyView(GroupSafetyCard()) }
        FeatureHooks.hikeStartedListeners.append { _, _ in GroupService.shared.setRecording(true) }
        FeatureHooks.hikeFinishedListeners.append { _ in
            GroupService.shared.hikeFinished()
            GroupService.shared.setRecording(false)
        }
        MapController.shared.onSelectMember = { marker in GroupFlows.showMember(marker.id) }

        AppEvents.shared.urlHandlers.append { url in
            guard url.scheme?.lowercased() == GroupInvite.scheme, url.host == GroupInvite.host else { return false }
            // Invites that arrive while onboarding is showing wait for it (MainActivity.handlePendingIntent).
            if !Prefs.shared.onboardingAccepted {
                pendingInvite = url
                return true
            }
            return GroupFlows.openInvite(url)
        }
        Prefs.shared.$onboardingAccepted
            .removeDuplicates()
            .filter { $0 }
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { _ in
                guard let url = pendingInvite else { return }
                pendingInvite = nil
                _ = GroupFlows.openInvite(url)
            }
            .store(in: &cancellables)

        GroupService.shared.start()
    }
}

/// The trip group's chip on the map: "Group 2/3", and a tap fits everyone on screen.
struct GroupChip: View {
    @ObservedObject private var service = GroupService.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        if service.group != nil && prefs.groupShowOnMap && prefs.frontierEnabled {
            let summary = service.summary() ?? "Group"
            TMChip(summary, glass: true) { GroupFlows.fitGroup() }
                .accessibilityLabel("Trip group, " + summary)
                .accessibilityHint("Shows the trip group on the map")
        } else {
            EmptyView()
        }
    }
}
