package com.trailmind.core.frontier

/**
 * Open-sky estimate from a small camera frame. It needs no model: sky is bright and blue-white or grey, while trees,
 * rock and buildings are darker, green or brown. It is a guide for where to stand, not a measurement, and it can be fooled by
 * snow, pale rock and glass, which is why the screen asks you to judge it by eye.
 */
object SkyCheck {
    class Result(val cols: Int, val rows: Int, val sky: BooleanArray, val openAbove25Pct: Int?, val line25Frac: Float?, val pitchDeg: Double)

    fun isSky(argb: Int): Boolean {
        val r = argb shr 16 and 0xFF
        val g = argb shr 8 and 0xFF
        val b = argb and 0xFF
        val luma = 0.299 * r + 0.587 * g + 0.114 * b
        if (luma >= 215) return true
        if (g > b + 8) return false
        return luma >= 105 && b >= r - 4 && b >= g * 0.9
    }

    /**
     * [pitchDeg] is how high the camera axis points; [vFovDeg] the vertical field of view of the picture, whose top row is
     * the highest. Only the part of the picture above [minElevDeg] counts towards the percentage.
     */
    fun analyse(pixels: IntArray, w: Int, h: Int, pitchDeg: Double, vFovDeg: Double, minElevDeg: Double = 25.0): Result {
        require(pixels.size >= w * h) { "pixel array too small" }
        val sky = BooleanArray(w * h) { isSky(pixels[it]) }
        var considered = 0
        var open = 0
        for (y in 0 until h) {
            val elevation = pitchDeg + (0.5 - (y + 0.5) / h) * vFovDeg
            if (elevation < minElevDeg) continue
            for (x in 0 until w) { considered++; if (sky[y * w + x]) open++ }
        }
        val f = (0.5 - (minElevDeg - pitchDeg) / vFovDeg).toFloat()
        return Result(w, h, sky, if (considered == 0) null else Math.round(100.0 * open / considered).toInt(), f.takeIf { it in 0f..1f }, pitchDeg)
    }
}
