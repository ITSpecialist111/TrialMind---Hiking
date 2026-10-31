import Foundation

/// Beacon's wording that needs no phone (AssistantPage): which briefing lines are shown as warnings, and the rules and
/// tidying for the write-up Apple's on-device model makes of the briefing.
enum BeaconText {
    /// Lines the Android app shows in the danger colour: warnings, and anything about finishing after sunset or in the
    /// dark (Kotlin's `startsWith("⚠")` and `contains(..., ignoreCase = true)`).
    static func warns(_ line: String) -> Bool {
        line.unicodeScalars.first == "\u{26A0}" || line.range(of: "after sunset", options: .caseInsensitive) != nil
            || line.range(of: "dark", options: .caseInsensitive) != nil
    }

    /// A briefing line as a bullet, as Android lists them.
    static func bullet(_ line: String) -> String { "•  " + line }

    /// The next quarter of an hour after `now` (AssistantPage.nextQuarterHour): the planned start Beacon opens with.
    static func nextQuarterHour(_ now: Int64) -> Int64 {
        let q: Int64 = 15 * 60_000
        return (now / q + 1) * q
    }

    /// When to set off along `points` to be down before sunset with `marginMinutes` to spare, for a walk starting at
    /// `forMs` (DaylightText.startByText). `clock` writes a time of day and `finish` a time that may fall on another
    /// day ("tomorrow 06:41"), both in `zone` and in the phone's own style.
    static func startBy(_ points: [TrackPoint], pace: PaceSettings, marginMinutes: Int, forMs: Int64, zone: TimeZone,
                        clock: (Int64) -> String, finish: (Int64) -> String) -> String {
        guard points.count >= 2 else { return "No route timing available." }
        let sun = Sun.times(epochDay: CivilDate.localEpochDay(forMs, zone), points[0].latLon())
        let estimate = Daylight.estimate(nowMs: forMs, remaining: points, walked: [], movingMinutes: nil, pace: pace, sun: sun,
                                         marginMinutes: max(marginMinutes, 0), zone: zone)
        if estimate.darkNow == true {
            return "It's dark now. " + (estimate.nextSunriseMs.map { "Sunrise \(finish($0))." } ?? "No sunrise time available.")
        }
        guard let sunset = sun.sunsetMs else {
            return sun.polarDay ? "No sunset today at this location." : "Daylight times unavailable here."
        }
        guard let startBy = estimate.startByMs else { return "No start time today: route is too long to finish before sunset." }
        return "Start by \(clock(startBy)) to finish before sunset (\(clock(sunset))) with \(marginMinutes) min to spare" +
            (startBy < forMs ? " (start-by time has passed)." : ".")
    }

    /// What the on-device model is told before it sees the briefing prompt.
    static let writeUpInstructions = "You are an experienced, safety-focused UK hill-walking leader writing a short, friendly " +
        "pre-hike briefing for a walker. Use only the facts you are given. Never invent weather, distances, heights, times or " +
        "place names, and keep every number and time exactly as written. Where something is missing, such as the weather, say " +
        "what to check instead. Write plain text in short paragraphs or simple lists, under 250 words, with no headings or tables."

    /// The model's answer ready to show: Markdown headings lose their hashes, horizontal rules go, runs of blank lines
    /// close up, and the ends are trimmed. Inline emphasis is left for the page to render.
    static func tidyWriteUp(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }) {
                return ""
            }
            if trimmed.hasPrefix("#") {
                return String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
            }
            return line
        }
        var out: [String] = []
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && (out.last.map { $0.isEmpty } ?? true) { continue }
            out.append(blank ? "" : line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
