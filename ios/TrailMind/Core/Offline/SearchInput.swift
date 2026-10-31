import Foundation

/// What Search does with the text typed (SearchPage.submit): ///three.words go to what3words, grid references and
/// decimal coordinates are found on the phone, text that looks like one but isn't valid is refused with the reason,
/// and anything else is a place-name search.
enum SearchInput: Equatable {
    case threeWords
    case local(OsNames.Place)
    case invalid(String)
    case places

    static let invalidGrid = "Invalid OS grid reference. Use two letters (not I) and an even number of digits."
    static let invalidCoordinates = "Coordinates must be within 90° latitude and 180° longitude."

    static func classify(_ text: String, imperial: Bool) -> SearchInput {
        if ThreeWordAddress.looksLike(text) { return .threeWords }
        let grid = OsGrid.parse(text)
        let coordinates = PlaceQuery.coordinates(text)
        if let grid {
            return .local(OsNames.Place(name: text, type: "Grid reference",
                                        area: "\(Units.distance(Double(grid.precisionM), imperial: imperial)) square",
                                        position: grid.position, grid: text.uppercased(), zoom: grid.precisionM >= 100_000 ? 9.0 : 15.0))
        }
        if let coordinates {
            return .local(OsNames.Place(name: text, type: "Coordinates", area: "", position: coordinates,
                                        grid: OsGrid.fromWgs84(coordinates)?.format(6), zoom: 15.0))
        }
        if PlaceQuery.looksLikeGrid(text) { return .invalid(invalidGrid) }
        if PlaceQuery.looksLikeCoordinates(text) { return .invalid(invalidCoordinates) }
        return .places
    }

    /// The five most recent searches, newest first, without repeating one that differs only in case.
    static func recent(_ text: String, _ previous: [String]) -> [String] {
        Array(([text] + previous.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(5))
    }

    /// A result's second line: its type, area and grid reference, leaving out the blank ones.
    static func detail(_ place: OsNames.Place) -> String {
        [place.type, place.area, place.grid ?? ""].filter { !KotlinText.isBlank($0) }.joined(separator: " · ")
    }
}
