import SwiftUI

/// The Android type scale (ui/Ui.kt `Ui.T`), on Dynamic Type text styles so it scales with the user's text size.
enum TMType {
    case display, headline, title, body, label, caption, mono

    var font: Font {
        switch self {
        case .display: return .system(.largeTitle, weight: .medium)
        case .headline: return .system(.title2, weight: .medium)
        case .title: return .system(.body, weight: .medium)
        case .body: return .system(.subheadline)
        case .label: return .system(.caption, weight: .medium)
        case .caption: return .system(.footnote)
        case .mono: return .system(.subheadline, design: .monospaced)
        }
    }
}

extension View {
    /// Applies a TrailMind text style: font and, for captions and labels, the muted colour.
    func tm(_ type: TMType, _ p: Palette, color: Color? = nil) -> some View {
        modifier(TMTextStyle(type: type, palette: p, color: color))
    }
}

private struct TMTextStyle: ViewModifier {
    let type: TMType
    let palette: Palette
    let color: Color?

    func body(content: Content) -> some View {
        let fg = color ?? ((type == .caption || type == .label) ? palette.muted : palette.onSurface)
        switch type {
        case .label:
            content.font(type.font).textCase(.uppercase).tracking(0.7).foregroundStyle(fg)
        case .body:
            content.font(type.font).lineSpacing(2).foregroundStyle(fg)
        default:
            content.font(type.font).foregroundStyle(fg)
        }
    }
}

/// Text in a TrailMind style.
struct TMText: View {
    @Environment(\.palette) private var p
    let text: String
    var type: TMType = .body
    var color: Color? = nil

    init(_ text: String, _ type: TMType = .body, color: Color? = nil) {
        self.text = text; self.type = type; self.color = color
    }

    var body: some View {
        Text(text).tm(type, p, color: color).fixedSize(horizontal: false, vertical: true)
    }
}

/// Non-breaking spaces, so a value such as "2h 25m" or "↑800 m" never wraps in the middle.
func nb(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "\u{00A0}") }
