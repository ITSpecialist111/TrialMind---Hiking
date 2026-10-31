import Foundation
import os

/// One line in the device log whenever what the display reports, or the layout the shell chose, changes
/// (read with `idevicesyslog -p TrailMind` or Console.app): for checking iPhone Duo poses on a device and for bug reports.
enum DuoLog {
    private static let logger = Logger(subsystem: "com.trailmind.ios", category: "display")
    private static var lastState = ""
    private static var lastLayout = ""

    static func state(_ s: DuoState) {
        let line = s.diagnostics.map { "\($0.0)=\($0.1)" }.joined(separator: " | ")
        guard line != lastState else { return }
        lastState = line
        logger.notice("display \(line, privacy: .public)")
    }

    static func layout(_ g: ShellGeometry) {
        func r(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))" }
        var line = "mode=\(g.mode) nav=\(g.nav) size=\(Int(g.size.width))x\(Int(g.size.height))"
        line += " safe=\(Int(g.safe.top)),\(Int(g.safe.leading)),\(Int(g.safe.bottom)),\(Int(g.safe.trailing))"
        line += " menuLeading=\(g.menuOnLeading) fullScreen=\(g.fullScreen) compactTabs=\(g.compactTabs)"
        line += " rail=\(r(g.railFrame)) pane=\(r(g.paneFrame)) capsule=\(r(g.capsuleFrame)) map=\(r(g.mapArea))"
        if let fold = g.fold { line += " fold=\(r(fold))" }
        guard line != lastLayout else { return }
        lastLayout = line
        logger.notice("layout \(line, privacy: .public)")
    }
}
