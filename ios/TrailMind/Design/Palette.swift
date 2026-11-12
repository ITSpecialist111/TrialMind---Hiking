import SwiftUI

extension Color {
    /// An Android-style 0xAARRGGBB colour, so the palette below matches the Android app value for value.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

/// The Android app's colour palette (ui/Ui.kt `Palette`), resolved for day or night.
struct Palette {
    let night: Bool

    var bg: Color { Color(argb: night ? 0xFF0C110F : 0xFFEFF3EE) }
    var surface: Color { Color(argb: night ? 0xFF161D19 : 0xFFFFFFFF) }
    var surfaceVariant: Color { Color(argb: night ? 0xFF222C27 : 0xFFE3EAE4) }
    var onSurface: Color { Color(argb: night ? 0xFFE6ECE8 : 0xFF17201B) }
    var muted: Color { Color(argb: night ? 0xFFA3B1A9 : 0xFF5B6A61) }
    var primary: Color { Color(argb: night ? 0xFF7FD1AE : 0xFF1F5B45) }
    var onPrimary: Color { Color(argb: night ? 0xFF06281B : 0xFFFFFFFF) }
    var primaryContainer: Color { Color(argb: night ? 0xFF1E4A38 : 0xFFCDEBDC) }
    var onPrimaryContainer: Color { Color(argb: night ? 0xFFCDEBDC : 0xFF0B3325) }
    var accent: Color { Color(argb: night ? 0xFFFFB066 : 0xFFE07A12) }
    var danger: Color { Color(argb: night ? 0xFFFF8A80 : 0xFFC62828) }
    var dangerContainer: Color { Color(argb: night ? 0xFF5C1B17 : 0xFFFDE2DF) }
    var warnContainer: Color { Color(argb: night ? 0xFF4A3A12 : 0xFFFFF1CC) }
    var outline: Color { Color(argb: night ? 0xFF3A463F : 0xFFD3DBD5) }
    var route: Color { Color(argb: 0xFF8E24AA) }
    var track: Color { Color(argb: 0xFFF06E14) }

    // Translucent surfaces do not reduce the opacity of text or safety controls.
    var glass: Color { Color(argb: night ? 0xEC161D19 : 0xECFFFFFF) }
    var glassStroke: Color { Color(argb: night ? 0x33FFFFFF : 0x16000000) }
    var inverse: Color { Color(argb: night ? 0xF8222C27 : 0xF816211B) }
    var onInverse: Color { Color(argb: 0xFFEAF2EC) }
    var inverseMuted: Color { Color(argb: 0xFFA3B5AA) }
    var navSelected: Color { Color(argb: night ? 0xFF7FD1AE : 0xFFBDF0D4) }
    var onNavSelected: Color { Color(argb: 0xFF0B2E21) }

    /// UIKit colours for MapKit overlays, which cannot take SwiftUI colours.
    var routeUI: UIColor { UIColor(route) }
    var trackUI: UIColor { UIColor(track) }

    static let day = Palette(night: false)
    static let night = Palette(night: true)
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.day
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Resolves the palette from the system appearance once, at the root, for every view below.
struct PaletteProvider<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.palette, scheme == .dark ? .night : .day)
    }
}
