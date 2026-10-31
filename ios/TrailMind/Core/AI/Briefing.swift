import Foundation

struct BriefingInput: Hashable {
    var routeName: String
    var estimate: HikeEstimate
    var start: LatLon
    var end: LatLon
    var maxEleM: Double?
    var waypointNames: [String]
    var sun: SunTimes?
    var plannedStartMs: Int64
    var zone: TimeZone = .current
    var imperial: Bool = false
    var highPoint: HighPoint? = nil
    /// Forecast for `highPoint`, fetched earlier and kept offline.
    var forecast: PointForecast? = nil
    var facilities: [Facility] = []
    var facilitiesPartial: Bool = false
}

/// Builds (1) a deterministic, rule-based trip briefing that works fully offline and (2) a self-contained prompt the
/// user can paste into an on-device LLM (e.g. Gemma in Google AI Edge Gallery). Nothing here calls a model.
enum Briefing {
    private static let clock = "HH:mm"
    private static let dayClock = "EEE HH:mm"
    /// Moving time plus breaks.
    private static let withBreaks = 1.2

    static func ruleBased(_ input: BriefingInput) -> [String] {
        let e = input.estimate
        var lines: [String] = []
        lines.append("\(Units.distance(e.distanceM, imperial: input.imperial)) with \(Units.elevation(e.ascentM, imperial: input.imperial)) of ascent " +
            "and \(Units.elevation(e.descentM, imperial: input.imperial)) of descent.")
        lines.append("Estimated moving time \(Units.minutes(e.naismithMinutes)) (Naismith/Langmuir) – " +
            "\(Units.minutes(e.toblerMinutes)) (Tobler). Add breaks: plan for \(Units.minutes(e.planningMinutes * withBreaks)).")
        let finish = input.plannedStartMs + kTruncateL(e.planningMinutes * withBreaks * 60_000)
        if let sunset = input.sun?.sunsetMs {
            let margin = (sunset - finish) / 60_000
            if margin < 0 {
                lines.append("⚠ Likely finish \(fmt(finish, input.zone)) is AFTER sunset (\(fmt(sunset, input.zone))). Start earlier, shorten, or carry a head torch.")
            } else if margin < 60 {
                lines.append("⚠ Only \(margin) min of daylight margin (sunset \(fmt(sunset, input.zone))). Carry a head torch.")
            } else {
                lines.append("Sunset \(fmt(sunset, input.zone)); expected finish ~\(fmt(finish, input.zone)).")
            }
        } else if input.sun?.polarNight == true {
            lines.append("⚠ No sunrise at this location today.")
        }
        if let hp = input.highPoint, let forecast = input.forecast {
            let eta = input.plannedStartMs + kTruncateL(hp.minutesFromStart * withBreaks * 60_000)
            let place = "the high point (\(Units.elevation(hp.eleM, imperial: input.imperial)))"
            if let hour = forecast.at(eta) {
                lines.append("Forecast for \(place) at about \(fmt(eta, input.zone)): \(MountainWeather.summary(hour, imperial: input.imperial)) " +
                    "(Open-Meteo, fetched \(fmt(forecast.fetchedMs, input.zone, dayClock))).")
                for warning in MountainWeather.warnings(hour, eleM: hp.eleM, imperial: input.imperial) { lines.append("⚠ \(warning)") }
            } else {
                lines.append("The saved forecast doesn't reach \(fmt(eta, input.zone, dayClock)), when you'd be at \(place): update it nearer the time.")
            }
        } else if let maxEle = input.maxEleM, maxEle >= 600 {
            lines.append("High point \(Units.elevation(maxEle, imperial: input.imperial)): expect it to be colder and windier than the valley (≈1°C per 150 m) and check the mountain forecast.")
        }
        let climbPerKm = e.ascentM / max(e.distanceM / 1000.0, 0.1)
        if climbPerKm > 80 {
            lines.append("Steep overall (\(kTruncate(climbPerKm)) m climb per km): allow extra time and take care on descents.")
        }
        let grid = OsGrid.fromWgs84(input.start)?.format(6)
        lines.append("Start \(grid ?? Units.latLon(input.start.lat, input.start.lon))" + (input.start == input.end
            ? " (circular)."
            : "; finish \(OsGrid.fromWgs84(input.end)?.format(6) ?? Units.latLon(input.end.lat, input.end.lon))."))
        if !input.waypointNames.isEmpty { lines.append("Waypoints: \(input.waypointNames.prefix(12).joined(separator: ", ")).") }
        if !input.facilities.isEmpty {
            let priority: [FacilityCategory] = [.parking, .toilets, .water, .cafe, .pub, .bus, .rail]
            func rank(_ item: Facility) -> Int { priority.firstIndex(of: item.category) ?? priority.count }
            var seen = Set<FacilityCategory>()
            let distinct = input.facilities.filter { seen.insert($0.category).inserted }
            // Stable sorts, as Kotlin's sortedWith and sortedBy are.
            let ranked = distinct.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map { $0.element }
            let stops = ranked.prefix(4).enumerated().sorted { ($0.element.alongM, $0.offset) < ($1.element.alongM, $1.offset) }
                .map { $0.element }
                .map { item -> String in
                    let place = item.alongM < 150 ? "at the start" : "at \(Units.distance(item.alongM, imperial: input.imperial))"
                    let title = item.name.isBlank ? item.category.label : "\(item.name.prefix(30)) \(item.category.label.lowercased())"
                    return "\(title) \(place)"
                }
            lines.append("Facilities\(input.facilitiesPartial ? " (limited results)" : ""): \(stops.joined(separator: "; ")).")
        }
        lines.append("Tell someone your route and return time. In the UK call 999 or 112, ask for Police, then Mountain Rescue.")
        return lines
    }

    static func gemmaPrompt(_ input: BriefingInput) -> String {
        var text = ""
        func appendLine(_ line: String = "") { text += line + "\n" }
        appendLine("You are an experienced, safety-focused UK hill-walking leader. Using ONLY the facts below, write a short pre-hike briefing:")
        appendLine("1) a realistic timing plan with breaks, 2) kit checklist for the conditions, 3) key hazards and turn-back points, 4) a 3-line emergency plan.")
        appendLine("If information is missing (e.g. weather), say what I should check rather than inventing it.")
        appendLine()
        appendLine("Route: \(input.routeName)")
        appendLine("Facts:")
        for line in ruleBased(input) { appendLine("- \(line)") }
        appendLine("- Planned start: \(fmt(input.plannedStartMs, input.zone)) local time")
        return text
    }

    /// `DateTimeFormatter.ofPattern(format)` in `zone`: day names in the phone's language, digits always ASCII as
    /// java.time writes them.
    private static func fmt(_ ms: Int64, _ zone: TimeZone, _ format: String = clock) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        return format.split(separator: " ").map { field -> String in
            let formatter = DateFormatter()
            formatter.locale = field.hasPrefix("E") ? Locale.current : Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = String(field)
            return formatter.string(from: date)
        }.joined(separator: " ")
    }
}
