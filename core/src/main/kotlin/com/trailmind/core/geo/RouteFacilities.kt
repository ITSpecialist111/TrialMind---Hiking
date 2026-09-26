package com.trailmind.core.geo

enum class FacilityCategory(val label: String, val glyph: String) {
    WATER("Drinking water", "W"), TOILETS("Toilets", "WC"), PUB("Pub", "P"), CAFE("Café", "C"),
    RESTAURANT("Restaurant", "R"), SHOP("Shop", "S"), PARKING("Parking", "P"), BUS("Bus stop", "B"),
    RAIL("Station", "T"), CAMP("Campsite", "C"), STAY("Accommodation", "H"), SHELTER("Shelter", "S"),
    VIEW("Viewpoint", "V"), PEAK("Peak", "▲");

    companion object {
        fun fromTags(tags: Map<String, String>): FacilityCategory? {
            if (tags["access"] == "private") return null
            return when {
                tags["amenity"] == "drinking_water" || tags["amenity"] == "water_point" ||
                    (tags["man_made"] == "water_tap" && tags["drinking_water"] == "yes") -> WATER
                tags["amenity"] == "toilets" -> TOILETS
                tags["amenity"] == "pub" -> PUB
                tags["amenity"] == "cafe" -> CAFE
                tags["amenity"] == "restaurant" -> RESTAURANT
                tags["shop"] in setOf("convenience", "supermarket") -> SHOP
                tags["amenity"] == "parking" -> PARKING
                tags["highway"] == "bus_stop" -> BUS
                tags["railway"] in setOf("station", "halt") -> RAIL
                tags["tourism"] == "camp_site" -> CAMP
                tags["tourism"] in setOf("hostel", "guest_house", "hotel") -> STAY
                tags["amenity"] == "shelter" || tags["tourism"] == "wilderness_hut" || tags["building"] == "hut" -> SHELTER
                tags["tourism"] == "viewpoint" -> VIEW
                tags["natural"] == "peak" && !tags["name"].isNullOrBlank() -> PEAK
                else -> null
            }
        }
    }
}

data class Facility(
    val category: FacilityCategory,
    val position: LatLon,
    val name: String = "",
    val ele: String = "",
    val openingHours: String = "",
    val fee: String = "",
    val access: String = "",
    val website: String = "",
    val alongM: Double = 0.0,
    val offM: Double = 0.0,
)

object RouteFacilities {
    fun corridorM(points: List<LatLon>): Int {
        val length = points.zipWithNext().sumOf { (start, end) -> Geo.distanceM(start, end) }
        return (250.0 * 40_000.0 / length.coerceAtLeast(40_000.0)).toInt().coerceIn(100, 250)
    }

    fun simplify(points: List<LatLon>, maxPoints: Int = 150): List<LatLon> {
        if (points.size <= maxPoints) return points
        var low = 0.0
        var high = points.maxOf { Geo.distanceM(points.first(), it) } + 1.0
        var result = points
        repeat(25) {
            val tolerance = (low + high) / 2
            val kept = BooleanArray(points.size)
            kept[0] = true
            kept[points.lastIndex] = true
            val stack = ArrayDeque<Pair<Int, Int>>()
            stack.add(0 to points.lastIndex)
            while (stack.isNotEmpty()) {
                val (start, end) = stack.removeLast()
                var farthest = 0.0
                var index = -1
                for (i in start + 1 until end) {
                    val distance = Geo.projectOntoSegment(points[i], points[start], points[end]).distanceM
                    if (distance > farthest) { farthest = distance; index = i }
                }
                if (farthest > tolerance && index > start) {
                    kept[index] = true
                    stack.add(start to index)
                    stack.add(index to end)
                }
            }
            val candidate = points.filterIndexed { i, _ -> kept[i] }
            if (candidate.size > maxPoints) low = tolerance else { high = tolerance; result = candidate }
        }
        return result
    }

    fun locate(route: List<LatLon>, facilities: List<Facility>, corridorM: Int = 250): List<Facility> {
        if (route.isEmpty()) return emptyList()
        val cumulative = DoubleArray(route.size)
        for (i in 1 until route.size) cumulative[i] = cumulative[i - 1] + Geo.distanceM(route[i - 1], route[i])
        val projected = facilities.mapNotNull { item ->
            val radius = if (item.category in setOf(FacilityCategory.PARKING, FacilityCategory.BUS, FacilityCategory.RAIL) &&
                minOf(Geo.distanceM(item.position, route.first()), Geo.distanceM(item.position, route.last())) <= 800) 800 else corridorM
            var off = if (route.size == 1) Geo.distanceM(item.position, route.first()) else Double.POSITIVE_INFINITY
            var along = 0.0
            for (i in 1 until route.size) {
                val p = Geo.projectOntoSegment(item.position, route[i - 1], route[i])
                if (p.distanceM < off) {
                    off = p.distanceM
                    along = cumulative[i - 1] + p.fraction * (cumulative[i] - cumulative[i - 1])
                }
                if (p.distanceM <= 75.0) break
            }
            if (off <= radius) item.copy(alongM = along, offM = off) else null
        }.sortedWith(compareBy<Facility> { it.alongM }.thenBy { it.offM })
        val unique = ArrayList<Facility>()
        for (item in projected) {
            if (unique.none { other -> other.category == item.category &&
                Geo.distanceM(other.position, item.position) < 50 &&
                (other.name.equals(item.name, true) || other.name.isBlank() || item.name.isBlank()) }) unique.add(item)
        }
        return unique
    }
}