import Foundation
import FoundationModels

/// Anything the assistant does that an interface may want to show, log, or gate.
public enum AgentEvent: Sendable {
    case toolStarted(name: String, arguments: String)
    case toolFinished(name: String, result: String)
    case modelRetry(attempt: Int, reason: String)
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

    public init(
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

    public init(
        tools: [AnyAssistantTool],
        instructions: String = Agent.defaultInstructions,
        disabled: Set<String> = []
    ) {
        self.init(definitions: tools, instructions: instructions, disabled: disabled)
    }

    public var toolNames: [String] { definitions.map(\.name) }

    public func describeTools() -> [(name: String, summary: String, mutating: Bool, enabled: Bool)] {
        definitions.map { ($0.name, $0.summary, $0.isMutating, !disabled.contains($0.name)) }
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

    public var enabledToolNames: [String] {
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


    public func configure(
        onEvent: ToolEventSink.EventHandler?,
        onApproval: ToolEventSink.ApprovalHandler?,
        autoApprove: Bool = false
    ) {
        sink.configure(onEvent: onEvent, onApproval: onApproval, autoApprove: autoApprove)
    }

    public var contextSize: Int { model.contextSize }

    public var availability: SystemLanguageModel.Availability { model.availability }

    /// Tokens the conversation occupies, plus the tool schemas the model carries
    /// on every turn.
    public func usedTokens() async -> Int {
        let conversation = (try? await model.tokenCount(for: session.transcript)) ?? 0
        let schemas = (try? await model.tokenCount(for: bridgedTools)) ?? 0
        return conversation + schemas
    }

    public func reset() {
        session = LanguageModelSession(tools: bridgedTools, instructions: Instructions(instructions))
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
                return try await stream(prompt: prompt, onSnapshot: onSnapshot)
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
