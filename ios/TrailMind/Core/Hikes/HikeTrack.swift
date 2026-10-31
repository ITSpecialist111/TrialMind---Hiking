import Foundation

/// In-memory view of the hike being recorded (TrackingState): its points, the line drawn on the map, the running
/// distance, ascent and descent, and the active time, which stops while the hike is paused. Mutated on one thread only.
final class HikeTrack {
    enum Status { case idle, recording, paused }

    private(set) var status = Status.idle
    private(set) var hikeId: Int64? = nil
    private(set) var hikeName = ""
    private(set) var startMs: Int64 = 0
    private var activeAccumMs: Int64 = 0
    private var activeSinceMs: Int64? = nil

    /// The drawn line (MercatorLine with its breaks): a new part starts after each pause, so the line isn't joined
    /// across a gap in the recording.
    private(set) var line: [[LatLon]] = []
    private(set) var points: [TrackPoint] = []
    private(set) var distanceM = 0.0
    private(set) var ascentM = 0.0
    private(set) var descentM = 0.0
    private var eleRef: Double? = nil
    private var needBreak = false

    func activeMs(_ now: Int64) -> Int64 {
        activeAccumMs + (activeSinceMs.map { now - $0 } ?? 0)
    }

    /// Starts showing a recording: a new hike, or an interrupted one with its `restored` segments and active time.
    func begin(id: Int64, name: String, start: Int64, restored: [[TrackPoint]], restoredActiveMs: Int64, nowMs: Int64) {
        hikeId = id
        hikeName = name
        startMs = start
        points.removeAll()
        line.removeAll()
        distanceM = 0.0
        ascentM = 0.0
        descentM = 0.0
        eleRef = nil
        for seg in restored {
            needBreak = true
            seg.forEach { addInternal($0) }
        }
        needBreak = !restored.isEmpty
        activeAccumMs = restoredActiveMs
        activeSinceMs = nowMs
        status = .recording
    }

    /// Adds a recorded point; ignored unless recording.
    @discardableResult
    func add(_ p: TrackPoint) -> Bool {
        if status != .recording { return false }
        addInternal(p)
        return true
    }

    private func addInternal(_ p: TrackPoint) {
        let last = points.last
        if needBreak {
            breakLine()
            needBreak = false
            eleRef = nil
        } else if let last {
            distanceM += Geo.distanceM(last.lat, last.lon, p.lat, p.lon)
        }
        if let e = p.ele {
            if let ref = eleRef {
                let d = e - ref
                if d >= TrackStats.defaultElevationThresholdM {
                    ascentM += d
                    eleRef = e
                } else if -d >= TrackStats.defaultElevationThresholdM {
                    descentM += -d
                    eleRef = e
                }
            } else {
                eleRef = e
            }
        }
        points.append(p)
        if line.isEmpty { line.append([]) }
        line[line.count - 1].append(p.latLon())
    }

    /// MercatorLine.breakHere: a line with no points has nothing to break.
    private func breakLine() {
        if let last = line.last, !last.isEmpty { line.append([]) }
    }

    /// Stops the active clock. `rewindMs` is time already counted as hiking that turned out to be a drive.
    func pause(rewindMs: Int64 = 0, nowMs: Int64) {
        if status != .recording { return }
        if let since = activeSinceMs { activeAccumMs += max(nowMs - since - rewindMs, 0) }
        activeSinceMs = nil
        status = .paused
    }

    func resume(nowMs: Int64) {
        if status != .paused { return }
        activeSinceMs = nowMs
        needBreak = true
        status = .recording
    }

    func end() {
        status = .idle
        hikeId = nil
        activeSinceMs = nil
        activeAccumMs = 0
        points.removeAll()
        line.removeAll()
        distanceM = 0.0
        ascentM = 0.0
        descentM = 0.0
    }
}
