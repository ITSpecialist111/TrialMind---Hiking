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
