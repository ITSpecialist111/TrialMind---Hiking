package com.trailmind.core.map

import kotlin.math.floor
import kotlin.math.ln

/**
 * The OS Maps API tile grid in British National Grid (EPSG:27700): 256 px tiles from a fixed top-left
 * corner, with the resolution halving at each zoom from 896 m per pixel. Values from OS's WMTS capabilities.
 */
object BngTiles {
    const val ORIGIN_E = -238_375.0
    const val ORIGIN_N = 1_376_256.0
    const val TILE_SIZE = 256

    /** The National Grid's extent over Great Britain. */
    const val GB_MAX_E = 700_000.0
    const val GB_MAX_N = 1_300_000.0

    fun resolution(z: Int): Double = 896.0 / (1 shl z)

    private fun span(z: Int) = TILE_SIZE * resolution(z)

    fun column(easting: Double, z: Int): Int = floor((easting - ORIGIN_E) / span(z)).toInt()

    fun row(northing: Double, z: Int): Int = floor((ORIGIN_N - northing) / span(z)).toInt()

    /** The west edge of [column]. */
    fun easting(column: Int, z: Int): Double = ORIGIN_E + column * span(z)

    /** The north edge of [row]. */
    fun northing(row: Int, z: Int): Double = ORIGIN_N - row * span(z)

    /** The most detailed zoom whose pixels are no smaller than [metresPerPixel], as Web Mercator zooms are chosen. */
    fun zoomFor(metresPerPixel: Double, minZoom: Int, maxZoom: Int): Int =
        floor(ln(896.0 / metresPerPixel) / ln(2.0) + 1e-9).toInt().coerceIn(minZoom, maxZoom)
}
