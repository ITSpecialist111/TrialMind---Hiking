import Foundation

/// A base map, matching the Android app's online sources. OS layers use the user's own OS Data Hub key.
enum MapLayer: String, CaseIterable, Identifiable {
    case osOutdoor = "os_outdoor", osRoad = "os_road", osLight = "os_light", osm = "osm", apple = "apple"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .osOutdoor: return "OS Maps – Outdoor"
        case .osRoad: return "OS Maps – Road"
        case .osLight: return "OS Maps – Light"
        case .osm: return "OpenStreetMap"
        case .apple: return "Apple Maps"
        }
    }

    var isOrdnanceSurvey: Bool { self == .osOutdoor || self == .osRoad || self == .osLight }
    var requiresKey: Bool { isOrdnanceSurvey }

    var minZoom: Int { isOrdnanceSurvey ? 7 : 0 }
    var maxZoom: Int {
        switch self {
        case .osOutdoor, .osRoad, .osLight: return 20
        case .osm: return 19
        case .apple: return 20
        }
    }

    /// OS Premium data starts here: it is charged to the user's plan and may be cached for 24 hours only.
    var premiumFromZoom: Int? { isOrdnanceSurvey ? 17 : nil }

    func attribution(year: Int = Calendar.current.component(.year, from: Date())) -> String? {
        switch self {
        case .osOutdoor, .osRoad, .osLight: return "Contains OS data © Crown copyright and database rights \(year)"
        case .osm: return "© OpenStreetMap contributors"
        case .apple: return nil
        }
    }

    var termsURL: URL? {
        switch self {
        case .osOutdoor, .osRoad, .osLight: return URL(string: "https://www.ordnancesurvey.co.uk/legal")
        case .osm: return URL(string: "https://www.openstreetmap.org/copyright")
        case .apple: return nil
        }
    }

    /// The tile URL, or nil for Apple Maps, a missing key or a zoom outside the layer.
    func tileURL(z: Int, x: Int, y: Int, apiKey: String?) -> URL? {
        guard self != .apple, (minZoom...maxZoom).contains(z) else { return nil }
        let layer: String
        switch self {
        case .osOutdoor: layer = "Outdoor"
        case .osRoad: layer = "Road"
        case .osLight: layer = "Light"
        case .osm: return URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")
        case .apple: return nil
        }
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              var components = URLComponents(string: "https://api.os.uk/maps/raster/v1/zxy/\(layer)_3857/\(z)/\(x)/\(y).png")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url
    }

    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let bundle = Bundle.main.bundleIdentifier ?? "com.trailmind.ios.beta"
        return "TrailMind-iOS/\(version) (\(bundle))"
    }()
}
