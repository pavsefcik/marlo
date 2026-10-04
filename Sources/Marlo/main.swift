import Foundation
import FoundationModels

// MARK: - Terminal helpers

let out = FileHandle.standardOutput
let err = FileHandle.standardError

func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}

/// Assistant text and answers go to stdout, so `marlo "…" > file` captures only
/// the answer. Tool activity, prompts and errors go to stderr.
func say(_ text: String) { write(text, to: out) }
func note(_ text: String) { write(text, to: err) }

let isInteractive = isatty(STDIN_FILENO) == 1

// MARK: - Argument parsing

struct Options {
    var prompt: String?
    var autoApprove = false
    var instructions: String?
    var showHelp = false
    var selfTest = false
    /// Tool names the model may call. `nil` means every tool.
    var onlyTools: [String]?
    /// Tool names to hide (applied after `onlyTools`).
    var withoutTools: [String] = []
    /// `--offline` hides every network-backed tool.
    var offline = false
    /// `--no-tools` disables every tool, so answers come from the model alone.
    var noTools = false
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var rest: [String] = []
    var index = 0

    while index < arguments.count {
        switch arguments[index] {
        case "-h", "--help":
            options.showHelp = true
        case "-y", "--yes":
            options.autoApprove = true
        case "--selftest":
            options.selfTest = true
        case "--offline":
            options.offline = true
        case "--no-tools":
            options.noTools = true
        case "--tools", "--only":
            index += 1
            if index < arguments.count {
                options.onlyTools = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        case "--without":
            index += 1
            if index < arguments.count {
                options.withoutTools += arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        case "-i", "--instructions":
            index += 1
            if index < arguments.count { options.instructions = arguments[index] }
        default:
            rest.append(arguments[index])
        }
        index += 1
    }

    if !rest.isEmpty { options.prompt = rest.joined(separator: " ") }
    return options
}

let options = parse(Array(CommandLine.arguments.dropFirst()))

func usage() -> String {
    """
    marlo — a local, on-device assistant (Apple Foundation Models)

    USAGE
      marlo                       interactive session
      marlo "question"            one-shot answer
      echo "question" | marlo     read the prompt from stdin

    OPTIONS
      -y, --yes                  auto-approve side-effecting tools
      -i, --instructions <text>  replace the default system instructions
      --offline                  hide every network-backed tool
      --no-tools                 hide every tool (answer from the model alone)
      --tools <a,b,c>            show only these tools (alias --only)
      --without <a,b,c>          hide these tools
      --selftest                 exercise every tool directly and report
      -h, --help                 show this help

    IN-SESSION COMMANDS
      /new     clear the conversation
      /tools   list tools and whether each is enabled
      /tools on|off <name>       enable/disable one tool
      /tools only <a,b>|all|none  restrict, enable, or disable every tool
      /offline [on|off]          toggle every network tool
      /tokens  show context usage
      /help    list commands
      /quit    exit

    EXAMPLES
      marlo --no-tools "explain photosynthesis"   answer from the model alone
      marlo --offline "what's a monad?"            keep time/memory, no network
      marlo --without wikipediaSummary "..."       keep every tool but Wikipedia
      marlo --tools getWeather,getCurrentTime "..."
    """
}

if options.showHelp {
    say(usage() + "\n")
    exit(0)
}

// MARK: - Tools

let memory = MemoryStore()

/// Tools that reach the network. `--offline` hides exactly these, so an offline
/// session can still use the clock and memory but nothing leaves the machine.
let networkToolNames: Set<String> = [
    "getWeather", "wikipediaSummary", "convertCurrency", "getCryptoPrice",
    "airQuality", "sunriseSunset", "recentEarthquakes",
    "upcomingPublicHolidays", "liveAirTraffic",
]

let tools: [AnyAssistantTool] = [
    // Local / offline
    AnyAssistantTool(CurrentTimeTool()),
    AnyAssistantTool(RememberFactTool(store: memory)),
    AnyAssistantTool(RecallMemoryTool(store: memory)),

    // Live data from keyless public APIs
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

let knownToolNames = Set(tools.map(\.name))

// Work out which tools start hidden: --offline, then --tools, then --without.
var initialDisabledTools = Set<String>()

if options.noTools {
    initialDisabledTools.formUnion(knownToolNames)
}

if options.offline {
    initialDisabledTools.formUnion(networkToolNames)
}

if let only = options.onlyTools {
    for name in knownToolNames where !only.contains(name) {
        initialDisabledTools.insert(name)
    }
    let unknown = only.filter { !knownToolNames.contains($0) }
    if !unknown.isEmpty {
        note("marlo: unknown tool(s) in --tools: \(unknown.joined(separator: ", "))\n")
    }
}

for name in options.withoutTools {
    if knownToolNames.contains(name) {
        initialDisabledTools.insert(name)
    } else {
        note("marlo: unknown tool in --without: \(name)\n")
    }
}

let agent = Agent(
    tools: tools,
    instructions: options.instructions ?? Agent.defaultInstructions,
    disabled: initialDisabledTools
)

// MARK: - Preflight

switch await agent.availability {
case .available:
    break
case .unavailable(let reason):
    note("marlo cannot start: \(AgentFailure.modelUnavailable(reason).localizedDescription)\n")
    exit(2)
@unknown default:
    note("marlo cannot start: the on-device model is unavailable.\n")
    exit(2)
}

// MARK: - Event plumbing

await agent.configure(
    onEvent: { event in
        switch event {
        case .toolStarted(let name, let arguments):
            note("\n  ▸ \(name) \(arguments)\n")
        case .toolFinished(let name, let result):
            let oneLine = result.replacingOccurrences(of: "\n", with: " ")
            let preview = oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
            note("  ✓ \(name) → \(preview)\n\n")
        case .modelRetry(let attempt, let reason):
            note("  ↻ retrying (\(attempt)) after \(reason)\n")
        }
    },
    onApproval: { name, arguments in
        // Non-interactive runs never run side-effecting tools unless -y was given.
        guard isInteractive else { return false }
        note("\n  ⚠︎ \(name) wants to run with \(arguments)\n  Approve? [y/N] ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        note("\n")
        return answer == "y" || answer == "yes"
    },
    autoApprove: options.autoApprove
)

// MARK: - A single turn

func respond(to prompt: String) async {
    do {
        let answer = try await agent.send(prompt) { delta in say(delta) }
        if !answer.isEmpty { say("\n") }
    } catch {
        note("\n  ✗ \(error.localizedDescription)\n")
    }
}

if options.selfTest {
    await runSelfTest()
    exit(0)
}

// MARK: - Self test

/// Calls every tool's implementation directly, bypassing the model. Catches the
/// class of failure that keeps appearing: a tool whose result gets swallowed by
/// a silent decode error and looks like missing data instead of a bug.
func runSelfTest() async {
    say("marlo selftest — calling every tool directly\n\n")

    var passed = 0
    var failed = 0

    func check(_ label: String, _ body: () async throws -> String) async {
        do {
            let result = try await body()
            let oneLine = result.replacingOccurrences(of: "\n", with: " · ")
            let preview = oneLine.count > 100 ? String(oneLine.prefix(100)) + "…" : oneLine
            if result.hasPrefix("error:") || result.contains("unexpected shape") {
                say("  ✗ \(label)\n      \(preview)\n")
                failed += 1
            } else {
                say("  ✓ \(label)\n      \(preview)\n")
                passed += 1
            }
        } catch {
            say("  ✗ \(label) — \(error.localizedDescription)\n")
            failed += 1
        }
    }

    await check("getCurrentTime") { try await CurrentTimeTool().run(TimeArguments(timeZone: "Asia/Tokyo")) }
    await check("getWeather") { try await WeatherTool().run(WeatherArguments(city: "Lisbon", unit: "celsius")) }
    await check("getWeather (fahrenheit)") { try await WeatherTool().run(WeatherArguments(city: "New York", unit: "fahrenheit")) }
    await check("wikipediaSummary") { try await WikipediaTool().run(WikipediaArguments(subject: "Alan Turing")) }
    await check("convertCurrency") { try await CurrencyTool().run(ExchangeRateArguments(amount: 100, fromCurrency: "EUR", toCurrency: "GBP")) }
    await check("getCryptoPrice") { try await CryptoPriceTool().run(CryptoPriceArguments(coin: "BTC")) }
    await check("airQuality") { try await AirQualityTool().run(CityArguments(city: "Delhi")) }
    await check("sunriseSunset") { try await SunTool().run(CityArguments(city: "Oslo")) }
    await check("recentEarthquakes") { try await EarthquakeTool().run(EarthquakeArguments(minimumMagnitude: 4.5, withinDays: 7)) }
    await check("upcomingPublicHolidays") { try await HolidayTool().run(HolidayArguments(country: "France")) }
    await check("liveAirTraffic (JFK)") { try await AirTrafficTool().run(AirportArguments(airport: "JFK")) }
    await check("liveAirTraffic (by name)") { try await AirTrafficTool().run(AirportArguments(airport: "Heathrow")) }

    say("\n  \(passed) passed, \(failed) failed\n")
    if failed > 0 { exit(1) }
}

// MARK: - One-shot / piped mode

if let prompt = options.prompt {
    await respond(to: prompt)
    exit(0)
}

if !isInteractive {
    let piped = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let piped, !piped.isEmpty { await respond(to: piped) }
    exit(0)
}

// MARK: - Interactive session

note("marlo — on-device assistant · context \(await agent.contextSize) tokens · type /help for commands\n\n")

while true {
    note("› ")
    guard let line = readLine() else { break }
    let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { continue }

    switch input {
    case "/quit", "/exit", "/q":
        note("\n")
        exit(0)

    case "/new", "/clear":
        await agent.reset()
        note("  started a new conversation\n\n")
        continue

    case "/tools":
        note("\n")
        for tool in await agent.describeTools() {
            let flag = tool.mutating ? " [asks approval]" : ""
            let state = tool.enabled ? "on " : "off"
            note("  [\(state)] \(tool.name)\(flag)\n    \(tool.summary)\n")
        }
        note("\n  /tools on <name> | /tools off <name> | /tools only <name,...>\n\n")
        continue

    case let command where command.hasPrefix("/tools "):
        let parts = command.dropFirst("/tools ".count)
            .split(separator: " ", maxSplits: 1)
            .map(String.init)
        let action = parts.first?.lowercased() ?? ""
        let names = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        note("\n")
        switch action {
        case "on", "off", "enable", "disable":
            let enabled = action == "on" || action == "enable"
            if names.isEmpty {
                note("  usage: /tools \(enabled ? "on" : "off") <name>[,<name>...]\n\n")
                continue
            }
            for name in names {
                let ok = await agent.setTool(name, enabled: enabled)
                note(ok
                    ? "  \(name): \(enabled ? "enabled" : "disabled")\n"
                    : "  unknown tool: \(name)\n")
            }
        case "only":
            if names.isEmpty {
                note("  usage: /tools only <name>[,<name>...]\n\n")
                continue
            }
            let known = Set(await agent.toolNames)
            let unknown = names.filter { !known.contains($0) }
            for name in unknown { note("  unknown tool: \(name)\n") }
            let keep = names.filter { known.contains($0) }
            await agent.setAllTools(enabled: false)
            for name in keep { await agent.setTool(name, enabled: true) }
            note("  enabled: \(keep.joined(separator: ", "))\n")
        case "all":
            await agent.setAllTools(enabled: true)
            note("  all tools enabled\n")
        case "none":
            await agent.setAllTools(enabled: false)
            note("  all tools disabled — answers come from the model alone\n")
        default:
            note("  usage: /tools [on|off|only|all|none] <name,...>\n")
        }
        note("\n")
        continue

    case let command where command == "/offline" || command.hasPrefix("/offline "):
        let names = Set(await agent.toolNames)
        let networkNames = await agent.toolNames.filter { networkToolNames.contains($0) }
        let enabled = Set(await agent.enabledToolNames)
        let anyNetworkOn = networkNames.contains { enabled.contains($0) }

        // Bare `/offline` toggles: if any network tool is on, turn them all off;
        // if none are on, turn them all back on. An explicit `on`/`off` is absolute.
        let argument = command.dropFirst("/offline".count).trimmingCharacters(in: .whitespaces).lowercased()
        let turnOn: Bool
        switch argument {
        case "on", "enable": turnOn = true
        case "off", "disable": turnOn = false
        case "": turnOn = !anyNetworkOn
        default:
            note("\n  usage: /offline [on|off]\n\n")
            continue
        }

        note("\n")
        for name in networkNames where names.contains(name) {
            await agent.setTool(name, enabled: turnOn)
        }
        note(turnOn
            ? "  network tools on\n\n"
            : "  network tools off — answers come from the model alone\n\n")
        continue

    case "/tokens":
        let used = await agent.usedTokens()
        let limit = await agent.contextSize
        let percent = limit > 0 ? used * 100 / limit : 0
        note("  \(used) / \(limit) tokens (\(percent)%)\n\n")
        continue

    case "/help":
        note("\n" + usage() + "\n\n")
        continue

    default:
        break
    }

    await respond(to: input)
    note("\n")
}
