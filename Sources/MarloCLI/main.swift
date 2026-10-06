import Foundation
import FoundationModels
import MarloKit

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
    var showVersion = false
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
        case "-V", "--version":
            options.showVersion = true
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
      -V, --version              show the version

    IN-SESSION COMMANDS
      Type / for the list, or tab-complete any command. ↑↓ walks history.
      /help, /?              show the command list
      /new, /clear           start a new conversation
      /tools                 list tools and whether each is enabled
      /tools on|off <names>  enable or disable tools
      /tools only|all|none   restrict, enable, or disable every tool
      /style [concise|balanced|expansive]
      /offline [on|off]      toggle every network tool
      /instructions [text|edit|reset]
      /model [system|pcc]    show or switch the model
      /save [name]           save this conversation
      /sessions              list saved conversations
      /resume [name]         resume one; no name reopens the newest
      /tokens                show context usage
      /quit, /exit, /q       leave

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

if options.showVersion {
    say(MarloVersion.line + "\n")
    exit(0)
}

// MARK: - Tools

let memory = MemoryStore()

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

/// Tools that reach the network, taken from the tools themselves. `--offline`
/// hides exactly these, so an offline session can still use the clock and
/// memory but nothing leaves the machine.
let networkToolNames = Set(tools.filter(\.isNetwork).map(\.name))

// Persisted preferences. A CLI run that names no tool flags respects them, so
// the same choices a user makes in the app apply here too.
let settingsStore = SettingsStore()
var settings = settingsStore.current

// Work out which tools are enabled for this run.
//
// Explicit flags win over the stored selection: `--tools` names exactly what
// this run may use rather than being filtered by a preference set in the app.
let enabledTools: Set<String>
if options.noTools {
    enabledTools = []
} else if let only = options.onlyTools {
    enabledTools = Set(only).intersection(knownToolNames)
    let unknown = only.filter { !knownToolNames.contains($0) }
    if !unknown.isEmpty {
        note("marlo: unknown tool(s) in --tools: \(unknown.joined(separator: ", "))\n")
    }
} else if settings.toolsEnabled {
    enabledTools = settings.enabledTools.intersection(knownToolNames)
} else {
    enabledTools = []
}

var initialDisabledTools = knownToolNames.subtracting(enabledTools)

if options.offline {
    initialDisabledTools.formUnion(networkToolNames)
}

for name in options.withoutTools {
    if knownToolNames.contains(name) {
        initialDisabledTools.insert(name)
    } else {
        note("marlo: unknown tool in --without: \(name)\n")
    }
}

let agent = Agent(
    definitions: tools,
    instructions: options.instructions ?? settings.instructions,
    disabled: initialDisabledTools,
    routingEnabled: !enabledTools.isEmpty,
    routingThreshold: settings.routingThreshold,
    styleInstruction: settings.responseStyle.instruction,
    model: settings.model
)

let sessionStore = SessionStore()

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
        case .routing(let chosen, let fallback):
            let list = chosen.isEmpty ? "none" : chosen.joined(separator: ", ")
            note("  ⇢ tools: \(list)\(fallback ? " (routing failed, using all)" : "")\n")
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
    // The terminal can only append, so route snapshots through the adapter.
    let renderer = AppendOnlyRenderer { text in say(text) }
    do {
        let answer = try await agent.send(prompt) { snapshot in
            renderer.render(snapshot)
        }
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

/// Build tool arguments from JSON.
///
/// `@Generable` synthesises `init(_ content: GeneratedContent)`, and declaring any
/// initialiser suppresses Swift's implicit memberwise one — so
/// `TimeArguments(timeZone: "UTC")` does not compile. Building through
/// `GeneratedContent` also exercises the same decode path the model's output
/// takes, which is what the self-test should be testing anyway.
func args<T: Generable>(_ type: T.Type, _ json: String) throws -> T {
    try T(GeneratedContent(json: json))
}

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

    await check("getCurrentTime") { try await CurrentTimeTool().run(try args(TimeArguments.self, #"{"timeZone": "Asia/Tokyo"}"#)) }
    await check("getWeather") { try await WeatherTool().run(try args(WeatherArguments.self, #"{"city": "Lisbon", "unit": "celsius"}"#)) }
    await check("getWeather (fahrenheit)") { try await WeatherTool().run(try args(WeatherArguments.self, #"{"city": "New York", "unit": "fahrenheit"}"#)) }
    await check("wikipediaSummary") { try await WikipediaTool().run(try args(WikipediaArguments.self, #"{"subject": "Alan Turing"}"#)) }
    await check("convertCurrency") { try await CurrencyTool().run(try args(ExchangeRateArguments.self, #"{"amount": 100, "fromCurrency": "EUR", "toCurrency": "GBP"}"#)) }
    await check("getCryptoPrice") { try await CryptoPriceTool().run(try args(CryptoPriceArguments.self, #"{"coin": "BTC"}"#)) }
    await check("airQuality") { try await AirQualityTool().run(try args(CityArguments.self, #"{"city": "Delhi"}"#)) }
    await check("sunriseSunset") { try await SunTool().run(try args(CityArguments.self, #"{"city": "Oslo"}"#)) }
    await check("recentEarthquakes") { try await EarthquakeTool().run(try args(EarthquakeArguments.self, #"{"minimumMagnitude": 4.5, "withinDays": 7}"#)) }
    await check("upcomingPublicHolidays") { try await HolidayTool().run(try args(HolidayArguments.self, #"{"country": "France"}"#)) }
    await check("liveAirTraffic (JFK)") { try await AirTrafficTool().run(try args(AirportArguments.self, #"{"airport": "JFK"}"#)) }
    await check("liveAirTraffic (by name)") { try await AirTrafficTool().run(try args(AirportArguments.self, #"{"airport": "Heathrow"}"#)) }

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

/// One runner for both front ends, so `/tools off getWeather` cannot mean one
/// thing here and another in the app.
let commands = CommandRunner(agent: agent, settingsStore: settingsStore, sessions: sessionStore)

/// The line editor, given a way to enumerate the things worth completing.
///
/// Tool names and session names are read live rather than captured once, so
/// completion reflects a `/tools off` or a `/save` from earlier in the session.
let editor = LineEditor(
    toolNames: { knownToolNames.sorted() },
    sessionNames: { sessionStore.names }
)
editor.install()

note("marlo — assistant on this Mac · context \(await agent.contextSize) tokens · \(MarloCommands.all.count) commands, type / for a list\n\n")

/// Print a command's output, indented and framed like the rest of the session.
@MainActor
func show(_ text: String) {
    guard !text.isEmpty else { return }
    note("\n")
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        note(line.isEmpty ? "\n" : "  \(line)\n")
    }
    note("\n")
}

/// Read new instructions from the terminal, multi-line.
///
/// This is the one command that cannot be a pure string transformation: it needs
/// the interface to gather input, which is why the runner hands it back as a
/// follow-up instead of trying to prompt for itself.
@MainActor
func editInstructionsInteractively() async {
    note("\n  Enter the new instructions. An empty line finishes.\n\n")
    var lines: [String] = []
    while let line = editor.read(prompt: "  ") {
        if line.isEmpty { break }
        lines.append(line)
    }
    guard !lines.isEmpty else {
        note("\n  cancelled\n\n")
        return
    }
    let text = lines.joined(separator: "\n")
    await commands.setInstructions(text)
    note("\n  instructions updated (\(text.count) characters)\n\n")
}

// MARK: The loop

while true {
    guard let line = editor.read(prompt: "› ") else { break }
    let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.isEmpty { continue }

    if let outcome = await commands.run(input) {
        switch outcome.followUp {
        case .quit:
            note("\n")
            exit(0)
        case .editInstructions:
            await editInstructionsInteractively()
        case nil:
            show(outcome.output)
        }
        continue
    }

    await respond(to: input)
    note("\n")
}
