package com.trailmind.core.map

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The opaque, grey LiDAR pictures that the Reveal slider pulls the Ordnance Survey map back to show: ground shaped
 * to bring out what is too low to see from the path (ditches, banks, hut platforms, lynchets, castle ramparts under
 * trees). Built from the same 1 m squares as [Lidar], with a wider border because they look up to 10 m around each cell.
 */
object LidarReveal {
    /** Pixels needed around a square: the furthest a cell looks for a horizon or a local average. */
    const val BORDER = 10

    enum class Style(val id: String, val label: String, val note: String) {
        SVF("svf", "Sky-view", "Shades ground by how much sky a person standing there would see. Ditches, hollows and platforms show dark, " +
            "and banks and ramparts stay light. The best all-round view."),
        SLRM("slrm", "Local relief", "Shows each spot's height against the ground around it: raised ground light, sunken ground dark, " +
            "with the hillside itself removed. Faint banks and ditches stand out."),
        HILLSHADE("hillshade", "Hillshade", "Light from four directions at once, so no bank hides in its own shadow.");

        companion object {
            fun of(id: String?): Style = entries.firstOrNull { it.id == id } ?: SVF
        }
    }

    /**
     * Opaque grey ARGB pixels for a [padded] square (see [Lidar.padded], with [BORDER]); transparent where the heights
     * around a cell are missing, so the map shows through at the edge of the survey.
     */
    fun render(padded: FloatArray, style: Style): IntArray {
        val stride = Lidar.SIZE + 2 * BORDER
        require(padded.size == stride * stride)
        val out = IntArray(Lidar.SIZE * Lidar.SIZE)
        val local = if (style == Style.SLRM) localRelief(padded) else null
        for (row in 0 until Lidar.SIZE) for (col in 0 until Lidar.SIZE) {
            val i = (row + BORDER) * stride + col + BORDER
            if (padded[i].isNaN()) continue
            val tone = when (style) {
                Style.HILLSHADE -> hillshade(padded, i, stride)
                Style.SVF -> {
                    val svf = skyView(padded, i, stride)
                    // Light from the north-west on top keeps the shape of the ground readable.
                    svfTone(svf) * (0.7f + 0.3f * hillshade(padded, i, stride) / FLAT).coerceIn(0.5f, 1.15f)
                }
                Style.SLRM -> {
                    val relief = local!![row * Lidar.SIZE + col]
                    // Eased towards the ends, so faint banks show and a rampart several metres high doesn't flatten to black and white.
                    0.5f + 0.5f * relief / (abs(relief) + SLRM_RANGE_M)
                }
            }
            if (tone.isNaN()) continue
            val grey = (tone.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
            out[row * Lidar.SIZE + col] = (0xFF shl 24) or (grey shl 16) or (grey shl 8) or grey
        }
        return out
    }

    /** Sky-view factor, 1 on open level ground and lower in hollows and under slopes; NaN where there is no height. */
    fun skyView(p: FloatArray, i: Int, stride: Int): Float {
        val z0 = p[i]
        if (z0.isNaN()) return Float.NaN
        var total = 0f
        for (d in 0 until 8) {
            val dx = DIR_X[d]
            val dy = DIR_Y[d]
            val metresPerStep = if (dx != 0 && dy != 0) SQRT2 else 1f
            var rise = 0f
            for (step in STEPS) {
                val v = p[i + dy * step * stride + dx * step]
                if (v.isNaN()) continue
                val t = (v - z0) / (step * metresPerStep)
                if (t > rise) rise = t
            }
            total += rise / sqrt(1 + rise * rise)
        }
        return 1 - total / 8
    }

    private fun svfTone(svf: Float) = ((svf - SVF_DARKEST) / (1 - SVF_DARKEST)).coerceIn(0f, 1f).let { 0.15f + 0.8f * it }

    /** Hillshade from 0 (dark) to 1 averaged over four light directions at 45°, with the relief stretched [Z_FACTOR] times. */
    fun hillshade(p: FloatArray, i: Int, s: Int): Float {
        val dzdx = ((p[i - s + 1] + 2 * p[i + 1] + p[i + s + 1]) - (p[i - s - 1] + 2 * p[i - 1] + p[i + s - 1])) / 8f * Z_FACTOR
        // Rows run south, so the rise towards the north is the opposite of the rise down the rows.
        val dzdy = ((p[i + s - 1] + 2 * p[i + s] + p[i + s + 1]) - (p[i - s - 1] + 2 * p[i - s] + p[i - s + 1])) / 8f * Z_FACTOR
        if (dzdx.isNaN() || dzdy.isNaN()) return Float.NaN
        val norm = sqrt(1 + dzdx * dzdx + dzdy * dzdy)
        var total = 0f
        for (a in LIGHT_SIN.indices) {
            val lit = (COS_ALT * (-dzdx * LIGHT_SIN[a] + dzdy * LIGHT_COS[a]) + FLAT) / norm
            total += lit.coerceIn(0f, 1f)
        }
        return total / LIGHT_SIN.size
    }

    /** Each cell's height minus the average over the 21 × 21 m around it, NaN where it or more than half its neighbours are missing. */
    private fun localRelief(p: FloatArray): FloatArray {
        val stride = Lidar.SIZE + 2 * BORDER
        val out = FloatArray(Lidar.SIZE * Lidar.SIZE) { Float.NaN }
        for (row in 0 until Lidar.SIZE) for (col in 0 until Lidar.SIZE) {
            val i = (row + BORDER) * stride + col + BORDER
            val z = p[i]
            if (z.isNaN()) continue
            var sum = 0.0
            var count = 0
            for (dy in -BORDER..BORDER) {
                val base = i + dy * stride
                for (dx in -BORDER..BORDER) {
                    val v = p[base + dx]
                    if (!v.isNaN()) { sum += v; count++ }
                }
            }
            if (count < WINDOW * WINDOW / 2) continue
            out[row * Lidar.SIZE + col] = (z - sum / count).toFloat()
        }
        return out
    }

    private const val WINDOW = 2 * BORDER + 1
    private const val FLAT = 0.70710677f
    private const val COS_ALT = 0.70710677f
    private const val Z_FACTOR = 2.5f
    /** Sky-view below this is as dark as the picture gets. */
    private const val SVF_DARKEST = 0.78f
    /** Local relief this far above or below its surroundings is half way to as light or dark as the picture gets. */
    private const val SLRM_RANGE_M = 0.25f
    private const val SQRT2 = 1.4142135f
    private val STEPS = intArrayOf(1, 2, 3, 4, 6, 8, 10)
    private val DIR_X = intArrayOf(1, 1, 0, -1, -1, -1, 0, 1)
    private val DIR_Y = intArrayOf(0, 1, 1, 1, 0, -1, -1, -1)
    // Light from the south-west, west, north-west and north.
    private val LIGHT_AZIMUTHS = doubleArrayOf(225.0, 270.0, 315.0, 360.0)
    private val LIGHT_SIN = FloatArray(4) { sin(Math.toRadians(LIGHT_AZIMUTHS[it])).toFloat() }
    private val LIGHT_COS = FloatArray(4) { cos(Math.toRadians(LIGHT_AZIMUTHS[it])).toFloat() }
}
