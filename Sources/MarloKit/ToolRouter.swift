import Foundation
import FoundationModels

/// Picks which tools a turn actually needs, before the turn is answered.
///
/// Declaring a tool has a fixed cost on *every* request, whether or not it is
/// used — roughly 95 tokens for the twelve Marlo ships with, on top of framing.
/// The alternative is a first, cheap pass with no tools at all that reads a
/// list of tool names and descriptions and names the ones the message needs.
/// Only those are then declared for the real turn.
///
/// The router is a pure function of the message and the candidate tools. It
/// cannot enable anything: its answer is always intersected with the set the
/// caller offers, so a routing mistake can never resurrect a tool the user
/// turned off. It also never runs when tools are off — "off" means off.
public struct ToolRouter: Sendable {
    private let model: SystemLanguageModel

    /// Caps the routing reply. The expected answer is a few tool names, and a
    /// cap is what keeps a confused model from writing an essay instead.
    private let maximumResponseTokens: Int

    public init(
        model: SystemLanguageModel = .default,
        maximumResponseTokens: Int = 24
    ) {
        self.model = model
        self.maximumResponseTokens = maximumResponseTokens
    }

    public enum Outcome: Sendable, Equatable {
        /// The model named these tools; already intersected with the candidates.
        case chosen(Set<String>)
        /// The model said no tool is needed.
        case none
        /// The router could not be used or its reply could not be read. The
        /// caller should fall back to declaring everything, which is safe.
        case unresolved(String)
    }

    /// Ask which of `candidates` the message needs.
    ///
    /// `previousMessage` is the turn before this one, if any. It is included
    /// because follow-ups like "and in Porto?" are meaningless alone, and
    /// because it is one message rather than a growing window: routing should
    /// not reintroduce the context cost it exists to avoid.
    public func decide(
        message: String,
        previousMessage: String?,
        candidates: [(name: String, summary: String)]
    ) async -> Outcome {
        guard !candidates.isEmpty else { return .none }

        let session = LanguageModelSession(
            instructions: Instructions(Self.instructions)
        )

        do {
            let response = try await session.respond(
                to: Self.prompt(
                    message: message,
                    previousMessage: previousMessage,
                    candidates: candidates
                ),
                options: GenerationOptions(
                    maximumResponseTokens: maximumResponseTokens,
                    // Recorded intent, not a guarantee: on this build the model
                    // can still call a tool with tool calling "disallowed", so
                    // the session having no tools is what actually enforces it.
                    toolCallingMode: .disallowed
                )
            )
            return Self.parse(response.content, candidates: Set(candidates.map(\.name)))
        } catch {
            return .unresolved(error.localizedDescription)
        }
    }

    // MARK: Prompt

    static let instructions = """
    You choose tools. Read the available tools and the user's message, then \
    reply with the names of the tools needed, comma separated. If no tool is \
    needed, reply NONE. Reply with names only — no explanation, no punctuation \
    beyond the commas, no other text.
    """

    static func prompt(
        message: String,
        previousMessage: String?,
        candidates: [(name: String, summary: String)]
    ) -> String {
        let listing = candidates
            .map { "- \($0.name): \($0.summary)" }
            .joined(separator: "\n")

        var lines = ["Tools:", listing, ""]
        if let previousMessage, !previousMessage.isEmpty {
            lines.append("Previous user message: \(previousMessage)")
        }
        lines.append("User message: \(message)")
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing

    /// Read a tool selection out of a model reply.
    ///
    /// The reply is usually a bare list, but the model has been observed to
    /// append its reasoning — `"convertCurrency, 100 USD to JPY"`. So this
    /// looks for known names anywhere in the text rather than trusting the
    /// shape of the reply, and matches on whole words so `getWeather` cannot be
    /// found inside a longer token.
    static func parse(_ reply: String, candidates: Set<String>) -> Outcome {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .unresolved("empty reply") }

        let upper = trimmed.uppercased()
        if upper == "NONE" || upper == "NO" || upper.contains("NONE") && !containsAnyName(trimmed, in: candidates) {
            return .none
        }

        let chosen = names(in: trimmed, candidates: candidates)
        if chosen.isEmpty {
            // A reply that is neither a recognisable name nor a clear NONE. The
            // caller declares everything rather than guessing.
            return .unresolved("no known tool name in reply")
        }
        return .chosen(chosen)
    }

    /// Every candidate name appearing as a whole word in `text`.
    static func names(in text: String, candidates: Set<String>) -> Set<String> {
        candidates.filter { name in
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: name, options: [.caseInsensitive], range: searchRange) {
                let before = found.lowerBound == text.startIndex
                    ? nil
                    : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex
                    ? nil
                    : text[found.upperBound]
                let boundaryBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
                let boundaryAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
                if boundaryBefore && boundaryAfter { return true }
                searchRange = found.upperBound..<text.endIndex
            }
            return false
        }
    }

    private static func containsAnyName(_ text: String, in candidates: Set<String>) -> Bool {
        !names(in: text, candidates: candidates).isEmpty
    }
}
