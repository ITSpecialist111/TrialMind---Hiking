import SwiftUI

extension ShellGeometry {
    /// Resolves the shell from SwiftUI's geometry and the Duo probe's vertical-bar trait.
    static func resolve(size: CGSize, safe: EdgeInsets, fold: CGRect?, verticalBarEdge: HorizontalEdge?,
                        occlusions: [CGRect], fullScreen: Bool) -> ShellGeometry {
        resolve(size: size, safe: Insets(safe), fold: fold,
                verticalBarEdge: verticalBarEdge.map { $0 == .leading ? BarEdge.leading : BarEdge.trailing },
                occlusions: occlusions, fullScreen: fullScreen, compactTabCount: Tab.compactTabs.count)
    }
}

extension ShellGeometry.Insets {
    init(_ e: EdgeInsets) { self.init(top: e.top, leading: e.leading, bottom: e.bottom, trailing: e.trailing) }
    var edgeInsets: EdgeInsets { EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing) }
}
