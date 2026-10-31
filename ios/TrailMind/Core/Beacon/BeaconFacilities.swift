import Foundation

/// Facilities found near a route and saved on the phone (data/OverpassFacilities.kt `SavedFacilities`), read from the file
/// the Android app writes (`pois/<route id>.json`), so Beacon's briefing can list them without signal.
struct BeaconFacilities: Hashable {
    var fetchedMs: Int64
    var items: [Facility]
    /// Results were capped or the corridor narrowed, so the list may be incomplete.
    var partial: Bool

    /// The saved file, or nil when it's missing a field or damaged.
    static func parse(_ data: Data) -> BeaconFacilities? {
        guard let json = BeaconJSON.optObject(data), let array = json["items"] as? [Any] else { return nil }
        do {
            let fetchedMs = try BeaconJSON.getLong(json, "fetchedMs")
            let items = try array.map { element -> Facility in
                guard let item = element as? [String: Any] else { throw BeaconJSON.Malformed("A facility isn't an object.") }
                guard let category = FacilityCategory(rawValue: try BeaconJSON.getString(item, "category")) else {
                    throw BeaconJSON.Malformed("Unknown facility category.")
                }
                return Facility(
                    category: category,
                    position: LatLon(try BeaconJSON.getDouble(item, "lat"), try BeaconJSON.getDouble(item, "lon")),
                    name: BeaconJSON.optString(item, "name"),
                    ele: BeaconJSON.optString(item, "ele"),
                    openingHours: BeaconJSON.optString(item, "openingHours"),
                    fee: BeaconJSON.optString(item, "fee"),
                    access: BeaconJSON.optString(item, "access"),
                    website: BeaconJSON.optString(item, "website"),
                    alongM: try BeaconJSON.getDouble(item, "alongM"),
                    offM: try BeaconJSON.getDouble(item, "offM")
                )
            }
            return BeaconFacilities(fetchedMs: fetchedMs, items: items, partial: BeaconJSON.optBoolean(json, "partial", false))
        } catch {
            return nil
        }
    }
}
