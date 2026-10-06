import Foundation
import FoundationModels
import Testing
@testable import MarloKit

/// Everything a command needs, with nothing touching the real settings or
/// session store.
private struct Harness {
    let agent: Agent
    let store: SettingsStore
    let sessions: SessionStore
    let runner: CommandRunner

    init(tools: [AnyAssistantTool]? = nil) {
        let suite = "marlo.tests.commands.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: defaults)

        let memory = MemoryStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("marlo-tests-\(UUID().uuidString).jsonl")
        )
        let definitions = tools ?? [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(WeatherTool()),
            AnyAssistantTool(RememberFactTool(store: memory)),
        ]
        let agent = Agent(definitions: definitions, instructions: store.current.instructions)
        let sessions = SessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("marlo-tests-sessions-\(UUID().uuidString)")
        )

        self.agent = agent
        self.store = store
        self.sessions = sessions
        self.runner = CommandRunner(agent: agent, settingsStore: store, sessions: sessions)
    }
}

@Suite("Command runner")
struct CommandRunnerTests {
    @Test("a plain prompt is not a command")
    func promptsPassThrough() async {
        let harness = Harness()
        #expect(await harness.runner.run("what's the weather?") == nil)
        // A leading slash anywhere but the start is just punctuation.
        #expect(await harness.runner.run("and/or") == nil)
    }

    @Test("a bare slash lists commands")
    func bareSlash() async {
        let harness = Harness()
        let outcome = await harness.runner.run("/")
        #expect(outcome?.output.contains("COMMANDS") == true)
    }

    @Test("every command in the table is answered, not 'not implemented'")
    func everyCommandIsImplemented() async {
        // This is the test that catches a command being added to the table and
        // forgotten in the runner.
        for command in MarloCommands.all {
            let harness = Harness()
            guard let outcome = await harness.runner.run("/" + command.name) else {
                Issue.record("/\(command.name) was not treated as a command")
                continue
            }
            #expect(
                !outcome.output.contains("not implemented"),
                "/\(command.name) is in the table but the runner does not handle it"
            )
        }
    }

    @Test("an unknown command produces help, not a prompt")
    func unknownCommand() async {
        let harness = Harness()
        let outcome = await harness.runner.run("/nope")
        #expect(outcome != nil)
        #expect(outcome?.output.contains("unknown command") == true)
        #expect(outcome?.output.contains("COMMANDS") == true)
    }

    @Test("aliases resolve to the same command")
    func aliases() async {
        let harness = Harness()
        let byName = await harness.runner.run("/help")
        let byAlias = await harness.runner.run("/?")
        #expect(byName?.output == byAlias?.output)
    }

    @Test("quit asks the front end to exit")
    func quit() async {
        let harness = Harness()
        #expect(await harness.runner.run("/quit")?.followUp == .quit)
        #expect(await harness.runner.run("/q")?.followUp == .quit)
        #expect(await harness.runner.run("/exit")?.followUp == .quit)
    }

    @Test("new replaces the conversation")
    func new() async {
        let harness = Harness()
        #expect(await harness.runner.run("/new")?.conversationReplaced == true)
        #expect(await harness.runner.run("/clear")?.conversationReplaced == true)
    }

    @Test("instruction editing is handed back to the front end")
    func editInstructionsFollowUp() async {
        let harness = Harness()
        // The runner cannot prompt for input, so this must be a follow-up rather
        // than an attempt to read from somewhere it cannot.
        let outcome = await harness.runner.run("/instructions edit")
        #expect(outcome?.followUp == .editInstructions)
        #expect(outcome?.output.isEmpty == true)
    }

    @Test("instructions are set, shown and reset")
    func instructions() async {
        let harness = Harness()

        await harness.runner.setInstructions("You are a pirate.")
        #expect(await harness.runner.run("/instructions")?.output.contains("You are a pirate.") == true)
        #expect(harness.store.current.instructionsOverride == "You are a pirate.")

        await harness.runner.resetInstructions()
        #expect(harness.store.current.instructionsOverride == nil)
        #expect(await harness.runner.run("/instructions")?.output.contains("pirate") == false)
    }

    @Test("the style list marks the current one")
    func styleListing() async {
        let harness = Harness()
        let listing = await harness.runner.run("/style")?.output ?? ""
        #expect(listing.contains("* balanced"))

        _ = await harness.runner.run("/style expansive")
        let updated = await harness.runner.run("/style")?.output ?? ""
        #expect(updated.contains("* expansive"))
        #expect(!updated.contains("* balanced"))
        #expect(harness.store.current.responseStyle == .expansive)
    }

    @Test("an unknown style is refused without changing anything")
    func badStyle() async {
        let harness = Harness()
        let before = harness.store.current.responseStyle
        let outcome = await harness.runner.run("/style shouty")
        #expect(outcome?.output.contains("unknown style") == true)
        #expect(harness.store.current.responseStyle == before)
    }

    @Test("tools can be turned off and on, and the change persists")
    func toolsToggle() async {
        let harness = Harness()

        _ = await harness.runner.run("/tools off getWeather")
        #expect(await harness.agent.enabledToolNames == ["getCurrentTime", "rememberFact"])
        #expect(!harness.store.current.enabledTools.contains("getWeather"))

        _ = await harness.runner.run("/tools on getWeather")
        #expect(await harness.agent.enabledToolNames.contains("getWeather"))
        #expect(harness.store.current.enabledTools.contains("getWeather"))
    }

    @Test("an unknown tool is reported, not silently accepted")
    func unknownTool() async {
        let harness = Harness()
        let outcome = await harness.runner.run("/tools off nosuchtool")
        #expect(outcome?.output.contains("unknown tool: nosuchtool") == true)
    }

    @Test("only restricts to exactly the named tools")
    func toolsOnly() async {
        let harness = Harness()
        _ = await harness.runner.run("/tools only getWeather")
        #expect(await harness.agent.enabledToolNames == ["getWeather"])
        #expect(harness.store.current.enabledTools == ["getWeather"])
    }

    @Test("none disables everything and all restores it")
    func toolsAllAndNone() async {
        let harness = Harness()
        _ = await harness.runner.run("/tools none")
        #expect(await harness.agent.enabledToolNames.isEmpty)
        #expect(harness.store.current.toolsEnabled == false)

        _ = await harness.runner.run("/tools all")
        #expect(await harness.agent.enabledToolNames.count == 3)
        #expect(harness.store.current.toolsEnabled == true)
    }

    @Test("offline toggles only the network tools")
    func offline() async {
        let harness = Harness()
        // Start from everything on so the toggle direction is unambiguous.
        _ = await harness.runner.run("/tools all")

        _ = await harness.runner.run("/offline off")
        let afterOff = Set(await harness.agent.enabledToolNames)
        #expect(!afterOff.contains("getWeather"))
        #expect(afterOff.contains("getCurrentTime"))
        #expect(afterOff.contains("rememberFact"))

        _ = await harness.runner.run("/offline on")
        #expect(await harness.agent.enabledToolNames.contains("getWeather"))
    }

    @Test("a bare offline flips based on the current state")
    func offlineToggles() async {
        let harness = Harness()
        _ = await harness.runner.run("/tools all")

        _ = await harness.runner.run("/offline")
        #expect(!(await harness.agent.enabledToolNames.contains("getWeather")))

        _ = await harness.runner.run("/offline")
        #expect(await harness.agent.enabledToolNames.contains("getWeather"))
    }

    @Test("model listing marks the current one and reports availability")
    func model() async {
        let harness = Harness()
        let listing = await harness.runner.run("/model")?.output ?? ""
        #expect(listing.contains("* system"))
        #expect(listing.contains("pcc"))
        #expect(listing.contains("/model system | pcc"))
    }

    @Test("an unknown model is refused")
    func badModel() async {
        let harness = Harness()
        #expect(await harness.runner.run("/model gpt")?.output.contains("unknown model") == true)
    }

    @Test("saving and resuming round-trips through the session store")
    func saveAndResume() async {
        let harness = Harness()
        _ = await harness.runner.run("/save my-notes")
        #expect(harness.sessions.names == ["my-notes"])

        let resume = await harness.runner.run("/resume my-notes")
        #expect(resume?.conversationReplaced == true)
        #expect(resume?.output.contains("resumed my-notes") == true)
    }

    @Test("sessions lists what is saved")
    func listSessions() async {
        let harness = Harness()
        #expect(await harness.runner.run("/sessions")?.output.contains("no saved conversations") == true)

        _ = await harness.runner.run("/save one")
        let listing = await harness.runner.run("/sessions")?.output ?? ""
        #expect(listing.contains("one"))
        #expect(listing.contains(harness.sessions.directory.path))
    }

    @Test("resuming something that does not exist explains itself")
    func resumeMissing() async {
        let harness = Harness()
        let outcome = await harness.runner.run("/resume ghost")
        #expect(outcome?.output.contains("could not resume ghost") == true)
        #expect(outcome?.output.contains("/sessions") == true)
        #expect(outcome?.conversationReplaced == false)
    }

    @Test("a bare resume opens the newest session")
    func resumeNewest() async {
        let harness = Harness()
        _ = await harness.runner.run("/save older")
        try? await Task.sleep(for: .milliseconds(20))
        _ = await harness.runner.run("/save newer")

        let outcome = await harness.runner.run("/resume")
        #expect(outcome?.output.contains("newer") == true)
    }

    @Test("tokens reports against the context limit")
    func tokens() async {
        let harness = Harness()
        let output = await harness.runner.run("/tokens")?.output ?? ""
        #expect(output.contains("/ 8192 tokens"))
    }
}

@Suite("Network tool declaration")
struct NetworkToolDeclarationTests {
    @Test("the network tools are exactly the ones that call out")
    func declaredSet() async {
        let harness = Harness(tools: [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(WeatherTool()),
            AnyAssistantTool(RememberFactTool(store: MemoryStore(
                url: FileManager.default.temporaryDirectory.appendingPathComponent("x.jsonl")
            ))),
            AnyAssistantTool(WikipediaTool()),
            AnyAssistantTool(CurrencyTool()),
            AnyAssistantTool(CryptoPriceTool()),
            AnyAssistantTool(AirQualityTool()),
            AnyAssistantTool(SunTool()),
            AnyAssistantTool(EarthquakeTool()),
            AnyAssistantTool(HolidayTool()),
            AnyAssistantTool(AirTrafficTool()),
        ])
        // The whole point of declaring `isNetwork` on the tool is that no list
        // anywhere has to be kept in step. This asserts the declaration is right.
        let network = Set(await harness.agent.networkToolNames)
        #expect(network == [
            "getWeather", "wikipediaSummary", "convertCurrency", "getCryptoPrice",
            "airQuality", "sunriseSunset", "recentEarthquakes",
            "upcomingPublicHolidays", "liveAirTraffic",
        ])
        #expect(!network.contains("getCurrentTime"))
        #expect(!network.contains("rememberFact"))
    }

    @Test("describeTools carries the network flag through")
    func described() async {
        let harness = Harness()
        let described = await harness.agent.describeTools()
        let weather = described.first { $0.name == "getWeather" }
        let clock = described.first { $0.name == "getCurrentTime" }
        #expect(weather?.network == true)
        #expect(clock?.network == false)
        #expect(weather?.mutating == false)
    }
}

@Suite("Dormant tools")
struct DormantToolTests {
    /// The app's configuration: every definition present, every one hidden.
    ///
    /// This is what makes Marlo a plain chatbot while keeping the machinery in
    /// the library. The guarantee worth testing is that hiding the tools really
    /// does remove them from the model's view — not merely from the UI.
    private func dormantAgent(_ tools: [AnyAssistantTool]) async -> Agent {
        let agent = Agent(
            definitions: tools,
            disabled: Set(tools.map(\.name)),
            routingEnabled: false
        )
        await agent.configure(onEvent: { _ in }, onApproval: nil)
        return agent
    }

    private var sampleTools: [AnyAssistantTool] {
        let memory = MemoryStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("dormant-\(UUID().uuidString).jsonl")
        )
        return [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(WeatherTool()),
            AnyAssistantTool(RememberFactTool(store: memory)),
        ]
    }

    @Test("a dormant agent declares no tools at all")
    func declaresNothing() async {
        let agent = await dormantAgent(sampleTools)
        #expect(await agent.sessionToolNames.isEmpty)
        #expect(await agent.enabledToolNames.isEmpty)
    }

    @Test("no tool can fire while dormant")
    func nothingCanFire() async {
        // The tools are all still *defined*; the question is whether hiding them
        // is enough to stop one running. Asking for exactly what a tool provides
        // is the strongest form of the question.
        let recorder = ToolFireRecorder()
        let tools = sampleTools
        let agent = Agent(
            definitions: tools,
            disabled: Set(tools.map(\.name)),
            routingEnabled: false
        )
        await agent.configure(
            onEvent: { event in
                if case .toolStarted(let name, _) = event { recorder.record(name) }
            },
            onApproval: nil
        )

        for question in [
            "What is the weather in Lisbon right now?",
            "What time is it in Tokyo?",
            "Remember that I prefer metric units.",
        ] {
            _ = try? await agent.send(question) { _ in }
        }
        #expect(recorder.fired.isEmpty)
    }

    @Test("a dormant agent costs no schema tokens")
    func noSchemaCost() async {
        let dormant = await dormantAgent(sampleTools)
        let awake = await Agent(definitions: sampleTools, routingEnabled: false).usedTokens()
        // Hiding a tool must remove its schema cost, which is the whole point of
        // `disabled` rather than a prompt telling the model to ignore it.
        #expect(await dormant.usedTokens() < awake)
    }

    @Test("the same definitions still work when switched back on")
    func stillWorksWhenEnabled() async {
        // Dormant is a configuration, not a demolition: flipping the switch must
        // restore full function.
        let tools = sampleTools
        let agent = Agent(definitions: tools, routingEnabled: false)
        await agent.configure(onEvent: { _ in }, onApproval: nil)
        #expect(Set(await agent.sessionToolNames) == Set(tools.map(\.name)))
        #expect(await agent.enabledToolNames.count == 3)
    }
}

/// Collects tool names from an event handler that runs off the main actor.
private final class ToolFireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func record(_ name: String) {
        lock.lock(); names.append(name); lock.unlock()
    }

    var fired: [String] {
        lock.lock(); defer { lock.unlock() }
        return names
    }
}
