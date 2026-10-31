import SwiftUI

// MARK: - Surfaces

/// Borderless tonal card: the surface colour alone separates it from the page (Ui.card).
struct TMCard<Content: View>: View {
    @Environment(\.palette) private var p
    var color: Color? = nil
    var padding: CGFloat = 16
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(color ?? p.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Frosted card for floating over the map: translucent, with a hairline edge (Ui.glassCard).
struct GlassCard<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 12
    var spacing: CGFloat = 6
    var radius: CGFloat = 26
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(padding)
            .glassBackground(p, radius: radius)
    }
}

extension View {
    /// The frosted plate used by every control over the map.
    func glassBackground(_ p: Palette, radius: CGFloat, shadow: CGFloat = 6) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(p.glass))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(p.glassStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: shadow, y: shadow / 3)
        }
    }
}

// MARK: - Buttons

enum TMButtonStyleKind { case filled, tonal, outlined, text, danger }

/// Pill button (Ui.button): 48 pt minimum height, medium 15 pt label, optional leading icon.
struct TMButton: View {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    let label: String
    var icon: TMIcon? = nil
    var style: TMButtonStyleKind = .filled
    var fill: Bool = false
    let action: () -> Void

    init(_ label: String, icon: TMIcon? = nil, style: TMButtonStyleKind = .filled, fill: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.style = style; self.fill = fill; self.action = action
    }

    private var colors: (bg: Color, fg: Color) {
        switch style {
        case .filled: return (p.primary, p.onPrimary)
        case .tonal: return (p.primaryContainer, p.onPrimaryContainer)
        case .outlined, .text: return (.clear, p.primary)
        case .danger: return (p.danger, .white)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { TMIconView(icon: icon, size: 20, color: colors.fg) }
                Text(label).font(.system(.subheadline, weight: .medium)).multilineTextAlignment(.center)
            }
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Capsule().fill(colors.bg))
            .overlay(Capsule().strokeBorder(style == .outlined ? p.outline : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A gentle press response in place of Android's ripple.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Round icon button (Ui.fab). Floating alone it has a surface disc and shadow; `flat` sits inside a capsule of tools.
struct FabButton: View {
    @Environment(\.palette) private var p
    let icon: TMIcon
    let description: String
    var size: CGFloat = 48
    var flat: Bool = false
    var bg: Color? = nil
    var fg: Color? = nil
    var rotation: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TMIconView(icon: icon, size: 24, color: fg ?? p.onSurface)
                .rotationEffect(.degrees(rotation))
                .frame(width: size, height: size)
                .background {
                    if !flat { Circle().fill(bg ?? p.surface).shadow(color: .black.opacity(0.2), radius: 4, y: 2) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(description)
    }
}

// MARK: - Chips

/// Pill label (Ui.chip). `glass` is the compact frosted kind for floating over the map.
struct TMChip: View {
    @Environment(\.palette) private var p
    let label: String
    var selected: Bool = false
    var glass: Bool = false
    var wrap: Bool = false
    var icon: TMIcon? = nil
    var tint: Color? = nil
    var action: (() -> Void)? = nil

    init(_ label: String, selected: Bool = false, glass: Bool = false, wrap: Bool = false, icon: TMIcon? = nil,
         tint: Color? = nil, action: (() -> Void)? = nil) {
        self.label = label; self.selected = selected; self.glass = glass; self.wrap = wrap; self.icon = icon
        self.tint = tint; self.action = action
    }

    var body: some View {
        let content = HStack(spacing: 6) {
            if let icon { TMIconView(icon: icon, size: 16, color: tint ?? (selected ? p.onPrimaryContainer : p.onSurface)) }
            Text(label)
                .font(.system(glass ? .caption : .footnote, weight: .medium))
                .lineLimit(wrap ? 3 : 1)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(tint ?? (selected ? p.onPrimaryContainer : p.onSurface))
        .padding(.horizontal, glass ? 11 : 13)
        .padding(.vertical, glass ? 6 : 8)
        .background {
            if glass {
                if selected { Capsule().fill(p.primaryContainer).overlay(Capsule().strokeBorder(p.glassStroke)) }
                else { Color.clear.glassBackground(p, radius: 18, shadow: 3) }
            } else {
                Capsule().fill(selected ? p.primaryContainer : p.surfaceVariant)
            }
        }
        .contentShape(Capsule())

        if let action {
            Button(action: action) { content }.buttonStyle(PressScaleStyle())
        } else {
            content
        }
    }
}

// MARK: - Statistics

private let numberUnit = try! NSRegularExpression(pattern: "^([↑↓+\\-]?\\d[\\d.,]*)[\\s\\u00A0]*([A-Za-z°%/²]+)$")

/// A figure set large with its unit small and muted ("360 m", "14.8 km/h"), as on Android.
struct NumberUnitText: View {
    @Environment(\.palette) private var p
    let value: String
    var big: Bool = false

    var body: some View {
        let ns = value as NSString
        if let m = numberUnit.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 3 {
            let number = ns.substring(with: m.range(at: 1))
            let unit = ns.substring(with: m.range(at: 2))
            (Text(number).font(big ? .system(.title, weight: .medium) : .system(.title3, weight: .medium)).foregroundColor(p.onSurface)
             + Text("\u{00A0}" + unit).font(big ? .system(.callout, weight: .medium) : .system(.footnote, weight: .medium)).foregroundColor(p.muted))
        } else {
            Text(value).font(big ? .system(.title, weight: .medium) : .system(.title3, weight: .medium)).foregroundColor(p.onSurface)
        }
    }
}

/// Label over a value, shrunk to fit its column (Ui.stat).
struct StatView: View {
    @Environment(\.palette) private var p
    let label: String
    let value: String
    var big: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).tm(.label, p).lineLimit(1).minimumScaleFactor(0.6)
            NumberUnitText(value: value, big: big).lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Grid of stat tiles, `cols` per row (Ui.statGrid).
struct StatGrid: View {
    let items: [(String, String)]
    var cols: Int = 3

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: cols).map { Array(items[$0..<min($0 + cols, items.count)]) }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rows[r].indices, id: \.self) { c in StatView(label: rows[r][c].0, value: rows[r][c].1) }
                    ForEach(0..<(cols - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

// MARK: - Inputs

/// Text field on a tonal rounded rectangle (Ui.input).
struct TMField: View {
    @Environment(\.palette) private var p
    let hint: String
    @Binding var text: String
    var secure: Bool = false
    var keyboard: UIKeyboardType = .default
    var multiline: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(hint, text: $text)
            } else if multiline {
                TextField(hint, text: $text, axis: .vertical).lineLimit(2...6)
            } else {
                TextField(hint, text: $text)
            }
        }
        .keyboardType(keyboard)
        .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
        .autocorrectionDisabled(keyboard != .default)
        .font(.system(.subheadline))
        .foregroundStyle(p.onSurface)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(p.surfaceVariant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A labelled switch with the primary track (Ui.switch).
struct TMToggle: View {
    @Environment(\.palette) private var p
    let label: String
    @Binding var isOn: Bool
    var detail: String? = nil

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(.subheadline)).foregroundStyle(p.onSurface)
                if let detail { Text(detail).tm(.caption, p) }
            }
        }
        .tint(p.primary)
        .frame(minHeight: 48)
    }
}

struct TMProgress: View {
    @Environment(\.palette) private var p
    let value: Double

    var body: some View {
        ProgressView(value: value.clamped(0, 1)).tint(p.primary)
    }
}

struct TMDivider: View {
    @Environment(\.palette) private var p
    var body: some View { Rectangle().fill(p.outline).frame(height: 1) }
}

/// Caption with an (i) button that explains it in a dialog (Ui.help).
struct HelpRow: View {
    @Environment(\.palette) private var p
    let summary: String
    let detail: String
    @State private var showing = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(summary).tm(.caption, p).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            FabButton(icon: .info, description: "More information: \(summary)", size: 40, flat: true, fg: p.muted) { showing = true }
        }
        .alert(summary, isPresented: $showing) { Button("OK", role: .cancel) {} } message: { Text(detail) }
    }
}

/// An underlined caption that opens its source, for credits whose licence asks for a link (Ui.link).
struct TMLink: View {
    @Environment(\.palette) private var p
    @Environment(\.openURL) private var openURL
    let label: String
    let url: URL

    var body: some View {
        Button { openURL(url) } label: {
            Text(label).font(.system(.footnote)).underline().foregroundStyle(p.primary).frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lists and banners

/// A list row (Ui.listItem): icon tile, title up to three lines, subtitle, and status badge below the text.
struct ListItemRow: View {
    @Environment(\.palette) private var p
    let title: String
    var subtitle: String? = nil
    var icon: TMIcon? = nil
    var badge: String? = nil
    var info: String? = nil
    var selected: Bool? = nil
    let action: () -> Void
    @State private var showingInfo = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: action) {
                HStack(alignment: .center, spacing: 10) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected ? p.primary : p.muted)
                    }
                    if let icon { IconTile(icon: icon) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(.callout, weight: .medium)).foregroundStyle(p.onSurface).lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if let subtitle, !subtitle.isEmpty { Text(subtitle).tm(.caption, p).multilineTextAlignment(.leading) }
                        if let badge { TMChip(badge, selected: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            if let info {
                FabButton(icon: .info, description: "About \(title)", size: 40, flat: true, fg: p.muted) { showingInfo = true }
                    .alert(title, isPresented: $showingInfo) { Button("OK", role: .cancel) {} } message: { Text(info) }
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Rounded-square icon tile, the tile shape the Android look uses throughout.
struct IconTile: View {
    @Environment(\.palette) private var p
    let icon: TMIcon
    var size: CGFloat = 40
    var bg: Color? = nil
    var fg: Color? = nil

    var body: some View {
        TMIconView(icon: icon, size: size / 2, color: fg ?? p.primary)
            .frame(width: size, height: size)
            .background(bg ?? p.primaryContainer, in: RoundedRectangle(cornerRadius: size * 0.33, style: .continuous))
    }
}

/// Warning or danger banner (Ui.banner).
struct TMBanner: View {
    @Environment(\.palette) private var p
    let message: String
    var danger: Bool = false
    var icon: TMIcon = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TMIconView(icon: icon, size: 22, color: danger ? p.danger : p.accent)
            Text(message).font(.system(.footnote)).foregroundStyle(p.onSurface).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(danger ? p.dangerContainer : p.warnContainer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Section label in the LABEL style.
struct SectionLabel: View {
    @Environment(\.palette) private var p
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).tm(.label, p).padding(.top, 4) }
}

// MARK: - Layout helpers

/// Lays children out left to right and wraps onto new lines, so no chip or button is ever pushed off-screen.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: maxW == .infinity ? nil : maxW, height: nil))
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > 0 && x + s.width > bounds.width { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Paired actions stay on one row only when each label has its natural width; otherwise they stack (Ui.actionRow).
struct ActionRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
        }
    }
}
