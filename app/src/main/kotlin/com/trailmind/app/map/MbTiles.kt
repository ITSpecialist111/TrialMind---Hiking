package com.trailmind.app.map

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import com.trailmind.core.geo.BoundingBox
import com.trailmind.core.geo.TileKey
import java.io.Closeable
import java.io.File

/** Minimal MBTiles 1.3 (raster) reader/writer on the framework SQLite. */
class MbTiles private constructor(val file: File, private val db: SQLiteDatabase) : Closeable {

    fun getTile(k: TileKey): ByteArray? =
        db.rawQuery(
            "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
            arrayOf(k.z.toString(), k.x.toString(), k.tmsY.toString()),
        ).use { c -> if (c.moveToFirst()) c.getBlob(0) else null }

    fun hasTile(k: TileKey): Boolean =
        db.rawQuery(
            "SELECT 1 FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1",
            arrayOf(k.z.toString(), k.x.toString(), k.tmsY.toString()),
        ).use { it.moveToFirst() }

    fun putTile(k: TileKey, data: ByteArray) {
        db.insertWithOnConflict("tiles", null, ContentValues().apply {
            put("zoom_level", k.z); put("tile_column", k.x); put("tile_row", k.tmsY); put("tile_data", data)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun metadata(): Map<String, String> = runCatching {
        db.rawQuery("SELECT name, value FROM metadata", null).use { c ->
            val m = HashMap<String, String>()
            while (c.moveToNext()) m[c.getString(0) ?: continue] = c.getString(1) ?: ""
            m
        }
    }.getOrDefault(emptyMap())

    fun tileCount(): Long = db.rawQuery("SELECT COUNT(*) FROM tiles", null).use { if (it.moveToFirst()) it.getLong(0) else 0 }

    fun zoomRange(): IntRange? = db.rawQuery("SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles", null).use {
        if (it.moveToFirst() && !it.isNull(0)) it.getInt(0)..it.getInt(1) else null
    }

    override fun close() = db.close()

    data class Info(
        val name: String?,
        val format: String,
        val bounds: BoundingBox?,
        val minZoom: Int,
        val maxZoom: Int,
        val attribution: String,
        val tileCount: Long,
    )

    fun info(): Info {
        val md = metadata()
        val zr = zoomRange()
        val bounds = md["bounds"]?.split(',')?.mapNotNull { it.trim().toDoubleOrNull() }?.takeIf { it.size == 4 }
            ?.let { BoundingBox(it[1], it[0], it[3], it[2]) }
        return Info(
            name = md["name"],
            format = (md["format"] ?: sniffFormat()).lowercase(),
            bounds = bounds,
            minZoom = md["minzoom"]?.toIntOrNull() ?: zr?.first ?: 0,
            maxZoom = md["maxzoom"]?.toIntOrNull() ?: zr?.last ?: 18,
            attribution = stripHtml(md["attribution"] ?: ""),
            tileCount = tileCount(),
        )
    }

    private fun sniffFormat(): String {
        val sample = db.rawQuery("SELECT tile_data FROM tiles LIMIT 1", null).use { if (it.moveToFirst()) it.getBlob(0) else null }
            ?: return "png"
        return when {
            sample.size > 4 && sample[0] == 0x89.toByte() && sample[1] == 'P'.code.toByte() -> "png"
            sample.size > 3 && sample[0] == 0xFF.toByte() && sample[1] == 0xD8.toByte() -> "jpg"
            sample.size > 12 && String(sample, 8, 4, Charsets.US_ASCII) == "WEBP" -> "webp"
            sample.size > 2 && sample[0] == 0x1f.toByte() && sample[1] == 0x8b.toByte() -> "pbf"
            else -> "unknown"
        }
    }

    companion object {
        val RASTER_FORMATS = setOf("png", "jpg", "jpeg", "webp")

        fun open(file: File): MbTiles {
            val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            return MbTiles(file, db)
        }

        fun openReadOnly(file: File): MbTiles {
            val db = SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            return MbTiles(file, db)
        }

        fun create(file: File, name: String, bounds: BoundingBox?, minZoom: Int, maxZoom: Int, attribution: String): MbTiles {
            file.parentFile?.mkdirs()
            val db = SQLiteDatabase.openOrCreateDatabase(file, null)
            db.execSQL("CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT)")
            db.execSQL("CREATE TABLE IF NOT EXISTS tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
            db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS tile_index ON tiles (zoom_level, tile_column, tile_row)")
            db.delete("metadata", null, null)
            fun md(k: String, v: String) = db.insert("metadata", null, ContentValues().apply { put("name", k); put("value", v) })
            md("name", name)
            md("format", "png")
            md("type", "baselayer")
            md("version", "1")
            md("minzoom", minZoom.toString())
            md("maxzoom", maxZoom.toString())
            md("attribution", attribution)
            bounds?.let { md("bounds", "${it.minLon},${it.minLat},${it.maxLon},${it.maxLat}") }
            return MbTiles(file, db)
        }

        private fun stripHtml(s: String) = s.replace(Regex("<[^>]*>"), "").replace("&copy;", "©").trim()
    }
}
