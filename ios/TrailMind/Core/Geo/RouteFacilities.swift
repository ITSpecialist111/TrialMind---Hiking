import Foundation

/// Persisted by name (the raw value), as on Android.
enum FacilityCategory: String, CaseIterable, Hashable {
    case water = "WATER", toilets = "TOILETS", pub = "PUB", cafe = "CAFE",
         restaurant = "RESTAURANT", shop = "SHOP", parking = "PARKING", bus = "BUS",
         rail = "RAIL", camp = "CAMP", stay = "STAY", shelter = "SHELTER",
         view = "VIEW", peak = "PEAK"

    var label: String {
        switch self {
        case .water: return "Drinking water"
        case .toilets: return "Toilets"
        case .pub: return "Pub"
        case .cafe: return "Café"
        case .restaurant: return "Restaurant"
        case .shop: return "Shop"
        case .parking: return "Parking"
        case .bus: return "Bus stop"
        case .rail: return "Station"
        case .camp: return "Campsite"
        case .stay: return "Accommodation"
        case .shelter: return "Shelter"
        case .view: return "Viewpoint"
        case .peak: return "Peak"
        }
    }

    var glyph: String {
        switch self {
        case .water: return "W"
        case .toilets: return "WC"
        case .pub: return "P"
        case .cafe: return "C"
        case .restaurant: return "R"
        case .shop: return "S"
        case .parking: return "P"
        case .bus: return "B"
        case .rail: return "T"
        case .camp: return "C"
        case .stay: return "H"
        case .shelter: return "S"
        case .view: return "V"
        case .peak: return "▲"
        }
    }

    static func fromTags(_ tags: [String: String]) -> FacilityCategory? {
        if tags["access"] == "private" { return nil }
        func tag(_ key: String, _ values: String...) -> Bool { tags[key].map { values.contains($0) } ?? false }
        if tag("amenity", "drinking_water", "water_point") || (tags["man_made"] == "water_tap" && tags["drinking_water"] == "yes") {
            return .water
        }
        if tag("amenity", "toilets") { return .toilets }
        if tag("amenity", "pub") { return .pub }
        if tag("amenity", "cafe") { return .cafe }
        if tag("amenity", "restaurant") { return .restaurant }
        if tag("shop", "convenience", "supermarket") { return .shop }
        if tag("amenity", "parking") { return .parking }
        if tag("highway", "bus_stop") { return .bus }
        if tag("railway", "station", "halt") { return .rail }
        if tag("tourism", "camp_site") { return .camp }
        if tag("tourism", "hostel", "guest_house", "hotel") { return .stay }
        if tag("amenity", "shelter") || tag("tourism", "wilderness_hut") || tag("building", "hut") { return .shelter }
        if tag("tourism", "viewpoint") { return .view }
        if tag("natural", "peak") && !(tags["name"] ?? "").isBlank { return .peak }
        return nil
    }
}

struct Facility: Hashable {
    var category: FacilityCategory
    var position: LatLon
    var name: String = ""
    var ele: String = ""
    var openingHours: String = ""
    var fee: String = ""
    var access: String = ""
    var website: String = ""
    var alongM: Double = 0.0
    var offM: Double = 0.0
}

enum RouteFacilities {
    static func corridorM(_ points: [LatLon]) -> Int {
        let length = zip(points, points.dropFirst()).reduce(0.0) { sum, pair in sum + Geo.distanceM(pair.0, pair.1) }
        return kTruncate(250.0 * 40_000.0 / max(length, 40_000.0)).clamped(100, 250)
    }

    static func simplify(_ points: [LatLon], maxPoints: Int = 150) -> [LatLon] {
        if points.count <= maxPoints { return points }
        var low = 0.0
        var high = points.dropFirst().reduce(Geo.distanceM(points[0], points[0])) { kMaxOf($0, Geo.distanceM(points[0], $1)) } + 1.0
        var result = points
        for _ in 0..<25 {
            let tolerance = (low + high) / 2
            var kept = [Bool](repeating: false, count: points.count)
            kept[0] = true
            kept[points.count - 1] = true
            var stack: [(Int, Int)] = [(0, points.count - 1)]
            while let range = stack.popLast() {
                let (start, end) = range
                var farthest = 0.0
                var index = -1
                for i in stride(from: start + 1, to: end, by: 1) {
                    let distance = Geo.projectOntoSegment(points[i], points[start], points[end]).distanceM
                    if distance > farthest {
                        farthest = distance
                        index = i
                    }
                }
                if farthest > tolerance && index > start {
                    kept[index] = true
                    stack.append((start, index))
                    stack.append((index, end))
                }
            }
            let candidate = points.indices.filter { kept[$0] }.map { points[$0] }
            if candidate.count > maxPoints {
                low = tolerance
            } else {
                high = tolerance
                result = candidate
            }
        }
        return result
    }

    static func locate(_ route: [LatLon], _ facilities: [Facility], corridorM: Int = 250) -> [Facility] {
        if route.isEmpty { return [] }
        var cumulative = [Double](repeating: 0.0, count: route.count)
        for i in 1..<route.count { cumulative[i] = cumulative[i - 1] + Geo.distanceM(route[i - 1], route[i]) }
        let transport: Set<FacilityCategory> = [.parking, .bus, .rail]
        let projected = facilities.compactMap { item -> Facility? in
            let radius = transport.contains(item.category) &&
                kMinOf(Geo.distanceM(item.position, route[0]), Geo.distanceM(item.position, route[route.count - 1])) <= 800 ? 800 : corridorM
            var off = route.count == 1 ? Geo.distanceM(item.position, route[0]) : Double.infinity
            var along = 0.0
            for i in 1..<route.count {
                let p = Geo.projectOntoSegment(item.position, route[i - 1], route[i])
                if p.distanceM < off {
                    off = p.distanceM
                    along = cumulative[i - 1] + p.fraction * (cumulative[i] - cumulative[i - 1])
                }
                if p.distanceM <= 75.0 { break }
            }
            guard off <= Double(radius) else { return nil }
            var found = item
            found.alongM = along
            found.offM = off
            return found
        }
        // A stable sort by distance along the route, then distance off it (Kotlin's sortedWith).
        let sorted = projected.enumerated()
            .sorted { ($0.element.alongM, $0.element.offM, $0.offset) < ($1.element.alongM, $1.element.offM, $1.offset) }
            .map { $0.element }
        var unique: [Facility] = []
        for item in sorted {
            let duplicate = unique.contains { other in
                other.category == item.category && Geo.distanceM(other.position, item.position) < 50 &&
                    (other.name.lowercased() == item.name.lowercased() || other.name.isBlank || item.name.isBlank)
            }
            if !duplicate { unique.append(item) }
        }
        return unique
    }
}
