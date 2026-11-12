import Foundation

/// True-north heading selection; timestamps must all use the same monotonic clock.
enum MapHeading {
    enum Source { case course, compass, unavailable }

    struct Reading: Hashable {
        var degrees: Double
        var atMs: Int64
    }

    struct Course: Hashable {
        var reading: Reading
        var speedMps: Double
        var accuracyM: Double
        var bearingAccuracyDeg: Double?
        var speedAccuracyMps: Double?
    }

    struct Result: Hashable {
        var degrees: Double?
        var source: Source
    }

    static func choose(_ nowMs: Int64, _ compass: Reading?, _ compassReliable: Bool, _ course: Course?) -> Result {
        let moving = course.flatMap { it -> Course? in
            fresh(it.reading, nowMs, 5_000) &&
                it.accuracyM.isFinite && (0.0...25.0).contains(it.accuracyM) &&
                it.speedMps.isFinite && it.speedMps >= (it.bearingAccuracyDeg == nil ? 1.2 : 0.8) ? it : nil
        }.flatMap { it -> Course? in
            (it.bearingAccuracyDeg.map { $0.isFinite && (0.0...25.0).contains($0) } ?? true) &&
                (it.speedAccuracyMps.map { $0.isFinite && $0 >= 0 && it.speedMps - $0 >= 0.5 } ?? true) ? it : nil
        }
        if let moving = moving { return Result(degrees: Geo.normalizeDeg(moving.reading.degrees), source: .course) }
        if compassReliable, let compass = compass, fresh(compass, nowMs, 2_000) {
            return Result(degrees: Geo.normalizeDeg(compass.degrees), source: .compass)
        }
        return Result(degrees: nil, source: .unavailable)
    }

    private static func fresh(_ reading: Reading, _ now: Int64, _ age: Int64) -> Bool {
        reading.degrees.isFinite && (0...age).contains(now - reading.atMs)
    }
}

extension MapHeading.Reading {
    init(_ degrees: Double, _ atMs: Int64) { self.init(degrees: degrees, atMs: atMs) }
}

extension MapHeading.Course {
    init(_ reading: MapHeading.Reading, _ speedMps: Double, _ accuracyM: Double, _ bearingAccuracyDeg: Double?,
         _ speedAccuracyMps: Double?) {
        self.init(reading: reading, speedMps: speedMps, accuracyM: accuracyM, bearingAccuracyDeg: bearingAccuracyDeg,
                  speedAccuracyMps: speedAccuracyMps)
    }
}

extension MapHeading.Result {
    init(_ degrees: Double?, _ source: MapHeading.Source) { self.init(degrees: degrees, source: source) }
}
