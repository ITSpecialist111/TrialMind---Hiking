import Combine
import CoreMotion
import Foundation

/// The compass's view of the magnetic field (sensor/Compass.kt): the declination where you are, from the World Magnetic
/// Model as Android's GeomagneticField gives it, and MagneticCheck's interference test. The test compares the strength
/// and dip of the field the phone measures (Core Motion's calibrated magnetometer, with gravity for "down") with the
/// model's, so steel, magnets and electronics show up even while iOS reports the compass as calibrated. It runs only
/// while a page that shows it is open.
final class CompassMonitor: ObservableObject {
    static let shared = CompassMonitor()

    /// Degrees east of true north where you are; 0 until the first fix.
    @Published private(set) var declinationDeg = 0.0
    /// The magnetometer sees more than the Earth's field.
    @Published private(set) var disturbed = false

    private let manager = SafetyMotion.manager
    private let check = MagneticCheck()
    private var users = 0
    private var listener: UUID?
    private var modelAt: (position: LatLon, timeMs: Int64)?

    /// The device has a magnetometer, so there is a compass at all.
    var available: Bool { manager.isMagnetometerAvailable }

    func acquire() {
        users += 1
        guard users == 1 else { return }
        check.reset()
        disturbed = false
        if let fix = LocationHub.shared.latest { updateModel(fix) }
        listener = LocationHub.shared.addListener { [weak self] fix in self?.updateModel(fix) }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        guard manager.isDeviceMotionAvailable, frames.contains(.xMagneticNorthZVertical) else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let field = motion.magneticField
            guard field.accuracy != .uncalibrated else { return }
            let g = motion.gravity
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            guard norm > 0.1 else { return }
            // Up is against gravity, in the phone's axes (Android's rotation matrix row for the vertical).
            self.check.add(field.field.x, field.field.y, field.field.z, -g.x / norm, -g.y / norm, -g.z / norm)
            if self.check.disturbed != self.disturbed { self.disturbed = self.check.disturbed }
        }
    }

    func release() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        manager.stopDeviceMotionUpdates()
        if let id = listener { LocationHub.shared.removeListener(id) }
        listener = nil
        check.reset()
        disturbed = false
    }

    /// The model's field where you are (Compass.updateLocation); worked out again after moving a kilometre or an hour on.
    func updateModel(_ fix: Fix) {
        if let at = modelAt, Geo.distanceM(at.position, fix.latLon) < 1_000, abs(fix.timeMs - at.timeMs) < 3_600_000 { return }
        modelAt = (fix.latLon, fix.timeMs)
        let field = WorldMagneticModel.field(fix.latLon, altitudeM: fix.altitudeM ?? 0, timeMs: fix.timeMs)
        declinationDeg = field.declinationDeg
        check.expect(field.totalNt / 1000, field.inclinationDeg)
    }
}
