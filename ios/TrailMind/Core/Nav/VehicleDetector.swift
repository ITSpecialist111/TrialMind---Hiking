import Foundation

/// Notices that someone recording a hike has got into a vehicle, usually because they forgot to pause or stop at the
/// car park. Feed it every GPS fix, including the ones the breadcrumb filter rejects.
///
/// A fix is "fast" when its speed is above `fastMps`, which is beyond a sustained run, let alone a walk. Speed is the
/// receiver's own Doppler speed where it has one, else worked out from the previous fix. The verdict is
/// `Verdict.maybe` while a fast run is under way and `Verdict.vehicle` once it has lasted `sustainMs` and covered at
/// least `minDistanceM`: a few seconds of downhill running, a bike lent for a minute or a GPS glitch never gets that
/// far. Short dips below the threshold (a junction, a queue) don't end a run; a stop of more than `dipMs` does.
///
/// While the verdict is `Verdict.maybe` the caller should hold back the fixes it would record, then write them if the
/// run ends (`Verdict.onFoot`) or drop them on `Verdict.vehicle`, so the drive never reaches the saved track.
final class VehicleDetector {
    enum Verdict { case onFoot, maybe, vehicle }

    private struct Sample {
        let timeMs: Int64
        let lat: Double
        let lon: Double
    }

    private let fastMps: Double
    private let sustainMs: Int64
    private let minDistanceM: Double
    private let dipMs: Int64
    private let maxAccuracyM: Float
    private let maxGapMs: Int64

    private var prev: Sample?
    private var runStart: Sample?
    private var lastFastMs: Int64 = 0
    private var confirmed = false

    private static let minDeriveMs: Int64 = 500

    init(fastMps: Double = 6.0, sustainMs: Int64 = 30_000, minDistanceM: Double = 120.0, dipMs: Int64 = 10_000,
         maxAccuracyM: Float = 40, maxGapMs: Int64 = 30_000) {
        self.fastMps = fastMps
        self.sustainMs = sustainMs
        self.minDistanceM = minDistanceM
        self.dipMs = dipMs
        self.maxAccuracyM = maxAccuracyM
        self.maxGapMs = maxGapMs
    }

    /// When the current fast run began, on the clock of the fixes fed in, or nil when there isn't one.
    var runStartedMs: Int64? { runStart?.timeMs }

    func reset() {
        prev = nil
        runStart = nil
        confirmed = false
    }

    /// Takes one fix: `timeMs` on any steady clock (elapsed real time is ideal), its position, its `accuracyM` and
    /// `speedMps` if the receiver gave them.
    func onFix(_ timeMs: Int64, _ lat: Double, _ lon: Double, accuracyM: Float?, speedMps: Double?) -> Verdict {
        if confirmed { return .vehicle }
        if let accuracyM, accuracyM > maxAccuracyM { return current() }
        let before = prev
        prev = Sample(timeMs: timeMs, lat: lat, lon: lon)
        // With no fix for a while (a tunnel, GPS off) there is no telling what happened, so a run can't carry across.
        if let before, timeMs - before.timeMs > maxGapMs { runStart = nil }
        let reported = speedMps.flatMap { $0.isFinite && $0 >= 0.0 ? $0 : nil }
        guard let speed = reported ?? derivedSpeed(before, timeMs, lat, lon) else { return current() }

        if speed >= fastMps {
            lastFastMs = timeMs
            let start: Sample
            if let runStart {
                start = runStart
            } else {
                start = Sample(timeMs: timeMs, lat: lat, lon: lon)
                runStart = start
            }
            if timeMs - start.timeMs >= sustainMs && Geo.distanceM(start.lat, start.lon, lat, lon) >= minDistanceM {
                confirmed = true
                return .vehicle
            }
            return .maybe
        }
        if runStart != nil && timeMs - lastFastMs > dipMs { runStart = nil }
        return current()
    }

    private func current() -> Verdict { runStart != nil ? .maybe : .onFoot }

    private func derivedSpeed(_ before: Sample?, _ timeMs: Int64, _ lat: Double, _ lon: Double) -> Double? {
        guard let before else { return nil }
        let dt = timeMs - before.timeMs
        if dt < Self.minDeriveMs || dt > maxGapMs { return nil }
        return Geo.distanceM(before.lat, before.lon, lat, lon) / (Double(dt) / 1000.0)
    }
}
