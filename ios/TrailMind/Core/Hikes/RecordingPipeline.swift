import Foundation

/// What the recorder does with each GPS fix while a hike records (TrackingService.onLocationChanged). The breadcrumb
/// filter decides which fixes are kept. Fixes taken while the phone moves faster than anyone walks are held back until
/// it is clear whether that was a brief burst (they are kept) or a drive (they are dropped and the hike pauses itself,
/// see `VehicleDetector`), so the drive never reaches the saved track.
final class RecordingPipeline {
    enum Outcome: Equatable {
        /// Points to save now, oldest first: fixes held back during a burst that has ended, then this one if accepted.
        case store([TrackPoint])
        /// The phone is in a vehicle: pause the hike, taking `rewindMs` of driving back off the hiking time.
        case autoPause(rewindMs: Int64)
    }

    private let filter: TrackFilter
    private let vehicle: VehicleDetector
    private(set) var held: [TrackPoint] = []

    init(filter: TrackFilter = TrackFilter(), vehicle: VehicleDetector = VehicleDetector()) {
        self.filter = filter
        self.vehicle = vehicle
    }

    /// A new, recovered or resumed recording: the breadcrumb starts afresh and any fast run is forgotten.
    func reset() {
        filter.reset()
        resetVehicleWatch()
    }

    func resetVehicleWatch() {
        vehicle.reset()
        held.removeAll()
    }

    /// The fixes held back during a fast stretch that turned out not to be a drive, to save now (on pause or finish).
    func flushHeld() -> [TrackPoint] {
        let out = held
        held.removeAll()
        return out
    }

    /// Takes one fix as the point it would record. `steadyMs` is the fix time on a steady clock; `accuracyM` and
    /// `speedMps` are the receiver's, nil when it gave none.
    func onFix(_ p: TrackPoint, steadyMs: Int64, accuracyM: Float?, speedMps: Double?, autoPauseInVehicle: Bool) -> Outcome {
        let verdict: VehicleDetector.Verdict
        if autoPauseInVehicle {
            verdict = vehicle.onFix(steadyMs, p.lat, p.lon, accuracyM: accuracyM, speedMps: speedMps)
        } else {
            resetVehicleWatch()
            verdict = .onFoot
        }
        switch verdict {
        case .vehicle:
            let rewind = vehicle.runStartedMs.map { steadyMs - $0 } ?? 0
            held.removeAll()
            vehicle.reset()
            return .autoPause(rewindMs: max(rewind, 0))
        case .maybe:
            if filter.accept(p) { held.append(p) }
            return .store([])
        case .onFoot:
            var out = flushHeld()
            if filter.accept(p) { out.append(p) }
            return .store(out)
        }
    }
}
