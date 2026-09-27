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

class Db(context: Context) : SQLiteOpenHelper(context, "trailmind.db", null, 4) {

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
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE packs ADD COLUMN premium_max_zoom INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE packs ADD COLUMN premium_ms INTEGER NOT NULL DEFAULT 0")
        }
        // Test builds shipped two different version 3 schemas (terrain or Frontier), so version 4 adds whichever is missing.
        if (oldVersion < 4) {
            val hasTerrainColumn = db.compileStatement(
                "SELECT COUNT(*) FROM pragma_table_info('routes') WHERE name = 'terrain_derived'",
            ).use { it.simpleQueryForLong() } > 0
            if (!hasTerrainColumn) db.execSQL("ALTER TABLE routes ADD COLUMN terrain_derived INTEGER NOT NULL DEFAULT 0")
            createMeshHeartbeats(db)
        }
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
