import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence: the on-device model (macOS 26+). Free, private, no key — but a small context
// (about 4,000 tokens), no images and no tool calls, so long briefings are shortened and the coach uses its
// whole-game briefing instead of tools.

enum AppleAI {
    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let r):
                switch r {
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri."
                case .modelNotReady: return "Apple Intelligence is still downloading its model. Try again later."
                @unknown default: return "Apple Intelligence isn't available."
                }
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }
    static var available: Bool { status == "available" }

    /// Shortens text to about `limit` characters, keeping the start and the end (the question is usually last).
    static func fit(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = s.prefix(limit * 2 / 3), tail = s.suffix(limit / 3 - 20)
        return head + "\n[…shortened…]\n" + tail
    }

    static func chat(system: String, messages: [AIMessage]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard available else { throw AIClient.AIError(status) }
            if messages.contains(where: { $0.imagePNG != nil }) { throw AIClient.AIError("Apple Intelligence can't read images. Choose a vision model in AI Settings for this.") }
            // Earlier turns condensed into the prompt; the newest message kept as whole as the budget allows.
            var budget = 9000
            for attempt in 0..<3 {
                let history = messages.dropLast().suffix(4).map { "\($0.role == "user" ? "Q" : "A"): \(fit($0.text, 600))" }.joined(separator: "\n")
                let last = fit(messages.last?.text ?? "", budget)
                let prompt = (history.isEmpty ? "" : "Earlier in this conversation:\n\(history)\n\n") + last
                let session = LanguageModelSession(instructions: fit(system, 2500))
                do {
                    return try await session.respond(to: prompt).content
                } catch let e as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = e, attempt < 2 { budget /= 2; continue }
                    if case .guardrailViolation = e { throw AIClient.AIError("Apple Intelligence declined to answer this (its safety filter). Try rephrasing, or use another AI.") }
                    throw AIClient.AIError("Apple Intelligence: \(e.localizedDescription)")
                }
            }
            throw AIClient.AIError("The question was too long for Apple Intelligence.")
        }
        #endif
        throw AIClient.AIError(status)
    }
}
