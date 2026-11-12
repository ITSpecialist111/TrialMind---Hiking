import Foundation

enum MenuMotion {
    /// Kotlin's `require(width > 0f)` failing: a menu needs a positive width to drag across.
    struct InvalidWidth: Error {}

    static func shouldDrag(_ dx: Float, _ dy: Float, _ slop: Float, _ fraction: Float) -> Bool {
        abs(dx) > slop && abs(dx) > abs(dy) * 1.5 &&
            (fraction > 0 || dx > 0) && (fraction < 1 || dx < 0)
    }

    static func fraction(_ start: Float, _ distance: Float, _ width: Float) throws -> Float {
        guard width > 0 else { throw InvalidWidth() }
        return (start + distance / width).clamped(0, 1)
    }

    static func settleOpen(_ fraction: Float, _ velocity: Float, _ flingThreshold: Float) -> Bool {
        abs(velocity) >= flingThreshold ? velocity > 0 : fraction >= 0.5
    }
}
