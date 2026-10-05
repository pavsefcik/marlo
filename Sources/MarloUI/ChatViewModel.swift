import Foundation
import FoundationModels
import MarloKit
import SwiftUI

/// One rendered tool call in a conversation.
struct ToolRun: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var arguments: String
    var result: String?

    var failed: Bool { result?.hasPrefix("error:") ?? false }
    var isRunning: Bool { result == nil }

    /// Pretty-printed arguments, so the card is legible without reading raw JSON.
    var prettyArguments: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: pretty, encoding: .utf8)
        else { return arguments }
        return text
    }

    var resultPreview: String {
        guard let result else { return "" }
        let oneLine = result.replacingOccurrences(of: "\n", with: " · ")
        return oneLine.count > 300 ? String(oneLine.prefix(300)) + "…" : oneLine
    }
}

struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var tools: [ToolRun] = []
}

/// A tool call suspended on the user's decision.
struct PendingApproval: Identifiable, Sendable {
    let id = UUID()
    var toolName: String
    var arguments: String

    var prettyArguments: String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: pretty, encoding: .utf8)
        else { return arguments }
        return text
    }
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
    var streamingTools: [ToolRun] = []
    var errorMessage: String?
    var pendingApproval: PendingApproval?
    var status: String?

    var isAvailable = true
    var unavailableReason: String?
    var autoApprove = false

    var usedTokens = 0
    var contextLimit = 8192
    private(set) var tools: [ToolDescriptor] = []

    /// Tools that reach the network, so the UI can offer one switch.
    /// `nonisolated` so the nested `ToolDescriptor` can consult it.
    nonisolated static let networkTools: Set<String> = [
        "getWeather", "wikipediaSummary", "convertCurrency", "getCryptoPrice",
        "airQuality", "sunriseSunset", "recentEarthquakes",
        "upcomingPublicHolidays", "liveAirTraffic",
    ]

    struct ToolDescriptor: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var summary: String
        var mutating: Bool
        var enabled: Bool
        var isNetwork: Bool { ChatViewModel.networkTools.contains(name) }
    }

    // MARK: Internals

    private let agent: Agent
    private var turnTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    init() {
        let memory = MemoryStore()
        let all: [AnyAssistantTool] = [
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
        self.agent = Agent(tools: all)
    }

    /// Wire callbacks, check availability, load tools. Call once on appear.
    func start() async {
        await agent.configure(
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            },
            onApproval: { [weak self] name, arguments in
                guard let self else { return false }
                return await self.requestApproval(name: name, arguments: arguments)
            }
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
        await reloadTools()
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
        streamingTools = []
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
            messages.append(
                ChatMessage(role: .assistant, text: streamingText, tools: streamingTools)
            )
        }
        streamingText = ""
        streamingTools = []
        isResponding = false
        status = nil
        // A cancelled turn may leave a tool awaiting an answer.
        resolveApproval(false)
    }

    func newConversation() {
        turnTask?.cancel()
        turnTask = nil
        Task {
            await agent.reset()
            messages = []
            streamingText = ""
            streamingTools = []
            errorMessage = nil
            isResponding = false
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        usedTokens = await agent.usedTokens()
    }

    var contextFraction: Double {
        guard contextLimit > 0 else { return 0 }
        return min(1, Double(usedTokens) / Double(contextLimit))
    }

    // MARK: Agent events

    private func handle(_ event: AgentEvent) {
        switch event {
        case .toolStarted(let name, let arguments):
            streamingTools.append(ToolRun(name: name, arguments: arguments))

        case .toolFinished(let name, let result):
            if let index = streamingTools.lastIndex(where: { $0.name == name && $0.result == nil }) {
                streamingTools[index].result = result
            }

        case .modelRetry(let attempt, let reason):
            status = "Retrying (\(attempt)) after \(reason)…"
        }
    }

    // MARK: Approval

    private func requestApproval(name: String, arguments: String) async -> Bool {
        if autoApprove { return true }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = PendingApproval(toolName: name, arguments: arguments)
        }
    }

    func resolveApproval(_ approved: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
    }

    // MARK: Tools

    private func reloadTools() async {
        tools = await agent.describeTools().map {
            ToolDescriptor(name: $0.name, summary: $0.summary, mutating: $0.mutating, enabled: $0.enabled)
        }
    }

    func toggleTool(_ name: String, enabled: Bool) {
        Task {
            await agent.setTool(name, enabled: enabled)
            await reloadTools()
            await refreshTokens()
        }
    }

    func setNetworkTools(enabled: Bool) {
        Task {
            for name in Self.networkTools {
                await agent.setTool(name, enabled: enabled)
            }
            await reloadTools()
            await refreshTokens()
        }
    }

    var networkEnabled: Bool {
        tools.contains { $0.isNetwork && $0.enabled }
    }
}
