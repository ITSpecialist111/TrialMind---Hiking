import Foundation

final class RouteStart {
    private var initialAlong: Double?
    private(set) var started = false

    @discardableResult
    func update(_ fix: RouteFix, recording: Bool) -> Bool {
        if started || fix.offRouteM > 40.0 { return started }
        if recording { started = true }
        if let initial = initialAlong {
            if fix.alongM >= 40.0 && fix.alongM - initial >= 40.0 { started = true }
        } else {
            initialAlong = fix.alongM
        }
        return started
    }
}
