import Foundation
import FoundationModels

/// Anything the assistant does that an interface may want to show, log, or gate.
public enum AgentEvent: Sendable {
    case toolStarted(name: String, arguments: String)
    case toolFinished(name: String, result: String)
    case modelRetry(attempt: Int, reason: String)
    /// The tool selection step chose the named tools for this turn. Reported
    /// whether or not any were chosen, so a UI can show that routing happened.
    case routing(chosen: [String], fallback: Bool)
}

/// One update from the model while it is producing an answer.
///
/// `text` is the **complete** response so far, not a delta. Callers must replace
/// whatever they were showing with this value rather than appending, because the
/// model can revise text it already emitted: a reasoning trace can be dropped
/// once the answer is settled, and a partially-typed word can be completed
/// differently. Appending deltas therefore produces corrupted output that no
/// amount of terminal cleverness fully repairs.
public struct ResponseSnapshot: Sendable {
    /// The full response text produced so far.
    public var text: String
    /// True when this update changes text that was already emitted, rather than
    /// extending it. Purely informational: replacing the rendered text is always
    /// correct, and a terminal (which cannot un-print) may want to know so it can
    /// start a fresh line instead of gluing a revision onto the old one.
    public var isRewrite: Bool

    public static let empty = ResponseSnapshot(text: "", isRewrite: false)
}

/// Bridges snapshot updates to something that can only append — a terminal.
///
/// A view should render `snapshot.text` directly. This exists for stream
/// consumers that have already painted the previous text and cannot take it
/// back, so it prints the smallest sane thing: the extension for an append, and
/// the whole text on a fresh line for a rewrite.
public final class AppendOnlyRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var printed = ""
    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    public func render(_ snapshot: ResponseSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        if snapshot.isRewrite {
            // A terminal cannot un-print earlier output. Reprint the revision on
            // its own line rather than splicing it into what is already shown.
            write("\n" + snapshot.text)
        } else if snapshot.text.count > printed.count {
            write(String(snapshot.text.dropFirst(printed.count)))
        }
        printed = snapshot.text
    }
}

/// Bridges one `AssistantTool` into a framework `Tool`.
/// (`BridgedTool` and `AnyAssistantTool` live in AssistantTool.swift.)

/// Callbacks an interface installs. A reference type so tools can report while
/// the owning `Agent` actor stays isolated.
public final class ToolEventSink: @unchecked Sendable {
    public init() {}

    public typealias EventHandler = @Sendable (AgentEvent) -> Void
    /// Approval is `async` on purpose. A UI cannot answer synchronously without
    /// blocking a thread (and anything that blocks inside the agent actor can
    /// deadlock it), so the decision is awaited instead.
    public typealias ApprovalHandler = @Sendable (_ name: String, _ arguments: String) async -> Bool

    private let lock = NSLock()
    private var onEvent: EventHandler?
    private var onApproval: ApprovalHandler?

    /// When true, mutating tools run without asking.
    private var autoApprove = false

    public func configure(
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

    /// The handler is copied out under the lock and awaited *after* releasing it:
    /// holding an `NSLock` across a suspension point is unsafe.
    func requestApproval(name: String, arguments: String) async -> Bool {
        let (handler, approved) = locked { ($0.onApproval, $0.autoApprove) }
        // `--yes` short-circuits the prompt entirely.
        if approved { return true }
        // With no handler installed (piping, scripting) mutating tools are
        // refused unless the caller opted in above.
        guard let handler else { return false }
        return await handler(name, arguments)
    }

    /// Read state without exposing the lock.
    private func locked<T>(_ body: (ToolEventSink) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// Why a turn failed, in terms an interface can act on.
public enum AgentFailure: LocalizedError {
    case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)
    case contextOverflow(tokens: Int, limit: Int)
    case guardrailsExhausted(attempts: Int, underlying: String)
    case other(String)

    public var errorDescription: String? {
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
public actor Agent {
    private let sink: ToolEventSink
    /// The base instructions, without the style clause. Mutable so
    /// `/instructions` can change it mid-conversation.
    private var instructions: String
    /// Which model sessions are built on.
    private var modelChoice: MarloModel

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

    /// Whether to pick tools with a cheap routing turn before answering. Set by
    /// the caller from `MarloSettings`.
    private var routingEnabled: Bool
    /// Enabled tools at or below which declaring all of them beats routing.
    private var routingThreshold: Int
    /// A style clause appended to the base instructions.
    private var styleInstruction: String

    public init(
        definitions: [AnyAssistantTool],
        instructions: String = Agent.defaultInstructions,
        disabled: Set<String> = [],
        routingEnabled: Bool = true,
        routingThreshold: Int = MarloSettings.minimumRoutingThreshold,
        styleInstruction: String = "",
        model: MarloModel = .system,
        sink: ToolEventSink = ToolEventSink()
    ) {
        self.instructions = instructions
        self.definitions = definitions
        self.disabled = disabled
        self.routingEnabled = routingEnabled
        self.routingThreshold = routingThreshold
        self.styleInstruction = styleInstruction
        self.modelChoice = model
        self.sink = sink
        let bridged = definitions
            .filter { !disabled.contains($0.name) }
            .map { $0.bridge(sink) }
        self.bridgedTools = bridged
        self.session = Self.makeSession(
            model: model,
            tools: bridged,
            history: Transcript(),
            instructions: Self.compose(instructions, styleInstruction)
        )
    }

    public init(
        tools: [AnyAssistantTool],
        instructions: String = Agent.defaultInstructions,
        disabled: Set<String> = []
    ) {
        self.init(definitions: tools, instructions: instructions, disabled: disabled)
    }

    /// Base instructions without the style clause, for `/instructions`.
    public var instructionsText: String { instructions }

    /// The base instructions with the style clause appended, if any.
    private static func compose(_ base: String, _ style: String) -> String {
        style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? base
            : base + "\n\n" + style
    }

    /// Update the routing and style preferences without disturbing the
    /// conversation.
    /// Update the preferences that a settings change should take effect for, at
    /// once and without disturbing the conversation.
    ///
    /// Instructions are deliberately *not* applied here. `--instructions` is a
    /// per-run override, and folding it back in from stored settings would make
    /// something like `/style` silently discard the flag the user passed. Use
    /// `setInstructions(_:)` and `resetInstructions()` for those.
    public func apply(settings: MarloSettings) {
        routingEnabled = settings.toolsEnabled
        routingThreshold = settings.routingThreshold
        styleInstruction = settings.responseStyle.instruction
        modelChoice = settings.model
        rebuildSession()
    }

    public var toolNames: [String] { definitions.map(\.name) }

    public func describeTools() -> [ToolDescription] {
        definitions.map {
            ToolDescription(
                name: $0.name,
                summary: $0.summary,
                mutating: $0.isMutating,
                network: $0.isNetwork,
                enabled: !disabled.contains($0.name)
            )
        }
    }

    /// Names of the tools that reach the network, for `/offline`.
    public var networkToolNames: [String] {
        definitions.filter(\.isNetwork).map(\.name)
    }

    /// Show or hide one tool for the rest of the session. Hiding a tool removes
    /// it from the model's schema, so the model cannot call it and its tokens no
    /// longer count against the context window. Returns false for unknown names.
    @discardableResult
    public func setTool(_ name: String, enabled: Bool) -> Bool {
        let known = Set(definitions.map(\.name))
        guard known.contains(name) else { return false }
        if enabled { disabled.remove(name) } else { disabled.insert(name) }
        rebuildSession()
        return true
    }

    /// Enable or disable every tool at once.
    public func setAllTools(enabled: Bool) {
        disabled = enabled ? [] : Set(definitions.map(\.name))
        rebuildSession()
    }

    public func setEnabledTools(_ names: Set<String>) {
        disabled = Set(definitions.map(\.name)).subtracting(names)
        rebuildSession()
    }

    public var enabledToolNames: [String] {
        definitions.map(\.name).filter { !disabled.contains($0) }
    }

    /// The tools actually declared to the model right now, read back from the
    /// session transcript rather than from the requested set. Exposed so tests
    /// can assert on the schema the model really sees.
    public var sessionToolNames: [String] {
        session.transcript.compactMap { entry -> [Transcript.ToolDefinition]? in
            guard case .instructions(let instructions) = entry else { return nil }
            return instructions.toolDefinitions
        }
        .flatMap { $0 }
        .map(\.name)
    }

    /// Rebuild the session around the current tool set while keeping the
    /// conversation.
    ///
    /// The transcript is *restricted* to the visible tools rather than carried
    /// over wholesale. The framework records each turn's live tool definitions
    /// in the transcript, so a plain `transcript:` rebuild would leave the model
    /// holding a definition it can no longer call — and it narrates a result for
    /// it instead of admitting the tool is gone. See `Transcript.restricted(to:)`.
    private func rebuildSession() {
        let names = enabledToolNames
        rebuildSession(visible: Set(names))
    }

    /// Rebuild around an explicit visible set. Used per turn when routing has
    /// narrowed the tools for this turn only.
    private func rebuildSession(visible: Set<String>) {
        bridgedTools = definitions
            .filter { visible.contains($0.name) }
            .map { $0.bridge(sink) }
        session = Self.makeSession(
            model: modelChoice,
            tools: bridgedTools,
            history: session.transcript,
            instructions: Self.compose(instructions, styleInstruction)
        )
    }

    /// Build a session for the given tools and instructions, fixing up the
    /// history to match.
    ///
    /// There is no `tools:transcript:instructions:` initializer, so the
    /// instructions entry is replaced by hand: drop the old one, prepend a fresh
    /// one carrying the current text and tool definitions, and restrict the rest
    /// of the history to the tools that are visible now. Without this, a session
    /// rebuilt with fewer tools still carries the definitions it used to have.
    private static func makeSession(
        model: MarloModel,
        tools: [any Tool],
        history: Transcript,
        instructions: String
    ) -> LanguageModelSession {
        let visible = Set(tools.map(\.name))
        let body = history.filter {
            if case .instructions = $0 { return false }
            return true
        }
        let instructionsEntry = Transcript.Entry.instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
        ))
        return LanguageModelSession(
            model: model.languageModel,
            tools: tools,
            transcript: Transcript(entries: [instructionsEntry] + Array(body.restricted(to: visible)))
        )
    }


    public func configure(
        onEvent: ToolEventSink.EventHandler?,
        onApproval: ToolEventSink.ApprovalHandler?,
        autoApprove: Bool = false
    ) {
        sink.configure(onEvent: onEvent, onApproval: onApproval, autoApprove: autoApprove)
    }

    /// Context size of the model in use.
    ///
    /// Async because the cloud model's context size is an `async throws`
    /// property. Both models report 8192 today, but this stays a lookup rather
    /// than a constant because that is a fact about the model, not about marlo.
    public var contextSize: Int {
        get async {
            switch modelChoice {
            case .system:
                SystemLanguageModel.default.contextSize
            case .pcc:
                (try? await PrivateCloudComputeLanguageModel().contextSize) ?? 0
            }
        }
    }

    /// Whether the on-device model can run at all. Distinct from
    /// `modelAvailability`, which is about the model currently selected.
    public var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    // MARK: Model and instructions

    public var model: MarloModel { modelChoice }

    /// Switch model, keeping the conversation. Returns the availability of the
    /// model switched to, so a caller can report honestly rather than assuming
    /// the switch worked.
    @discardableResult
    public func setModel(_ choice: MarloModel) -> MarloModel.ModelAvailability {
        modelChoice = choice
        rebuildSession()
        return choice.availability
    }

    /// The current instructions, style clause included, so `/instructions`
    /// shows exactly what the model is told.
    public var currentInstructions: String {
        Self.compose(instructions, styleInstruction)
    }

    /// Replace the base instructions. The style clause is still appended.
    public func setInstructions(_ text: String) {
        instructions = text
        rebuildSession()
    }

    /// Restore the built-in instructions.
    public func resetInstructions() {
        instructions = Agent.defaultInstructions
        rebuildSession()
    }

    /// Snapshot of the conversation, for saving to disk.
    public var transcript: Transcript { session.transcript }

    /// Replace the conversation, for resuming a saved session. Restricted to the
    /// tools visible now, so a saved transcript cannot reintroduce a tool that
    /// has since been turned off.
    public func setTranscript(_ transcript: Transcript) {
        let visible = Set(bridgedTools.map(\.name))
        session = Self.makeSession(
            model: modelChoice,
            tools: bridgedTools,
            history: transcript.restricted(to: visible),
            instructions: Self.compose(instructions, styleInstruction)
        )
        lastRequestTokens = nil
    }

    /// An estimate of what the next request will cost: the conversation plus the
    /// tool schemas the model carries on every turn.
    ///
    /// This is what to show before the first turn of a session. Once a turn has
    /// run, `lastRequestTokens` is the real number — the framework's own input
    /// count — and it runs around 15% higher than this estimate, because the
    /// schemas are framed into the request rather than appended to it.
    public func usedTokens() async -> Int {
        switch modelChoice {
        case .system:
            let model = SystemLanguageModel.default
            let conversation = (try? await model.tokenCount(for: session.transcript.map { $0 })) ?? 0
            let schemas = (try? await model.tokenCount(for: bridgedTools)) ?? 0
            return conversation + schemas
        case .pcc:
            // Private Cloud Compute exposes no token counter at all, so there is
            // no estimate to give. Last request's usage is the only real number.
            return lastRequestTokens ?? 0
        }
    }

    /// The exact input size the framework reported for the last completed turn,
    /// including reasoning. `nil` before the session has answered anything.
    public private(set) var lastRequestTokens: Int?

    /// The real cost of the last request. Falls back to the estimate when no
    /// turn has run yet, so a context meter can show one honest number.
    public func reportedTokens() async -> Int {
        if let lastRequestTokens { return lastRequestTokens }
        return await usedTokens()
    }

    public func reset() {
        session = Self.makeSession(
            model: modelChoice,
            tools: bridgedTools,
            history: Transcript(),
            instructions: Self.compose(instructions, styleInstruction)
        )
        lastRequestTokens = nil
    }

    /// One turn. Reports every snapshot through `onSnapshot` and returns the
    /// final answer text.
    ///
    /// `onSnapshot` receives the complete text so far, not a delta, so a view can
    /// render it directly. See `ResponseSnapshot` for why that matters.
    public func send(
        _ prompt: String,
        onSnapshot: @Sendable (ResponseSnapshot) -> Void
    ) async throws -> String {
        // Classify overflow *before* asking the model. On this build an over-long
        // request surfaces as `.guardrailViolation` ("May contain unsafe
        // content"), not `.contextSizeExceeded`, so a naive retry loop would
        // retry pointlessly and then report a misleading safety error.
        let limit = await contextSize
        let used = await usedTokens()
        // The cloud model exposes no token counter, so the pre-check is only
        // possible on-device. There it matters most: an over-long request
        // surfaces as a guardrail violation, which a retry loop would chase.
        if case .system = modelChoice {
            let incoming = (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? 0
            if used + incoming > limit {
                throw AgentFailure.contextOverflow(tokens: used + incoming, limit: limit)
            }
        }

        // Visibility for this turn is decided before the retry loop, so a retried
        // turn uses the same tools as the attempt it is retrying.
        rebuildSession(visible: await visibleToolsForThisTurn(prompt))
        return try await respondWithRetries(prompt: prompt, onSnapshot: onSnapshot)
    }

    /// Which tools the answer session should declare.
    ///
    /// No tools enabled, or tools switched off, means no tools and no routing
    /// turn at all. A tool count at or below the threshold declares everything:
    /// routing would cost a round-trip and save nothing. Above it, the router
    /// picks — and on any failure the safe answer is everything the user has
    /// enabled, never a silent guess.
    private func visibleToolsForThisTurn(_ prompt: String) async -> Set<String> {
        let enabled = Set(enabledToolNames)
        guard !enabled.isEmpty else { return [] }
        // Routing off, or few enough tools that declaring them all is cheaper
        // than a routing round-trip, means everything the user enabled.
        guard routingEnabled, enabled.count > routingThreshold else { return enabled }

        let candidates = definitions
            .filter { enabled.contains($0.name) }
            .map { (name: $0.name, summary: $0.summary) }

        // Routing runs on the on-device model only. It is a cheap classification
        // pass, and sending the whole tool list to the cloud model on every turn
        // to decide which tools not to send would defeat its purpose.
        guard case .system = modelChoice else { return enabled }

        let router = ToolRouter(model: SystemLanguageModel.default)
        let outcome = await router.decide(
            message: prompt,
            previousMessage: previousUserMessage(),
            candidates: candidates
        )

        switch outcome {
        case .chosen(let chosen):
            sink.emit(.routing(chosen: chosen.sorted(), fallback: false))
            return chosen
        case .none:
            sink.emit(.routing(chosen: [], fallback: false))
            return []
        case .unresolved(let reason):
            sink.emit(.routing(chosen: enabled.sorted(), fallback: true))
            sink.emit(.modelRetry(attempt: 0, reason: "tool selection unresolved: \(reason)"))
            return enabled
        }
    }

    /// The user's most recent message in this conversation, for routing context.
    private func previousUserMessage() -> String? {
        for entry in session.transcript.reversed() {
            guard case .prompt(let prompt) = entry else { continue }
            let text = prompt.segments
                .compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }
                .joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return nil
    }

    private func respondWithRetries(
        prompt: String,
        onSnapshot: @Sendable (ResponseSnapshot) -> Void
    ) async throws -> String {
        var attempt = 0
        var lastBlock: String?

        while attempt <= maxRetries {
            do {
                let answer = try await stream(prompt: prompt, onSnapshot: onSnapshot)
                lastRequestTokens = session.usage.input.totalTokenCount
                return answer
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
        onSnapshot: @Sendable (ResponseSnapshot) -> Void
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt)
        var previous = ""
        var final = ""

        for try await snapshot in stream {
            let text = snapshot.content
            // A snapshot either extends what came before or revises it. Report
            // the complete text either way; `isRewrite` is a hint for consumers
            // that cannot overwrite what they already displayed.
            let isRewrite = !text.hasPrefix(previous)
            onSnapshot(ResponseSnapshot(text: text, isRewrite: isRewrite))
            previous = text
            final = text
        }
        return final
    }

    public static let defaultInstructions = """
    You are Marlo, an assistant running locally on the user's Mac.

    Answer from your own knowledge whenever you can, and say so when you are not
    sure. Tools are available for facts you cannot know: the current time, live
    weather, or something the user asked you to remember. Reach for one when it
    gives a truer answer than your own knowledge, and otherwise just answer — do
    not use a tool merely because one exists.

    Never claim to have done something you did not do. If a tool returns an
    error, either correct your arguments and try once more, or tell the user
    plainly.
    """
}
