import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Beacon's write-up with Apple Intelligence: the on-device model rewrites the rule-based briefing in plain words. It
/// only ever adds to the offline briefing, which stays the reference; any failure just leaves the write-up out.
@MainActor
enum BeaconAI {
    enum Availability: Equatable {
        case available
        /// The iPhone can do it once Apple Intelligence is turned on in Settings.
        case turnedOff
        /// Apple Intelligence is still downloading its model.
        case notReady
        /// This iPhone or iOS can't run it.
        case unsupported
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .notReady
            default: return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    private static let instructions = """
        You are an experienced, safety-focused UK hill-walking leader writing a short, friendly pre-hike briefing for a walker. \
        Use only the facts you are given. Never invent weather, distances, heights, times or place names, and keep every number \
        and time exactly as written. Where something is missing, such as the weather, say what to check instead. \
        Write plain text in short paragraphs or simple lists, under 250 words, with no headings or tables.
        """

    /// Write-ups already made while the app runs, by prompt, so going back to a route doesn't run the model again.
    private static var made: [String: String] = [:]

    static func cached(_ prompt: String) -> String? { made[prompt] }

    /// The model's write-up of `prompt` (the briefing's facts), or nil when the model isn't there or anything goes wrong.
    static func writeUp(_ prompt: String) async -> String? {
        if let done = made[prompt] { return done }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let rules: String = instructions
            let session = LanguageModelSession(instructions: rules)
            do {
                let response = try await session.respond(to: prompt)
                let text = tidy(response.content)
                guard !text.isEmpty else { return nil }
                made[prompt] = text
                return text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Drops Markdown headings and rules the model may still add; inline emphasis is rendered by the page.
    nonisolated static func tidy(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { return "" }
            if trimmed.hasPrefix("#") { return String(trimmed.drop(while: { $0 == "#" }).drop(while: { $0 == " " })) }
            return line
        }
        .joined(separator: "\n")
        .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
