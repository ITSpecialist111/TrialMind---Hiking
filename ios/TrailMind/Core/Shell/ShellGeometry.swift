import Foundation

/// Where everything goes for the current window, pose and setting. The Android rules (MainActivity.buildLayout) decide
/// narrow versus wide; iPhone Duo adds the fold (book and tabletop) and vertical bars on the side.
/// Pure geometry (Foundation only) so the layout rules are tested on Linux; `Duo/ShellGeometry+SwiftUI.swift` adapts it.
struct ShellGeometry: Equatable {
    enum Mode: Equatable { case compact, wide, foldBook, foldTable }
    enum NavPlacement: Equatable { case bottom, leading, trailing }
    /// The side where the system stands bars vertically (iPhone Duo's `verticalBarEdge` trait).
    enum BarEdge: Equatable { case leading, trailing }

    struct Insets: Equatable {
        var top: CGFloat = 0
        var leading: CGFloat = 0
        var bottom: CGFloat = 0
        var trailing: CGFloat = 0
    }

    static let wideMinWidth: CGFloat = 600     // MainActivity.WIDE_DP
    static let railWidth: CGFloat = 76         // MainActivity.RAIL_DP
    static let capsuleThickness: CGFloat = 60  // 48 pt buttons + 6 pt padding each side
    static let gap: CGFloat = 10

    var mode: Mode
    var size: CGSize
    var safe: Insets
    var fold: CGRect?
    var nav: NavPlacement
    /// Rail and pane side in the wide and book layouts.
    var menuOnLeading: Bool
    var fullScreen: Bool
    /// Narrow windows and short wide ones (the cover screen in landscape) only fit five destinations.
    var compactTabs: Bool
    var railFrame: CGRect = .zero
    var paneFrame: CGRect = .zero
    var capsuleFrame: CGRect = .zero
    /// The uncovered part of the map, in window coordinates: overlays and centring use this.
    var mapArea: CGRect = .zero

    static func resolve(size: CGSize, safe: Insets, fold: CGRect?, verticalBarEdge: BarEdge?,
                        occlusions: [CGRect], fullScreen: Bool, compactTabCount: Int) -> ShellGeometry {
        let wide = size.width >= wideMinWidth
        var g = ShellGeometry(mode: .compact, size: size, safe: safe, fold: nil, nav: .bottom, menuOnLeading: verticalBarEdge != .trailing,
                              fullScreen: false, compactTabs: !wide || size.height < 600)
        let usable = CGRect(x: safe.leading, y: safe.top, width: size.width - safe.leading - safe.trailing,
                            height: size.height - safe.top - safe.bottom)

        if let fold, fold.width > 0 || fold.height > 0, ShellGeometry.foldFits(fold, size) {
            g.fold = fold
            if fold.height >= fold.width {
                // Book pose: the menu fills one side of the fold, the map the other.
                g.mode = .foldBook
                g.compactTabs = size.height < 600
                g.fullScreen = fullScreen
                let leadingHalf = CGRect(x: 0, y: 0, width: fold.minX, height: size.height)
                let trailingHalf = CGRect(x: fold.maxX, y: 0, width: size.width - fold.maxX, height: size.height)
                let menuHalf = g.menuOnLeading ? leadingHalf : trailingHalf
                let mapHalf = g.menuOnLeading ? trailingHalf : leadingHalf
                let railX = g.menuOnLeading ? max(safe.leading, menuHalf.minX) : menuHalf.maxX - safe.trailing - railWidth
                g.railFrame = CGRect(x: railX, y: 0, width: railWidth, height: size.height)
                let paneMinX = g.menuOnLeading ? g.railFrame.maxX : menuHalf.minX + 8
                let paneMaxX = g.menuOnLeading ? menuHalf.maxX - 8 : g.railFrame.minX
                g.paneFrame = CGRect(x: paneMinX, y: safe.top + 8, width: max(0, paneMaxX - paneMinX), height: size.height - safe.top - safe.bottom - 16)
                g.mapArea = fullScreen ? usable : mapHalf.intersection(usable)
                return g
            } else {
                // Tabletop: the map stands on the upper half, pages and navigation lie on the lower half.
                g.mode = .foldTable
                g.compactTabs = true
                g.nav = .bottom
                let lower = CGRect(x: 0, y: fold.maxY, width: size.width, height: size.height - fold.maxY)
                let capsuleW = min(lower.width - 32, 360)
                g.capsuleFrame = CGRect(x: (size.width - capsuleW) / 2, y: size.height - safe.bottom - gap - capsuleThickness,
                                        width: capsuleW, height: capsuleThickness)
                g.paneFrame = CGRect(x: safe.leading, y: lower.minY + 4, width: size.width - safe.leading - safe.trailing,
                                     height: max(0, g.capsuleFrame.minY - lower.minY - 8))
                g.mapArea = CGRect(x: 0, y: 0, width: size.width, height: fold.minY).intersection(usable)
                return g
            }
        }

        if wide {
            g.mode = .wide
            g.fullScreen = fullScreen
            let paneWidth = (size.width * 0.29).clamped(260, 340)
            if g.menuOnLeading {
                g.railFrame = CGRect(x: safe.leading, y: 0, width: railWidth, height: size.height)
                g.paneFrame = CGRect(x: g.railFrame.maxX, y: safe.top + 8, width: paneWidth, height: size.height - safe.top - safe.bottom - 16)
            } else {
                g.railFrame = CGRect(x: size.width - safe.trailing - railWidth, y: 0, width: railWidth, height: size.height)
                g.paneFrame = CGRect(x: g.railFrame.minX - paneWidth, y: safe.top + 8, width: paneWidth, height: size.height - safe.top - safe.bottom - 16)
            }
            if fullScreen {
                g.mapArea = usable
            } else if g.menuOnLeading {
                g.mapArea = CGRect(x: g.paneFrame.maxX + 8, y: usable.minY, width: usable.maxX - g.paneFrame.maxX - 8, height: usable.height)
            } else {
                g.mapArea = CGRect(x: usable.minX, y: usable.minY, width: g.paneFrame.minX - 8 - usable.minX, height: usable.height)
            }
            return g
        }

        // Narrow: a floating capsule, at the bottom or (iPhone Duo's outer display) standing on the vertical-bar edge.
        if let edge = verticalBarEdge {
            g.nav = edge == .leading ? .leading : .trailing
            let count = CGFloat(compactTabCount)
            let capsuleH = min(usable.height - 16, 48 * count + 12)
            var y = usable.midY - capsuleH / 2
            let x = edge == .leading ? usable.minX + 6 : usable.maxX - 6 - capsuleThickness
            var frame = CGRect(x: x, y: y, width: capsuleThickness, height: capsuleH)
            // Keep clear of the camera that always sits in a corner of the outer display.
            for o in occlusions where o.intersects(frame.insetBy(dx: -4, dy: -4)) {
                if o.midY < usable.midY { y = max(y, o.maxY + 8) } else { y = min(y, o.minY - 8 - capsuleH) }
                frame.origin.y = y
            }
            g.capsuleFrame = frame
            g.mapArea = edge == .leading
                ? CGRect(x: frame.maxX + gap, y: usable.minY, width: usable.maxX - frame.maxX - gap, height: usable.height)
                : CGRect(x: usable.minX, y: usable.minY, width: frame.minX - gap - usable.minX, height: usable.height)
        } else {
            let capsuleW = min(usable.width - 16, 400)
            g.capsuleFrame = CGRect(x: (size.width - capsuleW) / 2, y: size.height - safe.bottom - gap - capsuleThickness,
                                    width: capsuleW, height: capsuleThickness)
            g.mapArea = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: g.capsuleFrame.minY - gap - usable.minY)
        }
        return g
    }

    /// What pages must keep clear of so their content scrolls under the floating capsule.
    var pageInsets: Insets {
        switch (mode, nav) {
        case (.compact, .bottom): return Insets(bottom: ShellGeometry.capsuleThickness + ShellGeometry.gap + 4)
        case (.compact, .leading): return Insets(leading: ShellGeometry.capsuleThickness + ShellGeometry.gap)
        case (.compact, .trailing): return Insets(trailing: ShellGeometry.capsuleThickness + ShellGeometry.gap)
        default: return Insets()
        }
    }

    var usesCapsule: Bool { mode == .compact || mode == .foldTable }
    var usesRail: Bool { mode == .wide || mode == .foldBook }

    /// A fold crosses the whole window: top to bottom (book) or side to side (tabletop). While the phone turns, iOS can
    /// briefly report the fold for the old orientation; that one doesn't fit the new window and is ignored.
    static func foldFits(_ fold: CGRect, _ size: CGSize) -> Bool {
        let tolerance: CGFloat = 2
        if fold.height >= fold.width {
            return abs(fold.minY) <= tolerance && abs(fold.height - size.height) <= tolerance && fold.maxX <= size.width + tolerance
        }
        return abs(fold.minX) <= tolerance && abs(fold.width - size.width) <= tolerance && fold.maxY <= size.height + tolerance
    }

    /// How far the rail and pane slide to hide for the full-screen map: wholly past the window edge on their side,
    /// whatever sits between them and that edge (iPhone Duo's vertical status bar, a notch).
    var menuHideOffset: CGFloat {
        let left = min(railFrame.minX, paneFrame.minX), right = max(railFrame.maxX, paneFrame.maxX)
        return menuOnLeading ? -(right + 24) : size.width - left + 24
    }
}
