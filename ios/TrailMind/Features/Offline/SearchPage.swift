import MapKit
import SwiftUI

/// Search (SearchPage.kt): OS Names places with your OS key (Apple Maps without one), grid references and decimal
/// coordinates offline, and ///three.words with your own what3words key. The five most recent searches come back.
struct SearchPage: View {
    @Environment(\.palette) private var p
    @ObservedObject private var prefs = Prefs.shared
    @State private var text = ""
    @State private var query = ""
    @State private var results: [OsNames.Place]? = nil
    @State private var local: OsNames.Place? = nil
    @State private var error: String? = nil
    /// Who named the places found, for the credit line.
    @State private var credit: String? = nil
    @State private var job = 0
    @State private var task: Task<Void, Never>? = nil
    @State private var appleSearch: MKLocalSearch? = nil

    static let route = PageRoute("search") { SearchPage() }

    var body: some View {
        PageScaffold("Search") {
            HStack(alignment: .center, spacing: 8) {
                TMField(hint: "Place, grid ref, coordinates or ///three.words", text: $text, keyboard: .webSearch)
                    .submitLabel(.search)
                    .onSubmit { submit() }
                    .frame(maxWidth: .infinity)
                TMButton("Search", icon: .search, style: .tonal) { submit() }
            }
            if query.isEmpty {
                HelpRow(summary: "Search a place or position.",
                        detail: "Grid references and decimal coordinates work offline. Place names come from Ordnance Survey with your OS key, or from Apple Maps without one. Enter ///word.word.word for what3words; this sends the words to what3words using your own key. Always check the returned location on the map.")
                ForEach(prefs.recentSearches, id: \.self) { previous in
                    ListItemRow(title: previous, subtitle: "Recent search", icon: .search) {
                        text = previous
                        submit()
                    }
                }
            } else {
                if let place = local {
                    ListItemRow(title: place.name, subtitle: "\(place.type) · \(place.area) · \(place.grid ?? "")", icon: .search) { select(place) }
                }
                ForEach(Array((results ?? []).enumerated()), id: \.offset) { _, place in
                    ListItemRow(title: place.name, subtitle: SearchInput.detail(place), icon: .search) { select(place) }
                }
                if let error { TMBanner(message: error) }
                if local == nil && results == nil && error == nil { TMText("Searching places…", .caption) }
                if local?.type == "what3words" {
                    TMBanner(message: "Check the nearby place and map before navigating. A similar-sounding word can identify a distant location.")
                }
                if local == nil && results?.isEmpty == true { TMText("No places found. Try part of the name or a postcode district.", .caption) }
                if local == nil && results != nil { TMText(credit ?? osCredit, .caption) }
            }
        }
        .onChange(of: text) { _, new in
            if new.isEmpty && !query.isEmpty {
                cancel()
                query = ""
                local = nil
                results = nil
                error = nil
            }
        }
        .onDisappear { cancel() }
    }

    private var osCredit: String {
        "Place names: Contains OS data © Crown copyright and database rights \(Calendar(identifier: .gregorian).component(.year, from: Date()))"
    }

    private func cancel() {
        job += 1
        task?.cancel()
        task = nil
        appleSearch?.cancel()
        appleSearch = nil
    }

    private func submit() {
        let t = KotlinText.trim(text)
        if t.isEmpty {
            AppModel.shared.toast("Enter a place or position")
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        query = t
        prefs.recentSearches = SearchInput.recent(t, prefs.recentSearches)
        cancel()
        let id = job
        credit = nil
        switch SearchInput.classify(t, imperial: prefs.imperial) {
        case .threeWords:
            local = nil
            results = nil
            error = nil
            let key = prefs.what3wordsKey
            task = Task { @MainActor in
                do {
                    let address = try await OfflineNet.shared.searchThreeWords(t, key: key)
                    guard id == job else { return }
                    local = ThreeWordsSearch.place(address)
                    results = []
                } catch {
                    guard id == job else { return }
                    self.error = (error as? ThreeWordsSearch.Failure)?.message ?? ThreeWordsSearch.fallback
                }
                task = nil
            }
        case .local(let place):
            local = place
            results = []
            error = nil
        case .invalid(let message):
            local = nil
            results = nil
            error = message
        case .places:
            local = nil
            results = nil
            error = nil
            let key = prefs.osApiKey
            if KotlinText.isBlank(key) {
                searchApple(t, id)
                return
            }
            task = Task { @MainActor in
                do {
                    let places = try await OfflineNet.shared.searchOsNames(t, key: key)
                    guard id == job else { return }
                    results = places
                } catch {
                    guard id == job else { return }
                    results = nil
                    self.error = OsNames.userMessage((error as? OsNames.Failure)?.message)
                }
                task = nil
            }
        }
    }

    /// Without an OS key, Apple Maps names the places, searched around the map's centre.
    private func searchApple(_ t: String, _ id: Int) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = t
        request.resultTypes = [.address, .pointOfInterest]
        let center = MapController.shared.center
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
                                            latitudinalMeters: 300_000, longitudinalMeters: 300_000)
        let search = MKLocalSearch(request: request)
        appleSearch = search
        search.start { response, failure in
            DispatchQueue.main.async {
                guard id == job else { return }
                appleSearch = nil
                if let response {
                    results = response.mapItems.prefix(20).map(Self.place)
                    credit = "Place names: Apple Maps. Add your OS Data Hub key in Settings for Ordnance Survey names."
                } else if let code = (failure as? MKError)?.code, code == .placemarkNotFound {
                    results = []
                    credit = "Place names: Apple Maps. Add your OS Data Hub key in Settings for Ordnance Survey names."
                } else {
                    results = nil
                    error = "Could not reach Apple Maps. Grid references and coordinates still work offline."
                }
            }
        }
    }

    private static func place(_ item: MKMapItem) -> OsNames.Place {
        let mark = item.placemark
        let position = LatLon(mark.coordinate.latitude, mark.coordinate.longitude)
        let name = item.name ?? mark.name ?? "Place"
        let category = item.pointOfInterestCategory.map { category -> String in
            let raw = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
            return raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
        let area = [mark.locality, mark.subAdministrativeArea, mark.administrativeArea, mark.country]
            .compactMap { $0 }
            .first { !KotlinText.isBlank($0) && $0 != name } ?? ""
        let wide = mark.thoroughfare == nil && mark.locality == nil
        return OsNames.Place(name: name, type: category ?? (mark.thoroughfare != nil ? "Address" : "Place"), area: area,
                             position: position, grid: OsGrid.fromWgs84(position)?.format(6), zoom: wide ? 12.0 : 15.0)
    }

    private func select(_ place: OsNames.Place) {
        MapController.shared.showSearchPin(name: place.name, position: place.position, zoom: place.zoom)
        // Beside the map the page goes back; over it, the map shows.
        if Navigator.shared.mapHasPane { Navigator.shared.pop() } else { Navigator.shared.showMap() }
    }
}
