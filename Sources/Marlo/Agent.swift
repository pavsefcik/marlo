import Foundation
import FoundationModels

/// Anything the assistant does that an interface may want to show, log, or gate.
enum AgentEvent: Sendable {
    case toolStarted(name: String, arguments: String)
    case toolFinished(name: String, result: String)
    case modelRetry(attempt: Int, reason: String)
}

/// Bridges one `AssistantTool` into a framework `Tool`.
/// (`BridgedTool` and `AnyAssistantTool` live in AssistantTool.swift.)

/// Callbacks an interface installs. A reference type so tools can report while
/// the owning `Agent` actor stays isolated.
final class ToolEventSink: @unchecked Sendable {
    typealias EventHandler = @Sendable (AgentEvent) -> Void
    typealias ApprovalHandler = @Sendable (_ name: String, _ arguments: String) -> Bool

    private let lock = NSLock()
    private var onEvent: EventHandler?
    private var onApproval: ApprovalHandler?

    /// When true, mutating tools run without asking.
    private var autoApprove = false

    func configure(
        onEvent: EventHandler?,
        onApproval: ApprovalHandler?,
        autoApprove: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.onEvent = onEvent
        self.onApproval = onApproval
        self.autoApprove = autoApprove
    }

    func emit(_ event: AgentEvent) {
        lock.lock()
        let handler = onEvent
        lock.unlock()
        handler?(event)
    }

    func requestApproval(name: String, arguments: String) -> Bool {
        lock.lock()
        let handler = onApproval
        let approved = autoApprove
        lock.unlock()
        // `--yes` short-circuits the prompt entirely.
        if approved { return true }
        // With no handler installed (piping, scripting) mutating tools are
        // refused unless the caller opted in above.
        guard let handler else { return false }
        return handler(name, arguments)
    }
}

/// Why a turn failed, in terms an interface can act on.
enum AgentFailure: LocalizedError {
    case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)
    case contextOverflow(tokens: Int, limit: Int)
    case guardrailsExhausted(attempts: Int, underlying: String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                "This Mac does not support Apple Intelligence, so the on-device model is unavailable."
            case .appleIntelligenceNotEnabled:
                "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
            case .modelNotReady:
                "The on-device model is still preparing. Try again in a few minutes."
            @unknown default:
                "The on-device model is unavailable."
            }

        case .contextOverflow(let tokens, let limit):
            """
            This conversation no longer fits the model's \(limit)-token context \
            window (\(tokens) tokens used). Start a new session with /new.
            """

        case .guardrailsExhausted(let attempts, let underlying):
            """
            The model blocked this request \(attempts) times in a row. On the \
            on-device model that is often a false positive — rephrase, or start a \
            new session. Last error: \(underlying)
            """

        case .other(let message):
            message
        }
    }
}

/// Owns the model session and the agentic loop.
///
/// Tool calling is the real thing: the framework parses the model's tool choice,
/// validates arguments against the declared schema, runs `call(arguments:)`, and
/// feeds the result back, looping until the model produces a final answer. There
/// is no prompt-and-parse emulation.
actor Agent {
    private let model = SystemLanguageModel.default
    private let sink: ToolEventSink
    private let instructions: String

    /// Every tool the caller handed in, whether currently enabled or not.
    private let definitions: [AnyAssistantTool]
    /// Tools the model is *not* shown. The model can only call what it can see,
    /// so disabling a tool removes it from the schema entirely (and from the
    /// per-turn token cost) rather than asking the model to ignore it.
    private var disabled: Set<String>
    private var bridgedTools: [any Tool]
    private var session: LanguageModelSession

    /// Retries for a turn the model refuses. Guardrail blocks are frequently
    /// non-deterministic on-device, so one retry often succeeds.
    private let maxRetries = 2

    init(
        definitions: [AnyAssistantTool],
        instructions: String = Agent.defaultInstructions,
        disabled: Set<String> = [],
        sink: ToolEventSink = ToolEventSink()
    ) {
        self.instructions = instructions
        self.definitions = definitions
        self.disabled = disabled
        self.sink = sink
        let tools = definitions
            .filter { !disabled.contains($0.name) }
            .map { $0.bridge(sink) }
        self.bridgedTools = tools
        self.session = LanguageModelSession(tools: tools, instructions: Instructions(instructions))
    }

    init(
        tools: [AnyAssistantTool],
        instructions: String = Agent.defaultInstructions,
        disabled: Set<String> = []
    ) {
        self.init(definitions: tools, instructions: instructions, disabled: disabled)
    }

    var toolNames: [String] { definitions.map(\.name) }

    func describeTools() -> [(name: String, summary: String, mutating: Bool, enabled: Bool)] {
        definitions.map { ($0.name, $0.summary, $0.isMutating, !disabled.contains($0.name)) }
    }

    /// Show or hide one tool for the rest of the session. Hiding a tool removes
    /// it from the model's schema, so the model cannot call it and its tokens no
    /// longer count against the context window. Returns false for unknown names.
    @discardableResult
    func setTool(_ name: String, enabled: Bool) -> Bool {
        let known = Set(definitions.map(\.name))
        guard known.contains(name) else { return false }
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        rebuildSession()
        return true
    }

    /// Enable or disable every tool at once.
    func setAllTools(enabled: Bool) {
        disabled = enabled ? [] : Set(definitions.map(\.name))
        rebuildSession()
    }

    var enabledToolNames: [String] {
        definitions.map(\.name).filter { !disabled.contains($0) }
    }

    /// Rebuild the session around the current tool set while keeping the
    /// conversation. The transcript carries past tool calls; the framework reads
    /// enabled tool definitions per request, so a shrinking schema is fine.
    private func rebuildSession() {
        bridgedTools = definitions
            .filter { !disabled.contains($0.name) }
            .map { $0.bridge(sink) }
        session = LanguageModelSession(
            model: model,
            tools: bridgedTools,
            transcript: session.transcript
        )
    }


    func configure(
        onEvent: ToolEventSink.EventHandler?,
        onApproval: ToolEventSink.ApprovalHandler?,
        autoApprove: Bool = false
    ) {
        sink.configure(onEvent: onEvent, onApproval: onApproval, autoApprove: autoApprove)
    }

    var contextSize: Int { model.contextSize }

    var availability: SystemLanguageModel.Availability { model.availability }

    /// Tokens the conversation occupies, plus the tool schemas the model carries
    /// on every turn.
    func usedTokens() async -> Int {
        let conversation = (try? await model.tokenCount(for: session.transcript)) ?? 0
        let schemas = (try? await model.tokenCount(for: bridgedTools)) ?? 0
        return conversation + schemas
    }

    func reset() {
        session = LanguageModelSession(tools: bridgedTools, instructions: Instructions(instructions))
    }

    /// One turn. Streams assistant text through `onText`, returns the final answer.
    func send(
        _ prompt: String,
        onText: @Sendable (String) -> Void
    ) async throws -> String {
        // Classify overflow *before* asking the model. On this build an over-long
        // request surfaces as `.guardrailViolation` ("May contain unsafe
        // content"), not `.contextSizeExceeded`, so a naive retry loop would
        // retry pointlessly and then report a misleading safety error.
        let limit = model.contextSize
        let used = await usedTokens()
        let incoming = (try? await model.tokenCount(for: prompt)) ?? 0
        if used + incoming > limit {
            throw AgentFailure.contextOverflow(tokens: used + incoming, limit: limit)
        }

        var attempt = 0
        var lastBlock: String?

        while attempt <= maxRetries {
            do {
                return try await stream(prompt: prompt, onText: onText)
            } catch let error as LanguageModelError {
                switch error {
                case .contextSizeExceeded(let details):
                    throw AgentFailure.contextOverflow(
                        tokens: details.tokenCount,
                        limit: details.contextSize
                    )

                case .guardrailViolation, .rateLimited, .timeout:
                    lastBlock = String(describing: error)
                    attempt += 1
                    guard attempt <= maxRetries else { break }
                    sink.emit(.modelRetry(attempt: attempt, reason: "guardrail or rate limit"))
                    try? await Task.sleep(for: .milliseconds(300 * attempt))
                    continue

                default:
                    throw AgentFailure.other(error.localizedDescription)
                }
            } catch let failure as AgentFailure {
                throw failure
            } catch {
                throw AgentFailure.other(error.localizedDescription)
            }
        }

        throw AgentFailure.guardrailsExhausted(
            attempts: maxRetries + 1,
            underlying: lastBlock ?? "unknown"
        )
    }

    private func stream(
        prompt: String,
        onText: @Sendable (String) -> Void
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt)
        var printed = ""
        var final = ""

        for try await snapshot in stream {
            let text = snapshot.content
            if text.hasPrefix(printed) {
                let delta = String(text.dropFirst(printed.count))
                if !delta.isEmpty { onText(delta) }
            } else {
                // The snapshot rewrote earlier text; surface it whole. A rich UI
                // should re-render from the full snapshot instead.
                onText(text)
            }
            printed = text
            final = text
        }
        return final
    }

    static let defaultInstructions = """
    You are Marlo, a concise on-device assistant running locally on the user's Mac.
    Call the available tools whenever they give a more accurate answer than your
    own knowledge — the current time, weather, or anything the user asked you to
    remember.

    If no tool fits a question, answer from your own knowledge and say when you are
    unsure. Never claim to have done something you did not do. If a tool returns an
    error, either correct your arguments and try once more, or tell the user plainly.
    Keep answers short and direct.
    """
}
