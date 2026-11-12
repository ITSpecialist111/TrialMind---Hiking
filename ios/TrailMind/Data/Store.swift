import Foundation

struct RouteMeta: Identifiable, Hashable {
    var id: Int64
    var name: String
    var createdMs: Int64
    var distanceM: Double
    var ascentM: Double
    var descentM: Double
    var maxEleM: Double?
    var pointCount: Int
    var waypointCount: Int
    var terrainDerived: Bool = false
}

struct RouteData: Hashable {
    var meta: RouteMeta
    var points: [TrackPoint]
    var waypoints: [Waypoint]
}

enum HikeStatus: String { case recording = "RECORDING", paused = "PAUSED", done = "DONE" }

struct HikeMeta: Identifiable, Hashable {
    var id: Int64
    var name: String
    var startMs: Int64
    var endMs: Int64?
    var status: HikeStatus
    var distanceM: Double
    var ascentM: Double
    var descentM: Double
    var movingMs: Int64
    var durationMs: Int64
    var maxEleM: Double?
    var minEleM: Double?
    var routeId: Int64?
    var pointCount: Int
}

enum PackKind: String { case download = "DOWNLOAD", importFile = "IMPORT" }
enum PackStatus: String { case queued = "QUEUED", downloading = "DOWNLOADING", paused = "PAUSED", complete = "COMPLETE", partial = "PARTIAL", failed = "FAILED", ready = "READY" }

struct PackMeta: Identifiable, Hashable {
    var id: Int64
    var name: String
    var kind: PackKind
    /// For downloads: the online source it caches. For imports: "pack:<id>".
    var sourceId: String
    var fileName: String
    var minZoom: Int
    var maxZoom: Int
    var bounds: BoundingBox?
    var routeId: Int64?
    var bufferM: Double
    var tileTotal: Int64
    var tileDone: Int64
    var tileFailed: Int64
    var bytes: Int64
    var status: PackStatus
    var format: String
    var attribution: String
    var createdMs: Int64
    var message: String?
    /// Highest Premium zoom pre-loaded with the pack (0 = none). Those tiles live in the browse cache for 24 hours.
    var premiumMaxZoom: Int = 0
    /// When the Premium tiles were last fully loaded.
    var premiumMs: Int64 = 0
}

/// The trip group this phone is in. `secret` is the group code (kept in the Keychain-protected database file).
struct TripGroupRow: Hashable {
    var id: String
    var name: String
    var secret: Data
    var memberId: Int
    var displayName: String
    var colour: Int
    var createdMs: Int64
    var expiresMs: Int64
}

/// What this phone last knew about another member. `position` is the member's position frame.
struct GroupMemberRow: Hashable {
    var memberId: Int
    var name: String?
    var colour: Int?
    var position: Data?
    var positionMs: Int64
    var heardMs: Int64
    var directMs: Int64
    var rssi: Int?
    var coded: Bool
}

/// Where one hike's post to Strava has got to; at most one row per hike, so a retry can never post it twice.
struct StravaPostRow: Hashable {
    var hikeId: Int64
    /// A `StravaPostState` raw value (QUEUED, PROCESSING, POSTED, FAILED, ...).
    var state: String
    var uploadId: Int64?
    var activityId: Int64?
    var message: String?
    var attempts: Int
    var nextTryMs: Int64
    var updatedMs: Int64
}

/// A mesh heartbeat as stored (the core `HikerTelemetry` fields).
struct HeartbeatRow: Hashable {
    var hikerId: String
    var latitude: Double
    var longitude: Double
    var altitudeM: Int
    var batteryPercent: Int
    var timestampS: Int64
    var status: Int
    var triageCode: Int
}

/// Route, hike, pack, Strava and trip-group storage: the Android `Db` schema and queries on the system SQLite.
/// Every hike point is written the moment it is recorded, so a crash or a killed app loses nothing.
final class Store: ObservableObject {
    static let shared = Store()
    private let db: SQLiteDB
    /// Bumped on every write, so lists observing the store refresh.
    @Published private(set) var revision = 0

    init(path: String? = nil) {
        let file = path ?? Store.defaultPath()
        do {
            db = try SQLiteDB(path: file)
        } catch {
            // A database that cannot open is unrecoverable for storage, but the app must still show the map.
            db = try! SQLiteDB(path: ":memory:")
        }
        _ = try? db.exec("PRAGMA foreign_keys = ON")
        _ = try? db.exec("PRAGMA journal_mode = WAL")
        migrate()
    }

    static func defaultPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("trailmind.db")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url.path
    }

    private func changed() {
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    private func migrate() {
        guard db.userVersion < 6 else { return }
        _ = try? db.exec("""
            CREATE TABLE IF NOT EXISTS routes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_ms INTEGER NOT NULL,
               distance_m REAL NOT NULL, ascent_m REAL NOT NULL, descent_m REAL NOT NULL, max_ele REAL,
               point_count INTEGER NOT NULL, waypoint_count INTEGER NOT NULL, terrain_derived INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS route_points(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
               idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL, PRIMARY KEY(route_id, idx));
            CREATE TABLE IF NOT EXISTS route_waypoints(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
               idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL, name TEXT NOT NULL, descr TEXT,
               PRIMARY KEY(route_id, idx));
            CREATE TABLE IF NOT EXISTS hikes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, start_ms INTEGER NOT NULL,
               end_ms INTEGER, status TEXT NOT NULL, distance_m REAL NOT NULL DEFAULT 0, ascent_m REAL NOT NULL DEFAULT 0,
               descent_m REAL NOT NULL DEFAULT 0, moving_ms INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0,
               max_ele REAL, min_ele REAL, route_id INTEGER, point_count INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS hike_points(hike_id INTEGER NOT NULL REFERENCES hikes(id) ON DELETE CASCADE,
               seq INTEGER NOT NULL, segment INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL,
               time_ms INTEGER NOT NULL, accuracy REAL, PRIMARY KEY(hike_id, seq));
            CREATE TABLE IF NOT EXISTS packs(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
               source_id TEXT NOT NULL, file_name TEXT NOT NULL, min_zoom INTEGER NOT NULL, max_zoom INTEGER NOT NULL,
               min_lat REAL, min_lon REAL, max_lat REAL, max_lon REAL, route_id INTEGER, buffer_m REAL NOT NULL DEFAULT 0,
               tile_total INTEGER NOT NULL DEFAULT 0, tile_done INTEGER NOT NULL DEFAULT 0, tile_failed INTEGER NOT NULL DEFAULT 0,
               bytes INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, format TEXT NOT NULL DEFAULT 'png',
               attribution TEXT NOT NULL DEFAULT '', created_ms INTEGER NOT NULL, message TEXT,
               premium_max_zoom INTEGER NOT NULL DEFAULT 0, premium_ms INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS mesh_heartbeats(
               hiker_id TEXT PRIMARY KEY NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
               altitude_m INTEGER NOT NULL, battery_percent INTEGER NOT NULL, timestamp_s INTEGER NOT NULL,
               status INTEGER NOT NULL, triage_code INTEGER NOT NULL, received_ms INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS mesh_heartbeats_received_idx ON mesh_heartbeats(received_ms);
            CREATE TABLE IF NOT EXISTS trip_groups(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, secret BLOB NOT NULL,
               member_id INTEGER NOT NULL, display_name TEXT NOT NULL, colour INTEGER NOT NULL, created_ms INTEGER NOT NULL,
               expires_ms INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS group_members(group_id TEXT NOT NULL REFERENCES trip_groups(id) ON DELETE CASCADE,
               member_id INTEGER NOT NULL, name TEXT, colour INTEGER, position BLOB, position_ms INTEGER NOT NULL DEFAULT 0,
               heard_ms INTEGER NOT NULL DEFAULT 0, direct_ms INTEGER NOT NULL DEFAULT 0, rssi INTEGER,
               coded INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(group_id, member_id));
            CREATE TABLE IF NOT EXISTS strava_posts(hike_id INTEGER PRIMARY KEY NOT NULL REFERENCES hikes(id) ON DELETE CASCADE,
               state TEXT NOT NULL, upload_id INTEGER, activity_id INTEGER, message TEXT, attempts INTEGER NOT NULL DEFAULT 0,
               next_try_ms INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER NOT NULL);
            """)
        db.userVersion = 6
    }

    // MARK: Routes

    @discardableResult
    func insertRoute(name: String, points: [TrackPoint], waypoints: [Waypoint]) -> Int64? {
        let s = TrackStats.summarize(points)
        let id: Int64? = try? db.transaction {
            try db.run("""
                INSERT INTO routes(name, created_ms, distance_m, ascent_m, descent_m, max_ele, point_count, waypoint_count)
                VALUES (?,?,?,?,?,?,?,?)
                """, [.text(name), .int(nowMs()), .double(s.distanceM), .double(s.ascentM), .double(s.descentM),
                      s.maxEleM.map { .double($0) } ?? .null, .int(Int64(points.count)), .int(Int64(waypoints.count))])
            let id = db.lastInsertId
            let ps = try db.prepare("INSERT INTO route_points(route_id, idx, lat, lon, ele) VALUES (?,?,?,?,?)")
            for (i, p) in points.enumerated() {
                ps.bind([.int(id), .int(Int64(i)), .double(p.lat), .double(p.lon), p.ele.map { .double($0) } ?? .null])
                _ = ps.step()
            }
            let ws = try db.prepare("INSERT INTO route_waypoints(route_id, idx, lat, lon, ele, name, descr) VALUES (?,?,?,?,?,?,?)")
            for (i, w) in waypoints.enumerated() {
                ws.bind([.int(id), .int(Int64(i)), .double(w.lat), .double(w.lon), w.ele.map { .double($0) } ?? .null,
                         .text(w.name), w.description.map { .text($0) } ?? .null])
                _ = ws.step()
            }
            return id
        }
        changed()
        return id
    }

    private func routeMeta(_ s: SQLiteDB.Statement) -> RouteMeta {
        RouteMeta(id: s.int(s.column("id")), name: s.text(s.column("name")), createdMs: s.int(s.column("created_ms")),
                  distanceM: s.double(s.column("distance_m")), ascentM: s.double(s.column("ascent_m")),
                  descentM: s.double(s.column("descent_m")), maxEleM: s.optDouble(s.column("max_ele")),
                  pointCount: Int(s.int(s.column("point_count"))), waypointCount: Int(s.int(s.column("waypoint_count"))),
                  terrainDerived: s.int(s.column("terrain_derived")) != 0)
    }

    func routes() -> [RouteMeta] { (try? db.query("SELECT * FROM routes ORDER BY created_ms DESC", [], routeMeta)) ?? [] }

    func route(_ id: Int64) -> RouteMeta? { (try? db.query("SELECT * FROM routes WHERE id=?", [.int(id)], routeMeta))?.first }

    func routeData(_ id: Int64) -> RouteData? {
        guard let meta = route(id) else { return nil }
        let pts = (try? db.query("SELECT lat, lon, ele FROM route_points WHERE route_id=? ORDER BY idx", [.int(id)]) {
            TrackPoint(lat: $0.double(0), lon: $0.double(1), ele: $0.optDouble(2))
        }) ?? []
        let wps = (try? db.query("SELECT lat, lon, ele, name, descr FROM route_waypoints WHERE route_id=? ORDER BY idx", [.int(id)]) {
            Waypoint(lat: $0.double(0), lon: $0.double(1), name: $0.text(3), ele: $0.optDouble(2), description: $0.optText(4))
        }) ?? []
        return RouteData(meta: meta, points: pts, waypoints: wps)
    }

    func renameRoute(_ id: Int64, _ name: String) {
        _ = try? db.run("UPDATE routes SET name=? WHERE id=?", [.text(name), .int(id)])
        changed()
    }

    /// Fills only missing route elevations and refreshes the stored terrain statistics.
    @discardableResult
    func updateRouteHeights(_ id: Int64, sampled: [TrackPoint]) -> Bool {
        let ok: Bool = (try? db.transaction { () -> Bool in
            let existing = try db.query("SELECT lat, lon, ele FROM route_points WHERE route_id=? ORDER BY idx", [.int(id)]) {
                TrackPoint(lat: $0.double(0), lon: $0.double(1), ele: $0.optDouble(2))
            }
            if existing.isEmpty || existing.count != sampled.count { return false }
            var merged = existing
            for i in merged.indices where merged[i].ele == nil { merged[i].ele = sampled[i].ele }
            if !merged.indices.contains(where: { existing[$0].ele == nil && merged[$0].ele != nil }) { return false }
            let up = try db.prepare("UPDATE route_points SET ele=? WHERE route_id=? AND idx=? AND ele IS NULL")
            for (i, p) in merged.enumerated() {
                guard let e = p.ele else { continue }
                up.bind([.double(e), .int(id), .int(Int64(i))])
                _ = up.step()
            }
            let summary = TrackStats.summarize(merged)
            try db.run("UPDATE routes SET distance_m=?, ascent_m=?, descent_m=?, max_ele=?, terrain_derived=1 WHERE id=?",
                       [.double(summary.distanceM), .double(summary.ascentM), .double(summary.descentM),
                        summary.maxEleM.map { .double($0) } ?? .null, .int(id)])
            return true
        }) ?? false
        if ok { changed() }
        return ok
    }

    func deleteRoute(_ id: Int64) { deleteRoutes([id]) }

    @discardableResult
    func deleteRoutes(_ ids: Set<Int64>) -> Int {
        let count = (try? db.transaction { () -> Int in
            var count = 0
            for id in ids {
                count += try db.run("DELETE FROM routes WHERE id=?", [.int(id)])
                try db.run("UPDATE hikes SET route_id=NULL WHERE route_id=?", [.int(id)])
            }
            return count
        }) ?? 0
        changed()
        return count
    }

    // MARK: Hikes

    func createHike(name: String, startMs: Int64, routeId: Int64?) -> Int64 {
        _ = try? db.run("INSERT INTO hikes(name, start_ms, status, route_id) VALUES (?,?,?,?)",
                    [.text(name), .int(startMs), .text(HikeStatus.recording.rawValue), routeId.map { .int($0) } ?? .null])
        changed()
        return db.lastInsertId
    }

    func appendHikePoint(_ hikeId: Int64, seq: Int, segment: Int, _ p: TrackPoint) {
        _ = try? db.run("INSERT INTO hike_points(hike_id, seq, segment, lat, lon, ele, time_ms, accuracy) VALUES (?,?,?,?,?,?,?,?)",
                    [.int(hikeId), .int(Int64(seq)), .int(Int64(segment)), .double(p.lat), .double(p.lon),
                     p.ele.map { .double($0) } ?? .null, .int(p.timeMs ?? nowMs()), p.accuracyM.map { .double(Double($0)) } ?? .null])
    }

    /// Periodic checkpoint so an interrupted recording keeps sensible stats.
    func updateHikeLive(_ id: Int64, activeMs: Int64, distanceM: Double, ascentM: Double, descentM: Double, points: Int) {
        _ = try? db.run("UPDATE hikes SET duration_ms=?, distance_m=?, ascent_m=?, descent_m=?, point_count=? WHERE id=?",
                    [.int(activeMs), .double(distanceM), .double(ascentM), .double(descentM), .int(Int64(points)), .int(id)])
        changed()
    }

    func setHikeStatus(_ id: Int64, _ status: HikeStatus) {
        _ = try? db.run("UPDATE hikes SET status=? WHERE id=?", [.text(status.rawValue), .int(id)])
        changed()
    }

    /// Recomputes and stores the summary from the stored points.
    @discardableResult
    func finalizeHike(_ id: Int64, endMs: Int64, activeDurationMs: Int64?) -> HikeMeta? {
        let segs = hikeSegments(id)
        let perSeg = segs.map { TrackStats.summarize($0) }
        let distance = perSeg.reduce(0) { $0 + $1.distanceM }
        let ascent = perSeg.reduce(0) { $0 + $1.ascentM }
        let descent = perSeg.reduce(0) { $0 + $1.descentM }
        let minEle = perSeg.compactMap { $0.minEleM }.min()
        let maxEle = perSeg.compactMap { $0.maxEleM }.max()
        let duration = perSeg.reduce(Int64(0)) { $0 + $1.durationMs }
        let moving = perSeg.reduce(Int64(0)) { $0 + $1.movingMs }
        let count = segs.reduce(0) { $0 + $1.count }
        _ = try? db.run("""
            UPDATE hikes SET end_ms=?, status=?, distance_m=?, ascent_m=?, descent_m=?, moving_ms=?, duration_ms=?,
              max_ele=COALESCE(?, max_ele), min_ele=COALESCE(?, min_ele), point_count=? WHERE id=?
            """, [.int(endMs), .text(HikeStatus.done.rawValue), .double(distance), .double(ascent), .double(descent),
                  .int(moving), .int(activeDurationMs ?? duration), maxEle.map { .double($0) } ?? .null,
                  minEle.map { .double($0) } ?? .null, .int(Int64(count)), .int(id)])
        changed()
        return hike(id)
    }

    private func hikeMeta(_ s: SQLiteDB.Statement) -> HikeMeta {
        HikeMeta(id: s.int(s.column("id")), name: s.text(s.column("name")), startMs: s.int(s.column("start_ms")),
                 endMs: s.optInt(s.column("end_ms")), status: HikeStatus(rawValue: s.text(s.column("status"))) ?? .done,
                 distanceM: s.double(s.column("distance_m")), ascentM: s.double(s.column("ascent_m")),
                 descentM: s.double(s.column("descent_m")), movingMs: s.int(s.column("moving_ms")),
                 durationMs: s.int(s.column("duration_ms")), maxEleM: s.optDouble(s.column("max_ele")),
                 minEleM: s.optDouble(s.column("min_ele")), routeId: s.optInt(s.column("route_id")),
                 pointCount: Int(s.int(s.column("point_count"))))
    }

    func hikes() -> [HikeMeta] { (try? db.query("SELECT * FROM hikes ORDER BY start_ms DESC", [], hikeMeta)) ?? [] }

    func hike(_ id: Int64) -> HikeMeta? { (try? db.query("SELECT * FROM hikes WHERE id=?", [.int(id)], hikeMeta))?.first }

    func unfinishedHike() -> HikeMeta? {
        (try? db.query("SELECT * FROM hikes WHERE status != ? ORDER BY start_ms DESC LIMIT 1", [.text(HikeStatus.done.rawValue)], hikeMeta))?.first
    }

    func hikeSegments(_ id: Int64) -> [[TrackPoint]] {
        var out: [[TrackPoint]] = []
        var lastSeg = Int.min
        _ = try? db.query("SELECT segment, lat, lon, ele, time_ms, accuracy FROM hike_points WHERE hike_id=? ORDER BY seq", [.int(id)]) { s in
            let seg = Int(s.int(0))
            if seg != lastSeg { out.append([]); lastSeg = seg }
            out[out.count - 1].append(TrackPoint(lat: s.double(1), lon: s.double(2), ele: s.optDouble(3), timeMs: s.int(4),
                                                 accuracyM: s.optDouble(5).map { Float($0) }))
        }
        return out
    }

    /// The last stored point's sequence number and segment, to resume an interrupted recording.
    func lastHikePointInfo(_ id: Int64) -> (seq: Int, segment: Int)? {
        (try? db.query("SELECT seq, segment FROM hike_points WHERE hike_id=? ORDER BY seq DESC LIMIT 1", [.int(id)]) {
            (seq: Int($0.int(0)), segment: Int($0.int(1)))
        })?.first
    }

    func renameHike(_ id: Int64, _ name: String) {
        _ = try? db.run("UPDATE hikes SET name=? WHERE id=?", [.text(name), .int(id)])
        changed()
    }

    func deleteHike(_ id: Int64) {
        _ = try? db.run("DELETE FROM hikes WHERE id=?", [.int(id)])
        changed()
    }

    @discardableResult
    func deleteFinishedHikes(_ ids: Set<Int64>) -> Int {
        let count = (try? db.transaction { () -> Int in
            var count = 0
            for id in ids { count += try db.run("DELETE FROM hikes WHERE id=? AND status=?", [.int(id), .text(HikeStatus.done.rawValue)]) }
            return count
        }) ?? 0
        changed()
        return count
    }

    // MARK: Strava posts

    private func stravaRow(_ s: SQLiteDB.Statement) -> StravaPostRow {
        StravaPostRow(hikeId: s.int(s.column("hike_id")), state: s.text(s.column("state")),
                      uploadId: s.optInt(s.column("upload_id")), activityId: s.optInt(s.column("activity_id")),
                      message: s.optText(s.column("message")), attempts: Int(s.int(s.column("attempts"))),
                      nextTryMs: s.int(s.column("next_try_ms")), updatedMs: s.int(s.column("updated_ms")))
    }

    func stravaPost(_ hikeId: Int64) -> StravaPostRow? {
        (try? db.query("SELECT * FROM strava_posts WHERE hike_id=?", [.int(hikeId)], stravaRow))?.first
    }

    func saveStravaPost(_ row: StravaPostRow) {
        _ = try? db.run("""
            INSERT OR REPLACE INTO strava_posts(hike_id, state, upload_id, activity_id, message, attempts, next_try_ms, updated_ms)
            VALUES (?,?,?,?,?,?,?,?)
            """, [.int(row.hikeId), .text(row.state), row.uploadId.map { .int($0) } ?? .null, row.activityId.map { .int($0) } ?? .null,
                  row.message.map { .text($0) } ?? .null, .int(Int64(row.attempts)), .int(row.nextTryMs), .int(row.updatedMs)])
        changed()
    }

    /// Posts waiting to be sent, or to be checked on, whose time has come.
    func stravaDue(_ now: Int64) -> [StravaPostRow] {
        (try? db.query("SELECT * FROM strava_posts WHERE state IN ('QUEUED','PROCESSING') AND next_try_ms <= ? ORDER BY updated_ms",
                       [.int(now)], stravaRow)) ?? []
    }

    /// When the next waiting post is due, or nil if none is waiting.
    func stravaNextTry() -> Int64? {
        (try? db.query("SELECT MIN(next_try_ms) FROM strava_posts WHERE state IN ('QUEUED','PROCESSING')") { $0.optInt(0) })?.first ?? nil
    }

    func stravaWaitingCount() -> Int {
        (try? db.query("SELECT COUNT(*) FROM strava_posts WHERE state IN ('QUEUED','PROCESSING')") { Int($0.int(0)) })?.first ?? 0
    }

    /// Posts still waiting belong to the account that was just disconnected.
    func dropWaitingStravaPosts() {
        _ = try? db.run("DELETE FROM strava_posts WHERE state IN ('QUEUED','PROCESSING')")
        changed()
    }

    // MARK: Frontier mesh heartbeats

    func upsertMeshHeartbeat(_ h: HeartbeatRow, receivedMs: Int64 = nowMs()) {
        _ = try? db.run("""
            INSERT OR REPLACE INTO mesh_heartbeats(hiker_id, latitude, longitude, altitude_m, battery_percent, timestamp_s, status,
              triage_code, received_ms) VALUES (?,?,?,?,?,?,?,?,?)
            """, [.text(h.hikerId), .double(h.latitude), .double(h.longitude), .int(Int64(h.altitudeM)), .int(Int64(h.batteryPercent)),
                  .int(h.timestampS), .int(Int64(h.status)), .int(Int64(h.triageCode)), .int(receivedMs)])
        changed()
    }

    func meshHeartbeats(receivedAfterMs: Int64 = 0) -> [HeartbeatRow] {
        (try? db.query("""
            SELECT hiker_id, latitude, longitude, altitude_m, battery_percent, timestamp_s, status, triage_code
            FROM mesh_heartbeats WHERE received_ms >= ? ORDER BY status DESC, timestamp_s DESC LIMIT 8
            """, [.int(receivedAfterMs)]) {
            HeartbeatRow(hikerId: $0.text(0), latitude: $0.double(1), longitude: $0.double(2), altitudeM: Int($0.int(3)),
                         batteryPercent: Int($0.int(4)), timestampS: $0.int(5), status: Int($0.int(6)), triageCode: Int($0.int(7)))
        }) ?? []
    }

    func pruneMeshHeartbeats(receivedBeforeMs: Int64) {
        _ = try? db.run("DELETE FROM mesh_heartbeats WHERE received_ms < ?", [.int(receivedBeforeMs)])
    }

    // MARK: Trip groups

    /// The phone's trip group; there is at most one.
    func tripGroup() -> TripGroupRow? {
        (try? db.query("SELECT * FROM trip_groups ORDER BY created_ms DESC LIMIT 1") { s in
            TripGroupRow(id: s.text(s.column("id")), name: s.text(s.column("name")), secret: s.blob(s.column("secret")) ?? Data(),
                         memberId: Int(s.int(s.column("member_id"))), displayName: s.text(s.column("display_name")),
                         colour: Int(s.int(s.column("colour"))), createdMs: s.int(s.column("created_ms")),
                         expiresMs: s.int(s.column("expires_ms")))
        })?.first
    }

    /// Replaces any previous group, and everything known about its members.
    func saveTripGroup(_ g: TripGroupRow) {
        _ = try? db.transaction {
            try db.run("DELETE FROM trip_groups WHERE id != ?", [.text(g.id)])
            let values: [SQLiteDB.Value] = [.text(g.name), .blob(g.secret), .int(Int64(g.memberId)), .text(g.displayName),
                                            .int(Int64(g.colour)), .int(g.createdMs), .int(g.expiresMs), .text(g.id)]
            // Update in place: REPLACE deletes the row first, and the cascade would take the group's members with it.
            if try db.run("UPDATE trip_groups SET name=?, secret=?, member_id=?, display_name=?, colour=?, created_ms=?, expires_ms=? WHERE id=?", values) == 0 {
                try db.run("INSERT INTO trip_groups(name, secret, member_id, display_name, colour, created_ms, expires_ms, id) VALUES (?,?,?,?,?,?,?,?)", values)
            }
        }
        changed()
    }

    func deleteTripGroups() {
        _ = try? db.run("DELETE FROM trip_groups")
        changed()
    }

    func groupMembers(_ groupId: String) -> [GroupMemberRow] {
        (try? db.query("SELECT * FROM group_members WHERE group_id = ?", [.text(groupId)]) { s in
            GroupMemberRow(memberId: Int(s.int(s.column("member_id"))), name: s.optText(s.column("name")),
                           colour: s.optInt(s.column("colour")).map { Int($0) }, position: s.blob(s.column("position")),
                           positionMs: s.int(s.column("position_ms")), heardMs: s.int(s.column("heard_ms")),
                           directMs: s.int(s.column("direct_ms")), rssi: s.optInt(s.column("rssi")).map { Int($0) },
                           coded: s.int(s.column("coded")) != 0)
        }) ?? []
    }

    func upsertGroupMember(_ groupId: String, _ m: GroupMemberRow) {
        _ = try? db.run("""
            INSERT OR REPLACE INTO group_members(group_id, member_id, name, colour, position, position_ms, heard_ms, direct_ms, rssi, coded)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(groupId), .int(Int64(m.memberId)), m.name.map { .text($0) } ?? .null, m.colour.map { .int(Int64($0)) } ?? .null,
                  m.position.map { .blob($0) } ?? .null, .int(m.positionMs), .int(m.heardMs), .int(m.directMs),
                  m.rssi.map { .int(Int64($0)) } ?? .null, .int(m.coded ? 1 : 0)])
        changed()
    }

    // MARK: Offline packs

    @discardableResult
    func insertPack(name: String, kind: PackKind, sourceId: String, fileName: String, minZoom: Int, maxZoom: Int,
                    bounds: BoundingBox?, routeId: Int64?, bufferM: Double, tileTotal: Int64, status: PackStatus,
                    format: String, attribution: String, premiumMaxZoom: Int = 0) -> Int64 {
        _ = try? db.run("""
            INSERT INTO packs(name, kind, source_id, file_name, min_zoom, max_zoom, premium_max_zoom, min_lat, min_lon, max_lat, max_lon,
              route_id, buffer_m, tile_total, status, format, attribution, created_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(name), .text(kind.rawValue), .text(sourceId), .text(fileName), .int(Int64(minZoom)), .int(Int64(maxZoom)),
                  .int(Int64(premiumMaxZoom)), bounds.map { .double($0.minLat) } ?? .null, bounds.map { .double($0.minLon) } ?? .null,
                  bounds.map { .double($0.maxLat) } ?? .null, bounds.map { .double($0.maxLon) } ?? .null,
                  routeId.map { .int($0) } ?? .null, .double(bufferM), .int(tileTotal), .text(status.rawValue), .text(format),
                  .text(attribution), .int(nowMs())])
        changed()
        return db.lastInsertId
    }

    /// Updates named pack columns, e.g. `updatePack(id, ["file_name": .text(x)])`.
    func updatePack(_ id: Int64, _ values: [String: SQLiteDB.Value]) {
        guard !values.isEmpty else { return }
        let keys = Array(values.keys)
        _ = try? db.run("UPDATE packs SET " + keys.map { "\($0)=?" }.joined(separator: ", ") + " WHERE id=?", keys.map { values[$0]! } + [.int(id)])
        changed()
    }

    func updatePackProgress(_ id: Int64, done: Int64, failed: Int64, bytes: Int64, status: PackStatus, message: String? = nil) {
        updatePack(id, ["tile_done": .int(done), "tile_failed": .int(failed), "bytes": .int(bytes), "status": .text(status.rawValue),
                        "message": message.map { .text($0) } ?? .null])
    }

    private func packMeta(_ s: SQLiteDB.Statement) -> PackMeta {
        let minLat = s.optDouble(s.column("min_lat"))
        let bounds = minLat.map { BoundingBox($0, s.double(s.column("min_lon")), s.double(s.column("max_lat")), s.double(s.column("max_lon"))) }
        return PackMeta(id: s.int(s.column("id")), name: s.text(s.column("name")),
                        kind: PackKind(rawValue: s.text(s.column("kind"))) ?? .download, sourceId: s.text(s.column("source_id")),
                        fileName: s.text(s.column("file_name")), minZoom: Int(s.int(s.column("min_zoom"))),
                        maxZoom: Int(s.int(s.column("max_zoom"))), bounds: bounds, routeId: s.optInt(s.column("route_id")),
                        bufferM: s.double(s.column("buffer_m")), tileTotal: s.int(s.column("tile_total")),
                        tileDone: s.int(s.column("tile_done")), tileFailed: s.int(s.column("tile_failed")),
                        bytes: s.int(s.column("bytes")), status: PackStatus(rawValue: s.text(s.column("status"))) ?? .failed,
                        format: s.text(s.column("format")), attribution: s.text(s.column("attribution")),
                        createdMs: s.int(s.column("created_ms")), message: s.optText(s.column("message")),
                        premiumMaxZoom: Int(s.int(s.column("premium_max_zoom"))), premiumMs: s.int(s.column("premium_ms")))
    }

    func packs() -> [PackMeta] { (try? db.query("SELECT * FROM packs ORDER BY created_ms DESC", [], packMeta)) ?? [] }

    func pack(_ id: Int64) -> PackMeta? { (try? db.query("SELECT * FROM packs WHERE id=?", [.int(id)], packMeta))?.first }

    func deletePack(_ id: Int64) {
        _ = try? db.run("DELETE FROM packs WHERE id=?", [.int(id)])
        changed()
    }
}
