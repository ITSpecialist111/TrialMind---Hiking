package com.trailmind.app.share

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Minimal read-only provider exposing files in cacheDir/exports (GPX files for sharing to
 * Strava, email, Drive…). Not exported; access is granted per-URI via FLAG_GRANT_READ_URI_PERMISSION.
 */
class ExportProvider : ContentProvider() {
    override fun onCreate() = true

    private fun fileFor(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        val dir = dir(ctx)
        val f = File(dir, name)
        if (f.parentFile?.canonicalPath != dir.canonicalPath || !f.isFile) throw FileNotFoundException(uri.toString())
        return f
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read-only")
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = if (uri.lastPathSegment?.endsWith(".gpx") == true) GPX_MIME else "application/octet-stream"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = fileFor(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = cols.map<String, Any?> { c ->
            when (c) {
                OpenableColumns.DISPLAY_NAME -> f.name
                OpenableColumns.SIZE -> f.length()
                else -> null
            }
        }
        return MatrixCursor(cols, 1).apply { addRow(row.toTypedArray()) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        const val AUTHORITY = "com.trailmind.app.exports"
        const val GPX_MIME = "application/gpx+xml"

        fun dir(ctx: Context): File = File(ctx.cacheDir, "exports").apply { mkdirs() }

        /** Writes [content] to a shareable file and returns its content:// URI. */
        fun write(ctx: Context, fileName: String, content: String): Uri {
            val safe = fileName.replace(Regex("[^A-Za-z0-9._-]+"), "_").take(80).ifBlank { "export.gpx" }
            val f = File(dir(ctx), safe)
            f.writeText(content, Charsets.UTF_8)
            return Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(safe).build()
        }
    }
}
