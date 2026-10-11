package com.trailmind.app.data

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.TrackPoint
import com.trailmind.core.geo.Waypoint
import com.trailmind.core.frontier.EmergencyStatus
import com.trailmind.core.frontier.HikerTelemetry
import com.trailmind.core.stats.TrackStats
import com.trailmind.core.stats.TrackSummary
import com.trailmind.core.strava.StravaPostState

data class RouteMeta(
    val id: Long,
    val name: String,
    val createdMs: Long,
    val distanceM: Double,
    val ascentM: Double,
    val descentM: Double,
    val maxEleM: Double?,
    val pointCount: Int,
    val waypointCount: Int,
    val terrainDerived: Boolean = false,
)

data class RouteData(val meta: RouteMeta, val points: List<TrackPoint>, val waypoints: List<Waypoint>)

enum class HikeStatus { RECORDING, PAUSED, DONE }

data class HikeMeta(
    val id: Long,
    val name: String,
    val startMs: Long,
    val endMs: Long?,
    val status: HikeStatus,
    val distanceM: Double,
    val ascentM: Double,
    val descentM: Double,
    val movingMs: Long,
    val durationMs: Long,
    val maxEleM: Double?,
    val minEleM: Double?,
    val routeId: Long?,
    val pointCount: Int,
)

enum class PackKind { DOWNLOAD, IMPORT }
enum class PackStatus { QUEUED, DOWNLOADING, PAUSED, COMPLETE, PARTIAL, FAILED, READY }

data class PackMeta(
    val id: Long,
    val name: String,
    val kind: PackKind,
    /** For downloads: the online source it caches. For imports: "pack:<id>". */
    val sourceId: String,
    val fileName: String,
    val minZoom: Int,
    val maxZoom: Int,
    val bounds: BoundingBox?,
    val routeId: Long?,
    val bufferM: Double,
    val tileTotal: Long,
    val tileDone: Long,
    val tileFailed: Long,
    val bytes: Long,
    val status: PackStatus,
    val format: String,
    val attribution: String,
    val createdMs: Long,
    val message: String?,
    /** Highest Premium zoom pre-loaded with the pack (0 = none). Those tiles live in the browse cache for 24 hours. */
    val premiumMaxZoom: Int = 0,
    /** When the Premium tiles were last fully loaded. */
    val premiumMs: Long = 0,
)

/** The trip group this phone is in. [secret] is the group code, wrapped by the Android keystore. */
class TripGroupRow(
    val id: String,
    val name: String,
    val secret: ByteArray,
    val memberId: Int,
    val displayName: String,
    val colour: Int,
    val createdMs: Long,
    val expiresMs: Long,
)

/** What this phone last knew about another member. [position] is the member's 30-byte position frame. */
class GroupMemberRow(
    val memberId: Int,
    val name: String?,
    val colour: Int?,
    val position: ByteArray?,
    val positionMs: Long,
    val heardMs: Long,
    val directMs: Long,
    val rssi: Int?,
    val coded: Boolean,
)

/** Where one hike's post to Strava has got to. There is at most one row per hike, so a retry can never post it twice. */
data class StravaPostRow(
    val hikeId: Long,
    val state: StravaPostState,
    /** Strava's id for the upload while it is processing it. */
    val uploadId: Long?,
    /** The activity on Strava, once it exists. */
    val activityId: Long?,
    /** Why it failed, or a note such as "Already on Strava". */
    val message: String?,
    val attempts: Int,
    val nextTryMs: Long,
    val updatedMs: Long,
)

class Db(context: Context) : SQLiteOpenHelper(context, "trailmind.db", null, 6) {

    override fun onConfigure(db: SQLiteDatabase) {
        db.setForeignKeyConstraintsEnabled(true)
        db.enableWriteAheadLogging()
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE routes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, created_ms INTEGER NOT NULL,
               distance_m REAL NOT NULL, ascent_m REAL NOT NULL, descent_m REAL NOT NULL, max_ele REAL,
               point_count INTEGER NOT NULL, waypoint_count INTEGER NOT NULL, terrain_derived INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL(
            """CREATE TABLE route_points(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
               idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL, PRIMARY KEY(route_id, idx))""",
        )
        db.execSQL(
            """CREATE TABLE route_waypoints(route_id INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
               idx INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL, name TEXT NOT NULL, descr TEXT,
               PRIMARY KEY(route_id, idx))""",
        )
        db.execSQL(
            """CREATE TABLE hikes(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, start_ms INTEGER NOT NULL,
               end_ms INTEGER, status TEXT NOT NULL, distance_m REAL NOT NULL DEFAULT 0, ascent_m REAL NOT NULL DEFAULT 0,
               descent_m REAL NOT NULL DEFAULT 0, moving_ms INTEGER NOT NULL DEFAULT 0, duration_ms INTEGER NOT NULL DEFAULT 0,
               max_ele REAL, min_ele REAL, route_id INTEGER, point_count INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL(
            """CREATE TABLE hike_points(hike_id INTEGER NOT NULL REFERENCES hikes(id) ON DELETE CASCADE,
               seq INTEGER NOT NULL, segment INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, ele REAL,
               time_ms INTEGER NOT NULL, accuracy REAL, PRIMARY KEY(hike_id, seq))""",
        )
        db.execSQL(
            """CREATE TABLE packs(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
               source_id TEXT NOT NULL, file_name TEXT NOT NULL, min_zoom INTEGER NOT NULL, max_zoom INTEGER NOT NULL,
               min_lat REAL, min_lon REAL, max_lat REAL, max_lon REAL, route_id INTEGER, buffer_m REAL NOT NULL DEFAULT 0,
               tile_total INTEGER NOT NULL DEFAULT 0, tile_done INTEGER NOT NULL DEFAULT 0, tile_failed INTEGER NOT NULL DEFAULT 0,
               bytes INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, format TEXT NOT NULL DEFAULT 'png',
               attribution TEXT NOT NULL DEFAULT '', created_ms INTEGER NOT NULL, message TEXT,
               premium_max_zoom INTEGER NOT NULL DEFAULT 0, premium_ms INTEGER NOT NULL DEFAULT 0)""",
        )
        createMeshHeartbeats(db)
        createTripGroups(db)
        createStravaPosts(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE packs ADD COLUMN premium_max_zoom INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE packs ADD COLUMN premium_ms INTEGER NOT NULL DEFAULT 0")
        }
        // Test builds shipped two different version 3 schemas (terrain or Frontier), so version 4 adds whichever is missing.
        if (oldVersion < 4) ensureVersion4(db)
        if (oldVersion < 5) createTripGroups(db)
        if (oldVersion < 6) createStravaPosts(db)
    }

    // Newer test builds only add tables, which this build ignores, so keep the user's data instead of crashing.
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        ensureVersion4(db)
        createTripGroups(db)
        createStravaPosts(db)
    }

    private fun createStravaPosts(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS strava_posts(hike_id INTEGER PRIMARY KEY NOT NULL REFERENCES hikes(id) ON DELETE CASCADE,
               state TEXT NOT NULL, upload_id INTEGER, activity_id INTEGER, message TEXT, attempts INTEGER NOT NULL DEFAULT 0,
               next_try_ms INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER NOT NULL)""",
        )
    }

    private fun ensureVersion4(db: SQLiteDatabase) {
        val hasTerrainColumn = db.compileStatement(
            "SELECT COUNT(*) FROM pragma_table_info('routes') WHERE name = 'terrain_derived'",
        ).use { it.simpleQueryForLong() } > 0
        if (!hasTerrainColumn) db.execSQL("ALTER TABLE routes ADD COLUMN terrain_derived INTEGER NOT NULL DEFAULT 0")
        createMeshHeartbeats(db)
    }

    private fun createTripGroups(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS trip_groups(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, secret BLOB NOT NULL,
               member_id INTEGER NOT NULL, display_name TEXT NOT NULL, colour INTEGER NOT NULL, created_ms INTEGER NOT NULL,
               expires_ms INTEGER NOT NULL)""",
        )
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS group_members(group_id TEXT NOT NULL REFERENCES trip_groups(id) ON DELETE CASCADE,
               member_id INTEGER NOT NULL, name TEXT, colour INTEGER, position BLOB, position_ms INTEGER NOT NULL DEFAULT 0,
               heard_ms INTEGER NOT NULL DEFAULT 0, direct_ms INTEGER NOT NULL DEFAULT 0, rssi INTEGER,
               coded INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(group_id, member_id))""",
        )
    }

    private fun createMeshHeartbeats(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS mesh_heartbeats(
               hiker_id TEXT PRIMARY KEY NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL,
               altitude_m INTEGER NOT NULL, battery_percent INTEGER NOT NULL, timestamp_s INTEGER NOT NULL,
               status INTEGER NOT NULL, triage_code INTEGER NOT NULL, received_ms INTEGER NOT NULL)""",
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS mesh_heartbeats_received_idx ON mesh_heartbeats(received_ms)")
    }

    // ---------------------------------------------------------------- routes

    fun insertRoute(name: String, points: List<TrackPoint>, waypoints: List<Waypoint>): Long {
        val s = TrackStats.summarize(points)
        val db = writableDatabase
        db.beginTransaction()
        try {
            val id = db.insertOrThrow("routes", null, ContentValues().apply {
                put("name", name)
                put("created_ms", System.currentTimeMillis())
                put("distance_m", s.distanceM)
                put("ascent_m", s.ascentM)
                put("descent_m", s.descentM)
                s.maxEleM?.let { put("max_ele", it) }
                put("point_count", points.size)
                put("waypoint_count", waypoints.size)
            })
            val ps = db.compileStatement("INSERT INTO route_points(route_id, idx, lat, lon, ele) VALUES (?,?,?,?,?)")
            points.forEachIndexed { i, p ->
                ps.clearBindings()
                ps.bindLong(1, id); ps.bindLong(2, i.toLong()); ps.bindDouble(3, p.lat); ps.bindDouble(4, p.lon)
                p.ele?.let { ps.bindDouble(5, it) } ?: ps.bindNull(5)
                ps.executeInsert()
            }
            val ws = db.compileStatement("INSERT INTO route_waypoints(route_id, idx, lat, lon, ele, name, descr) VALUES (?,?,?,?,?,?,?)")
            waypoints.forEachIndexed { i, w ->
                ws.clearBindings()
                ws.bindLong(1, id); ws.bindLong(2, i.toLong()); ws.bindDouble(3, w.lat); ws.bindDouble(4, w.lon)
                w.ele?.let { ws.bindDouble(5, it) } ?: ws.bindNull(5)
                ws.bindString(6, w.name)
                w.description?.let { ws.bindString(7, it) } ?: ws.bindNull(7)
                ws.executeInsert()
            }
            db.setTransactionSuccessful()
            return id
        } finally {
            db.endTransaction()
        }
    }

    fun routes(): List<RouteMeta> = readableDatabase.rawQuery("SELECT * FROM routes ORDER BY created_ms DESC", null).use { c ->
        c.map { routeMeta(it) }
    }

    fun route(id: Long): RouteMeta? =
        readableDatabase.rawQuery("SELECT * FROM routes WHERE id=?", arrayOf(id.toString())).use { c ->
            if (c.moveToFirst()) routeMeta(c) else null
        }

    fun routeData(id: Long): RouteData? {
        val meta = route(id) ?: return null
        val pts = readableDatabase.rawQuery(
            "SELECT lat, lon, ele FROM route_points WHERE route_id=? ORDER BY idx", arrayOf(id.toString()),
        ).use { c -> c.map { TrackPoint(it.getDouble(0), it.getDouble(1), it.optDouble(2)) } }
        val wps = readableDatabase.rawQuery(
            "SELECT lat, lon, ele, name, descr FROM route_waypoints WHERE route_id=? ORDER BY idx", arrayOf(id.toString()),
        ).use { c -> c.map { Waypoint(it.getDouble(0), it.getDouble(1), it.getString(3), it.optDouble(2), it.optString(4)) } }
        return RouteData(meta, pts, wps)
    }

    fun renameRoute(id: Long, name: String) {
        writableDatabase.update("routes", ContentValues().apply { put("name", name) }, "id=?", arrayOf(id.toString()))
    }

    /** Fills only missing route elevations and refreshes the stored terrain statistics. */
    fun updateRouteHeights(id: Long, sampled: List<TrackPoint>): Boolean {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val existing = db.rawQuery(
                "SELECT lat, lon, ele FROM route_points WHERE route_id=? ORDER BY idx", arrayOf(id.toString()),
            ).use { c -> c.map { TrackPoint(it.getDouble(0), it.getDouble(1), it.optDouble(2)) } }
            if (existing.isEmpty() || existing.size != sampled.size) return false
            val merged = existing.mapIndexed { index, point ->
                if (point.ele != null) point else point.copy(ele = sampled[index].ele)
            }
            if (merged.indices.none { existing[it].ele == null && merged[it].ele != null }) return false
            db.compileStatement("UPDATE route_points SET ele=? WHERE route_id=? AND idx=? AND ele IS NULL").use { statement ->
                merged.forEachIndexed { index, point ->
                    val elevation = point.ele ?: return@forEachIndexed
                    statement.clearBindings()
                    statement.bindDouble(1, elevation); statement.bindLong(2, id); statement.bindLong(3, index.toLong())
                    statement.executeUpdateDelete()
                }
            }
            val summary = TrackStats.summarize(merged)
            db.update("routes", ContentValues().apply {
                put("distance_m", summary.distanceM)
                put("ascent_m", summary.ascentM)
                put("descent_m", summary.descentM)
                summary.maxEleM?.let { put("max_ele", it) } ?: putNull("max_ele")
                put("terrain_derived", 1)
            }, "id=?", arrayOf(id.toString()))
            db.setTransactionSuccessful()
            return true
        } finally {
            db.endTransaction()
        }
    }

    fun deleteRoute(id: Long) {
        writableDatabase.delete("routes", "id=?", arrayOf(id.toString()))
    }

    private fun routeMeta(c: Cursor) = RouteMeta(
        id = c.long("id"), name = c.str("name"), createdMs = c.long("created_ms"),
        distanceM = c.dbl("distance_m"), ascentM = c.dbl("ascent_m"), descentM = c.dbl("descent_m"),
        maxEleM = c.optDouble(c.getColumnIndexOrThrow("max_ele")), pointCount = c.int("point_count"),
        waypointCount = c.int("waypoint_count"), terrainDerived = c.getInt(c.getColumnIndexOrThrow("terrain_derived")) != 0,
    )

    // ---------------------------------------------------------------- hikes

    fun createHike(name: String, startMs: Long, routeId: Long?): Long =
        writableDatabase.insertOrThrow("hikes", null, ContentValues().apply {
            put("name", name)
            put("start_ms", startMs)
            put("status", HikeStatus.RECORDING.name)
            routeId?.let { put("route_id", it) }
        })

    fun appendHikePoint(hikeId: Long, seq: Int, segment: Int, p: TrackPoint) {
        writableDatabase.insertOrThrow("hike_points", null, ContentValues().apply {
            put("hike_id", hikeId); put("seq", seq); put("segment", segment)
            put("lat", p.lat); put("lon", p.lon)
            p.ele?.let { put("ele", it) }
            put("time_ms", p.timeMs ?: System.currentTimeMillis())
            p.accuracyM?.let { put("accuracy", it.toDouble()) }
        })
    }

    /** Periodic checkpoint so an interrupted recording keeps sensible stats. */
    fun updateHikeLive(id: Long, activeMs: Long, distanceM: Double, ascentM: Double, descentM: Double, points: Int) {
        writableDatabase.update("hikes", ContentValues().apply {
            put("duration_ms", activeMs); put("distance_m", distanceM); put("ascent_m", ascentM)
            put("descent_m", descentM); put("point_count", points)
        }, "id=?", arrayOf(id.toString()))
    }

    fun setHikeStatus(id: Long, status: HikeStatus) {
        writableDatabase.update("hikes", ContentValues().apply { put("status", status.name) }, "id=?", arrayOf(id.toString()))
    }

    /** Recomputes and stores the summary from the stored points (segment-aware). */
    fun finalizeHike(id: Long, endMs: Long, activeDurationMs: Long?): HikeMeta? {
        val segs = hikeSegments(id)
        val all = segs.flatten()
        val perSeg = segs.map { TrackStats.summarize(it) }
        val summary = TrackSummary(
            distanceM = perSeg.sumOf { it.distanceM },
            ascentM = perSeg.sumOf { it.ascentM },
            descentM = perSeg.sumOf { it.descentM },
            minEleM = perSeg.mapNotNull { it.minEleM }.minOrNull(),
            maxEleM = perSeg.mapNotNull { it.maxEleM }.maxOrNull(),
            durationMs = perSeg.sumOf { it.durationMs },
            movingMs = perSeg.sumOf { it.movingMs },
            pointCount = all.size,
        )
        writableDatabase.update("hikes", ContentValues().apply {
            put("end_ms", endMs)
            put("status", HikeStatus.DONE.name)
            put("distance_m", summary.distanceM)
            put("ascent_m", summary.ascentM)
            put("descent_m", summary.descentM)
            put("moving_ms", summary.movingMs)
            put("duration_ms", activeDurationMs ?: summary.durationMs)
            summary.maxEleM?.let { put("max_ele", it) }
            summary.minEleM?.let { put("min_ele", it) }
            put("point_count", all.size)
        }, "id=?", arrayOf(id.toString()))
        return hike(id)
    }

    fun hikes(): List<HikeMeta> =
        readableDatabase.rawQuery("SELECT * FROM hikes ORDER BY start_ms DESC", null).use { c -> c.map { hikeMeta(it) } }

    fun hike(id: Long): HikeMeta? =
        readableDatabase.rawQuery("SELECT * FROM hikes WHERE id=?", arrayOf(id.toString())).use { c ->
            if (c.moveToFirst()) hikeMeta(c) else null
        }

    fun unfinishedHike(): HikeMeta? =
        readableDatabase.rawQuery("SELECT * FROM hikes WHERE status != ? ORDER BY start_ms DESC LIMIT 1", arrayOf(HikeStatus.DONE.name))
            .use { c -> if (c.moveToFirst()) hikeMeta(c) else null }

    fun hikeSegments(id: Long): List<List<TrackPoint>> {
        val out = ArrayList<ArrayList<TrackPoint>>()
        var lastSeg = Int.MIN_VALUE
        readableDatabase.rawQuery(
            "SELECT segment, lat, lon, ele, time_ms, accuracy FROM hike_points WHERE hike_id=? ORDER BY seq",
            arrayOf(id.toString()),
        ).use { c ->
            while (c.moveToNext()) {
                val seg = c.getInt(0)
                if (seg != lastSeg) { out.add(ArrayList()); lastSeg = seg }
                out.last().add(TrackPoint(c.getDouble(1), c.getDouble(2), c.optDouble(3), c.getLong(4), c.optDouble(5)?.toFloat()))
            }
        }
        return out
    }

    fun lastHikePointInfo(id: Long): Pair<Int, Int>? =
        readableDatabase.rawQuery("SELECT seq, segment FROM hike_points WHERE hike_id=? ORDER BY seq DESC LIMIT 1", arrayOf(id.toString()))
            .use { c -> if (c.moveToFirst()) c.getInt(0) to c.getInt(1) else null }

    fun renameHike(id: Long, name: String) {
        writableDatabase.update("hikes", ContentValues().apply { put("name", name) }, "id=?", arrayOf(id.toString()))
    }

    fun deleteHike(id: Long) {
        writableDatabase.delete("hikes", "id=?", arrayOf(id.toString()))
    }

    private fun hikeMeta(c: Cursor) = HikeMeta(
        id = c.long("id"), name = c.str("name"), startMs = c.long("start_ms"),
        endMs = c.optLong(c.getColumnIndexOrThrow("end_ms")),
        status = runCatching { HikeStatus.valueOf(c.str("status")) }.getOrDefault(HikeStatus.DONE),
        distanceM = c.dbl("distance_m"), ascentM = c.dbl("ascent_m"), descentM = c.dbl("descent_m"),
        movingMs = c.long("moving_ms"), durationMs = c.long("duration_ms"),
        maxEleM = c.optDouble(c.getColumnIndexOrThrow("max_ele")), minEleM = c.optDouble(c.getColumnIndexOrThrow("min_ele")),
        routeId = c.optLong(c.getColumnIndexOrThrow("route_id")), pointCount = c.int("point_count"),
    )

    // ---------------------------------------------------------------- Strava posts

    fun stravaPost(hikeId: Long): StravaPostRow? =
        readableDatabase.rawQuery("SELECT * FROM strava_posts WHERE hike_id=?", arrayOf(hikeId.toString())).use { c ->
            if (c.moveToFirst()) stravaRow(c) else null
        }

    fun saveStravaPost(row: StravaPostRow) {
        writableDatabase.insertWithOnConflict("strava_posts", null, ContentValues().apply {
            put("hike_id", row.hikeId); put("state", row.state.name)
            row.uploadId?.let { put("upload_id", it) } ?: putNull("upload_id")
            row.activityId?.let { put("activity_id", it) } ?: putNull("activity_id")
            row.message?.let { put("message", it) } ?: putNull("message")
            put("attempts", row.attempts); put("next_try_ms", row.nextTryMs); put("updated_ms", row.updatedMs)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    /** Posts waiting to be sent, or to be checked on, whose time has come. */
    fun stravaDue(nowMs: Long): List<StravaPostRow> =
        readableDatabase.rawQuery(
            "SELECT * FROM strava_posts WHERE state IN (?, ?) AND next_try_ms <= ? ORDER BY updated_ms",
            arrayOf(StravaPostState.QUEUED.name, StravaPostState.PROCESSING.name, nowMs.toString()),
        ).use { c -> c.map { stravaRow(it) } }

    /** When the next waiting post is due, or null if none is waiting. */
    fun stravaNextTry(): Long? =
        readableDatabase.rawQuery(
            "SELECT MIN(next_try_ms) FROM strava_posts WHERE state IN (?, ?)",
            arrayOf(StravaPostState.QUEUED.name, StravaPostState.PROCESSING.name),
        ).use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null }

    fun stravaWaitingCount(): Int =
        readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM strava_posts WHERE state IN (?, ?)",
            arrayOf(StravaPostState.QUEUED.name, StravaPostState.PROCESSING.name),
        ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    /** Posts still waiting belong to the account that was just disconnected; those hikes can be posted again after linking. */
    fun dropWaitingStravaPosts() {
        writableDatabase.delete("strava_posts", "state IN (?, ?)", arrayOf(StravaPostState.QUEUED.name, StravaPostState.PROCESSING.name))
    }

    private fun stravaRow(c: Cursor) = StravaPostRow(
        hikeId = c.long("hike_id"),
        state = runCatching { StravaPostState.valueOf(c.str("state")) }.getOrDefault(StravaPostState.FAILED),
        uploadId = c.optLong(c.getColumnIndexOrThrow("upload_id")),
        activityId = c.optLong(c.getColumnIndexOrThrow("activity_id")),
        message = c.optString(c.getColumnIndexOrThrow("message")),
        attempts = c.int("attempts"), nextTryMs = c.long("next_try_ms"), updatedMs = c.long("updated_ms"),
    )

    // ---------------------------------------------------------------- frontier mesh

    fun upsertMeshHeartbeat(telemetry: HikerTelemetry, receivedMs: Long = System.currentTimeMillis()) {
        writableDatabase.insertWithOnConflict(
            "mesh_heartbeats",
            null,
            ContentValues().apply {
                put("hiker_id", telemetry.hikerId)
                put("latitude", telemetry.latitude)
                put("longitude", telemetry.longitude)
                put("altitude_m", telemetry.altitudeMeters)
                put("battery_percent", telemetry.batteryPercent)
                put("timestamp_s", telemetry.timestampEpochSeconds)
                put("status", telemetry.status.wireValue)
                put("triage_code", telemetry.triageCode)
                put("received_ms", receivedMs)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    fun meshHeartbeats(receivedAfterMs: Long = 0L): List<HikerTelemetry> =
        readableDatabase.rawQuery(
            """SELECT hiker_id, latitude, longitude, altitude_m, battery_percent, timestamp_s, status, triage_code
               FROM mesh_heartbeats WHERE received_ms >= ? ORDER BY status DESC, timestamp_s DESC LIMIT 8""",
            arrayOf(receivedAfterMs.toString()),
        ).use { c ->
            c.map {
                HikerTelemetry(
                    hikerId = it.getString(0),
                    latitude = it.getDouble(1),
                    longitude = it.getDouble(2),
                    altitudeMeters = it.getInt(3),
                    batteryPercent = it.getInt(4),
                    timestampEpochSeconds = it.getLong(5),
                    status = EmergencyStatus.fromWire(it.getInt(6)),
                    triageCode = it.getInt(7),
                )
            }
        }

    fun pruneMeshHeartbeats(receivedBeforeMs: Long) {
        writableDatabase.delete("mesh_heartbeats", "received_ms < ?", arrayOf(receivedBeforeMs.toString()))
    }

    // ---------------------------------------------------------------- trip groups

    /** The phone's trip group; there is at most one. */
    fun tripGroup(): TripGroupRow? = readableDatabase.rawQuery("SELECT * FROM trip_groups ORDER BY created_ms DESC LIMIT 1", null).use { c ->
        if (!c.moveToFirst()) null else TripGroupRow(
            id = c.str("id"), name = c.str("name"), secret = c.getBlob(c.getColumnIndexOrThrow("secret")),
            memberId = c.int("member_id"), displayName = c.str("display_name"), colour = c.int("colour"),
            createdMs = c.long("created_ms"), expiresMs = c.long("expires_ms"),
        )
    }

    /** Replaces any previous group, and everything known about its members. */
    fun saveTripGroup(g: TripGroupRow) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.delete("trip_groups", "id != ?", arrayOf(g.id))
            val values = ContentValues().apply {
                put("id", g.id); put("name", g.name); put("secret", g.secret); put("member_id", g.memberId)
                put("display_name", g.displayName); put("colour", g.colour); put("created_ms", g.createdMs); put("expires_ms", g.expiresMs)
            }
            // Update in place: REPLACE deletes the row first, and the cascade would take the group's members with it.
            if (db.update("trip_groups", values, "id = ?", arrayOf(g.id)) == 0) db.insertOrThrow("trip_groups", null, values)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun deleteTripGroups() {
        writableDatabase.delete("trip_groups", null, null)
    }

    fun groupMembers(groupId: String): List<GroupMemberRow> =
        readableDatabase.rawQuery("SELECT * FROM group_members WHERE group_id = ?", arrayOf(groupId)).use { c ->
            c.map {
                GroupMemberRow(
                    memberId = it.int("member_id"), name = it.optString(it.getColumnIndexOrThrow("name")),
                    colour = it.optLong(it.getColumnIndexOrThrow("colour"))?.toInt(),
                    position = it.getColumnIndexOrThrow("position").let { i -> if (it.isNull(i)) null else it.getBlob(i) },
                    positionMs = it.long("position_ms"), heardMs = it.long("heard_ms"), directMs = it.long("direct_ms"),
                    rssi = it.optLong(it.getColumnIndexOrThrow("rssi"))?.toInt(), coded = it.int("coded") != 0,
                )
            }
        }

    fun upsertGroupMember(groupId: String, m: GroupMemberRow) {
        writableDatabase.insertWithOnConflict("group_members", null, ContentValues().apply {
            put("group_id", groupId); put("member_id", m.memberId)
            if (m.name != null) put("name", m.name) else putNull("name")
            if (m.colour != null) put("colour", m.colour) else putNull("colour")
            if (m.position != null) put("position", m.position) else putNull("position")
            put("position_ms", m.positionMs); put("heard_ms", m.heardMs); put("direct_ms", m.directMs)
            if (m.rssi != null) put("rssi", m.rssi) else putNull("rssi")
            put("coded", if (m.coded) 1 else 0)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    // ---------------------------------------------------------------- offline packs

    fun insertPack(
        name: String, kind: PackKind, sourceId: String, fileName: String, minZoom: Int, maxZoom: Int,
        bounds: BoundingBox?, routeId: Long?, bufferM: Double, tileTotal: Long, status: PackStatus,
        format: String, attribution: String, premiumMaxZoom: Int = 0,
    ): Long = writableDatabase.insertOrThrow("packs", null, ContentValues().apply {
        put("name", name); put("kind", kind.name); put("source_id", sourceId); put("file_name", fileName)
        put("min_zoom", minZoom); put("max_zoom", maxZoom); put("premium_max_zoom", premiumMaxZoom)
        bounds?.let { put("min_lat", it.minLat); put("min_lon", it.minLon); put("max_lat", it.maxLat); put("max_lon", it.maxLon) }
        routeId?.let { put("route_id", it) }
        put("buffer_m", bufferM); put("tile_total", tileTotal); put("status", status.name)
        put("format", format); put("attribution", attribution); put("created_ms", System.currentTimeMillis())
    })

    fun updatePack(id: Long, values: ContentValues) {
        writableDatabase.update("packs", values, "id=?", arrayOf(id.toString()))
    }

    fun updatePackProgress(id: Long, done: Long, failed: Long, bytes: Long, status: PackStatus, message: String? = null) {
        updatePack(id, ContentValues().apply {
            put("tile_done", done); put("tile_failed", failed); put("bytes", bytes); put("status", status.name)
            if (message != null) put("message", message) else putNull("message")
        })
    }

    fun packs(): List<PackMeta> =
        readableDatabase.rawQuery("SELECT * FROM packs ORDER BY created_ms DESC", null).use { c -> c.map { packMeta(it) } }

    fun pack(id: Long): PackMeta? =
        readableDatabase.rawQuery("SELECT * FROM packs WHERE id=?", arrayOf(id.toString())).use { c ->
            if (c.moveToFirst()) packMeta(c) else null
        }

    fun deletePack(id: Long) {
        writableDatabase.delete("packs", "id=?", arrayOf(id.toString()))
    }

    private fun packMeta(c: Cursor): PackMeta {
        val minLat = c.optDouble(c.getColumnIndexOrThrow("min_lat"))
        val bounds = if (minLat == null) null else BoundingBox(
            minLat, c.dbl("min_lon"), c.dbl("max_lat"), c.dbl("max_lon"),
        )
        return PackMeta(
            id = c.long("id"), name = c.str("name"),
            kind = runCatching { PackKind.valueOf(c.str("kind")) }.getOrDefault(PackKind.DOWNLOAD),
            sourceId = c.str("source_id"), fileName = c.str("file_name"),
            minZoom = c.int("min_zoom"), maxZoom = c.int("max_zoom"), bounds = bounds,
            routeId = c.optLong(c.getColumnIndexOrThrow("route_id")), bufferM = c.dbl("buffer_m"),
            tileTotal = c.long("tile_total"), tileDone = c.long("tile_done"), tileFailed = c.long("tile_failed"),
            bytes = c.long("bytes"),
            status = runCatching { PackStatus.valueOf(c.str("status")) }.getOrDefault(PackStatus.FAILED),
            format = c.str("format"), attribution = c.str("attribution"), createdMs = c.long("created_ms"),
            message = c.optString(c.getColumnIndexOrThrow("message")),
            premiumMaxZoom = c.int("premium_max_zoom"), premiumMs = c.long("premium_ms"),
        )
    }
}

internal inline fun <T> Cursor.map(f: (Cursor) -> T): List<T> {
    val out = ArrayList<T>(count.coerceAtLeast(0))
    while (moveToNext()) out.add(f(this))
    return out
}

private fun Cursor.long(col: String) = getLong(getColumnIndexOrThrow(col))
private fun Cursor.int(col: String) = getInt(getColumnIndexOrThrow(col))
private fun Cursor.dbl(col: String) = getDouble(getColumnIndexOrThrow(col))
private fun Cursor.str(col: String) = getString(getColumnIndexOrThrow(col)) ?: ""
internal fun Cursor.optDouble(i: Int): Double? = if (isNull(i)) null else getDouble(i)
internal fun Cursor.optLong(i: Int): Long? = if (isNull(i)) null else getLong(i)
internal fun Cursor.optString(i: Int): String? = if (isNull(i)) null else getString(i)
