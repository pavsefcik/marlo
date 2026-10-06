import Foundation
import FoundationModels
import MarloKit
import SwiftUI

struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
}

@MainActor
@Observable
final class ChatViewModel {
    // MARK: Observable state

    var messages: [ChatMessage] = []
    var draft = ""
    var isResponding = false
    /// Complete text of the in-flight answer. Always *replaced*, never appended.
    var streamingText = ""
    var errorMessage: String?
    var status: String?

    var isAvailable = true
    var unavailableReason: String?

    /// Persisted preferences shared with the CLI.
    var settings: MarloSettings
    private let settingsStore: SettingsStore

    var usedTokens = 0
    var contextLimit = 8192

    // MARK: Internals

    private let agent: Agent
    private var turnTask: Task<Void, Never>?

    /// Every tool the library ships.
    ///
    /// Listed rather than omitted so the wiring below is a single visible
    /// decision. Marlo in the app is a local chatbot: it answers from the model
    /// and nothing else. The tools, the router, the command runner and the
    /// session store are all still in `MarloKit`, still built and still covered
    /// by its tests — the app simply does not offer them. To bring them back,
    /// stop hiding the definitions and drop the two `false`s in `init`.
    private static let allTools: [AnyAssistantTool] = {
        let memory = MemoryStore()
        return [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(RememberFactTool(store: memory)),
            AnyAssistantTool(RecallMemoryTool(store: memory)),
            AnyAssistantTool(WeatherTool()),
            AnyAssistantTool(WikipediaTool()),
            AnyAssistantTool(CurrencyTool()),
            AnyAssistantTool(CryptoPriceTool()),
            AnyAssistantTool(AirQualityTool()),
            AnyAssistantTool(SunTool()),
            AnyAssistantTool(EarthquakeTool()),
            AnyAssistantTool(HolidayTool()),
            AnyAssistantTool(AirTrafficTool()),
        ]
    }()

    init() {
        let store = SettingsStore()
        let settings = store.current
        self.settingsStore = store
        self.settings = settings

        let definitions = Self.allTools
        self.agent = Agent(
            definitions: definitions,
            instructions: settings.instructions,
            // Dormant: hiding every definition means none is declared to the
            // model, so no tool can be called and none costs context.
            disabled: Set(definitions.map(\.name)),
            routingEnabled: false,
            routingThreshold: settings.routingThreshold,
            styleInstruction: settings.responseStyle.instruction,
            model: settings.model
        )
    }

    /// Check availability and prime the token meter. Call once on appear.
    func start() async {
        // No approval handler: with every tool hidden nothing can run, and an
        // unset handler refuses by default rather than silently allowing.
        await agent.configure(
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            },
            onApproval: nil
        )

        switch await agent.availability {
        case .available:
            isAvailable = true
        case .unavailable(let reason):
            isAvailable = false
            unavailableReason = AgentFailure.modelUnavailable(reason).localizedDescription
        @unknown default:
            isAvailable = false
            unavailableReason = "The on-device model is unavailable."
        }

        contextLimit = await agent.contextSize
        await refreshTokens()
    }

    // MARK: Conversation

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }

        draft = ""
        errorMessage = nil
        status = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        streamingText = ""
        isResponding = true

        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.agent.send(prompt) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.streamingText = snapshot.text
                    }
                }
                await self.finishTurn()
            } catch is CancellationError {
                await self.finishTurn()
            } catch {
                self.errorMessage = error.localizedDescription
                await self.finishTurn()
            }
            await self.refreshTokens()
        }
    }

    /// Ends the turn, keeping whatever text already streamed in.
    func stop() {
        turnTask?.cancel()
        turnTask = nil
        Task { await finishTurn() }
    }

    private func finishTurn() async {
        if !streamingText.isEmpty {
            messages.append(ChatMessage(role: .assistant, text: streamingText))
        }
        streamingText = ""
        isResponding = false
        status = nil
    }

    func newConversation() {
        turnTask?.cancel()
        turnTask = nil
        Task {
            await agent.reset()
            messages = []
            streamingText = ""
            errorMessage = nil
            isResponding = false
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        usedTokens = await agent.reportedTokens()
        contextLimit = await agent.contextSize
    }

    var contextFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(usedTokens) / Double(contextLimit))
    }

    /// Whether the conversation can be cleared.
    var hasConversation: Bool {
        !messages.isEmpty || !streamingText.isEmpty
    }

    func setResponseStyle(_ style: ResponseStyle) {
        Task {
            var settings = settings
            settings.responseStyle = style
            self.settings = settings
            settingsStore.update(settings)
            await agent.apply(settings: settings)
            await refreshTokens()
        }
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        // Only retries can surface with no tools configured. The tool and
        // routing cases are handled by the CLI, which does offer them.
        switch event {
        case .modelRetry(let attempt, let reason):
            status = "Retrying (\(attempt)) after \(reason)…"
        case .toolStarted, .toolFinished, .routing:
            break
        }
    }
}
