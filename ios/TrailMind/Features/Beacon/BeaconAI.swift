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
        /// Apple Intelligence is still getting its model ready.
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

    /// Write-ups already made while the app runs, by prompt, so going back to a route doesn't run the model again.
    private static var made: [String: String] = [:]

    static func cached(_ prompt: String) -> String? { made[prompt] }

    /// The model's write-up of `prompt` (the briefing's facts), or nil when the model isn't there or anything goes wrong
    /// (not enabled, a language it doesn't speak, its guardrails, or the page closing first).
    static func writeUp(_ prompt: String) async -> String? {
        if let done = made[prompt] { return done }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            let rules: String = BeaconText.writeUpInstructions
            let session = LanguageModelSession(instructions: rules)
            do {
                // A cool temperature keeps the model close to the facts it was given.
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.4))
                let text = BeaconText.tidyWriteUp(response.content)
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
}
