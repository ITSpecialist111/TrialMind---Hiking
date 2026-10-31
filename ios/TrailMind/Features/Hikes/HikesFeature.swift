import SwiftUI

// Placeholders for the hikes feature (recording, history, guidance on the map).
// The hikes feature replaces this whole file with its real implementation.

struct HikesPage: View {
    var body: some View { FeaturePlaceholder(title: "Hikes", note: "Hike recording and history are being ported.") }
}

/// Start hike / the recording card at the foot of the map.
struct RecordBar: View {
    var body: some View { EmptyView() }
}

/// "Following" card for the active route (distance and ascent left, off-route warnings).
struct GuidanceCard: View {
    var body: some View { EmptyView() }
}

/// "Go to" bearing and distance card.
struct GoToCard: View {
    var body: some View { EmptyView() }
}

/// Offer to recover an unfinished hike.
struct RecoverCard: View {
    var body: some View { EmptyView() }
}
