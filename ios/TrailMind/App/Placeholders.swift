import SwiftUI

/// A page that is still to come, in the TrailMind style.
struct FeaturePlaceholder: View {
    let title: String
    let note: String

    var body: some View {
        PageScaffold(title) {
            TMCard { TMText(note) }
        }
    }
}

/// What the display and iPhone Duo's fold report right now, for checking layouts on the device (More → Display & fold).
struct DisplayDiagnosticsPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var duo = DuoState.shared

    var body: some View {
        PageScaffold("Display & fold") {
            TMCard {
                ForEach(duo.diagnostics, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).tm(.label, p)
                        Text(row.1).tm(.body, p).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HelpRow(summary: "How TrailMind uses this.",
                    detail: "When iPhone Duo is partly folded, the menu takes one side of the fold and the map the other (or the map stands above the fold on a table). On the outer display the navigation stands on the edge where iOS puts its own bars. Nothing is placed across the fold or under the cameras.")
            TMButton("Copy for a bug report", icon: .share, style: .tonal) {
                AppModel.shared.copy("Display details", duo.diagnostics.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
            }
        }
    }
}
