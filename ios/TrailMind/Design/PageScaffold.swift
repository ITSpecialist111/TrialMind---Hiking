import SwiftUI

/// The header every page uses (Ui.header): back arrow when there is a page behind, a large two-tone title, and any
/// actions on a wrapping row below it.
struct PageHeader<Actions: View>: View {
    @Environment(\.palette) private var p
    @Environment(\.pageCanGoBack) private var canGoBack
    let title: String
    var showBack: Bool? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 4) {
                if showBack ?? canGoBack {
                    FabButton(icon: .arrowBack, description: "Back", size: 48, flat: true, fg: p.onSurface) { Navigator.shared.pop() }
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                PageTitle(title: title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)
            let actionsView = actions()
            if !(actionsView is EmptyView) {
                FlowLayout(spacing: 8) { actionsView }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }
}

/// A short title set light then bold ("Trip *group*"); anything with numbers, names or punctuation is left plain.
struct PageTitle: View {
    @Environment(\.palette) private var p
    let title: String

    var body: some View {
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let plain = words.count < 2 || words.count > 3 || title.contains(where: { $0.isNumber || "·:,–—&/()".contains($0) })
        let size: Font = title.count <= 22 ? .system(.title, weight: .medium) : .system(.title2, weight: .medium)
        Group {
            if plain {
                Text(title).font(size)
            } else {
                (Text(words[0] + " ").font(title.count <= 22 ? .system(.title, weight: .light) : .system(.title2, weight: .light))
                 + Text(words.dropFirst().joined(separator: " ")).font(size))
            }
        }
        .foregroundStyle(p.onSurface)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    }
}

/// Standard page: header and a scrolling column body (Page.scaffold). The body is a 12 pt-spaced column with 16 pt
/// padding; the page's foot scrolls under any floating navigation.
struct PageScaffold<Actions: View, Content: View>: View {
    @Environment(\.palette) private var p
    @Environment(\.pageInsets) private var insets
    let title: String
    var showBack: Bool? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    init(_ title: String, showBack: Bool? = nil, @ViewBuilder actions: @escaping () -> Actions,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.showBack = showBack; self.actions = actions; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: title, showBack: showBack, actions: actions)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .padding(.bottom, insets.bottom)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
    }
}

extension PageScaffold where Actions == EmptyView {
    init(_ title: String, showBack: Bool? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, showBack: showBack, actions: { EmptyView() }, content: content)
    }
}
