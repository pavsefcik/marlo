# marlo

A local, on-device assistant for macOS, built on Apple's **Foundation Models**
framework. No cloud, no API keys, no `fm serve` process. Ships as a **SwiftUI
menu-bar app** plus a scriptable **CLI** that share one agent.

Tools run against real data. `getWeather` calls the free, keyless
[Open-Meteo](https://open-meteo.com) API; `getCurrentTime` uses the system clock;
memory is a local JSONL file. Nothing is faked — if a tool cannot reach its
source, it says so instead of inventing an answer.

```
marlo/
  Sources/MarloKit/          shared library
    Agent.swift                session, streaming, retries, tool bridging
    AssistantTool.swift        tool definitions + memory store
    Arguments.swift            Generable argument types (@Generable + @Guide)
  Sources/MarloUI/           SwiftUI menu-bar app
    MarloApp.swift             MenuBarExtra scene, status bar, settings
    ChatViewModel.swift        agent ↔ SwiftUI bridge
    Views.swift                transcript, tool cards, approval sheet
  Sources/MarloCLI/          the CLI
    main.swift                 REPL, one-shot, piped input, --selftest
```

## Quick start

```bash
swift build

# The app: a marlo icon in the menu bar
swift run MarloApp

# The CLI
swift run marlo --selftest        # call every tool directly, no model
swift run marlo "What's the weather in Tokyo?"
swift run marlo                   # interactive session
echo "What time is it in UTC?" | swift run marlo
```

Requirements: macOS 27, Apple Intelligence enabled, and `fm license` accepted
(`sudo fm license`). **Xcode is required** — `Arguments.swift` uses the
`@Generable` macro, whose compiler plugin ships only in Xcode.

./.build/debug/marlo --selftest        # call every tool directly, no model
./.build/debug/marlo "What's the weather in Tokyo?"
./.build/debug/marlo            # interactive session
echo "What time is it in UTC?" | ./.build/debug/marlo
```

Requirements: macOS 27, Apple Intelligence enabled, and `fm license` accepted
(`sudo fm license`). See the top of this file for the Xcode requirement.

In-session commands: `/new`, `/tools`, `/tools on|off|only|all|none <names>`,
`/offline`, `/tokens`, `/help`, `/quit`.
Flags: `-y` auto-approves side-effecting tools, `-i` overrides instructions,
`--offline` hides network tools, `--no-tools` hides every tool, `--tools a,b,c`
shows only those, `--without a,b` hides those.

### Asking without a tool call

The model can only call a tool it can see. Disabling a tool removes it from the
session's `LanguageModelSession(tools:)` **and** from the schema the model is
shown, so it cannot reach for it and its tokens stop counting against the 8192
token window. This is the supported way to say "answer from your own knowledge".

```bash
marlo --offline "explain photosynthesis"          # no network tools
marlo --no-tools "who was Ada Lovelace?"          # nothing but the model
marlo --without wikipediaSummary "who was Alan Turing?"
marlo --tools getWeather,getCurrentTime "weather in Tokyo and the time here"
```

Mid-session, the transcript is carried across the swap with
`LanguageModelSession(model:tools:transcript:)`, so `/offline` after a Wikipedia
lookup keeps the conversation but makes the next turn answer from the model:

```
› Who was Ada Lovelace?      ▸ wikipediaSummary …
› /offline                   network tools off — answers come from the model alone
› Who was Alan Turing?       (no tool call)
```

The four local commands are `/tools on|off <name>` to toggle one, `/tools only
<a,b>` to restrict, `/tools all`, `/tools none`, and `/offline [on|off]` to
toggle every network tool at once. `/tools` now prints `[on ]`/`[off]` per tool.

## Tools

| Tool | Source | Notes |
|---|---|---|
| `getCurrentTime` | system clock | offline |
| `rememberFact` / `recallMemory` | local JSONL | offline, mutating → approval |
| `getWeather` | Open-Meteo | current conditions, °C/°F |
| `airQuality` | Open-Meteo | European AQI, PM2.5, PM10 |
| `sunriseSunset` | Open-Meteo | sunrise, sunset, daylight length |
| `wikipediaSummary` | Wikipedia REST | resolves loose names to articles |
| `convertCurrency` | Frankfurter | ECB reference rates |
| `getCryptoPrice` | Coinbase | USD spot price |
| `recentEarthquakes` | USGS | magnitude + time window |
| `upcomingPublicHolidays` | Nager.Date | accepts country name or code |
| `liveAirTraffic` | adsb.lol | **observed** aircraft, not a timetable |

All are free and keyless. `--selftest` calls each one directly so a broken tool
fails loudly instead of looking like missing data.

### What cannot be done: flight schedules

"What is the next flight leaving JFK?" **cannot be answered truthfully** from
public keyless data. Every schedule API — AviationStack, AirLabs, FlightAware,
Schiphol — requires an API key.

What exists is *observed* ADS-B traffic: aircraft transmitting near an airport
right now. `liveAirTraffic` reports that, and its description states plainly that
it is not a timetable, so the model declines future-flight questions instead of
inventing an answer. OpenSky was the other candidate and is avoided on purpose:
its anonymous quota burned out during testing (roughly 400 credits/day, several
per query) and returned `429` with an 86,201-second retry.

## Why this exists

An earlier exploration concluded that Apple's on-device model cannot do tool
calling, has a ~5k token context, and should be driven through `fm serve` with a
web backend emulating tools via `response_format`. Probing the real APIs showed
that most of that is an artifact of the `fm serve` HTTP shim, not the model.

| Claim | What is actually true |
|---|---|
| No tool calling | The **framework has real tool calling**, and the model uses it reliably. `fm serve` fails only because its parser drops `tool_calls`; on this build `tool_choice: "required"` returns `500 "An unsupported generation guide was used"`. |
| ~5,100 token ceiling | **8192** (`SystemLanguageModel.contextSize`). The 5k wall was the shim's framing overhead. |
| Structured output as a tool substitute | Unnecessary. `response_format` works, but it is a workaround for a bug that does not exist on the native path. |
| Needs a BFF + browser UI | No server, no SSE parsing, no process supervision. `FoundationModels` is called in-process. |
| Needs Xcode | Only partly — see below. |

Source of truth for the rest of this document: the SDK interface on this machine
(`MacOSX27.0.sdk`, `FoundationModels.swiftinterface`) plus live probes.

## Tool calling, done natively

Define a `Generable` argument type, implement `AssistantTool`, done:

```swift
struct WeatherTool: AssistantTool {
    let name = "getWeather"
    let summary = "Get the current real-world weather for a city."
    typealias Arguments = WeatherArguments

    func run(_ arguments: WeatherArguments) async throws -> String {
        // geocode + fetch from Open-Meteo, then format
    }
}
```

Every tool follows the same shape: typed `Generable` arguments, a `summary` that
tells the model *when* to reach for it, and a function that does real work. This
mirrors Anthropic's tool-use model closely.

The framework parses the model's tool choice, validates arguments against the
declared schema, runs `call(arguments:)`, and feeds the result back — looping
until the model answers. Verified behaviours:

- single tool call, correct arguments (`{"city": "Tokyo", "unit": "fahrenheit"}`)
- **multiple tools in one turn** (weather + time, results returned in parallel)
- **real weather data** across cities and climates (verified 8°–24°C spread,
  correct country/region resolution, Fahrenheit conversion)
- **honest failure**: an unknown city returns `no city named 'X' was found` and
  the model asks for clarification rather than guessing
- mutating tools can be gated on user approval before they run

## Findings worth keeping

These cost real time to discover and are easy to trip over again.

**1. Runtime-built tool schemas crash the model.**
Constructing a tool's schema with `GenerationSchema(root: DynamicGenerationSchema,
dependencies:)` compiles but fails at inference with
`Resource (Local Model Asset) unavailable error … Failed to create
ToolAwareGuidedGenerationConstraints`. The typed `Generable` path works. So tool
arguments are Swift types, not `JSONSchema` blobs. This killed an earlier
design that generated schemas dynamically.

**2. Context overflow masquerades as a safety error.**
A request larger than the window throws `LanguageModelError.guardrailViolation`
with the message *"The model's safety guardrails were triggered."* —
`.contextSizeExceeded` is never thrown. A naive retry loop therefore retries a
request that can never succeed and then reports a misleading safety failure.
`Agent.send` counts tokens up front and raises `contextOverflow` before calling
the model.

**3. Guardrail false positives are real.**
`fm respond --no-stream 'Say PONG'` returned *"I cannot respond to that."* at the
same moment a direct framework call answered fine. Retry-with-backoff is worth
having, but overflow must be excluded from it (see 2).

**4. Snapshots are cumulative, and the UI contract now says so.**
`ResponseStream` yields the **complete** text so far, not deltas. `Agent.send`
reports a `ResponseSnapshot` carrying that full text plus an `isRewrite` flag,
and callers render it by **replacement**. Appending deltas is the wrong model: a
snapshot may revise text already emitted.

Honest caveat: I could not reproduce a rewrite. Against this build, 18 probes
across reasoning, list and self-revision prompts produced 0 rewrites — every
snapshot extended the last one. So the replacement contract is right on the
merits (it is what the API provides and cannot corrupt output), but the specific
harm of appending deltas is *unverified here*, not demonstrated. The terminal
adapter (`AppendOnlyRenderer`) keeps the delta behaviour for a medium that cannot
un-print.

**5. Tool schemas cost context every turn.**
`/tokens` reports conversation + tool schema cost. With four tools and default
instructions, an idle session sits near **1000 of 8192 tokens** (~12%) before the
user types anything. Keep tool descriptions short and the tool count low.

## Xcode

`Arguments.swift` uses the `@Generable` and `@Guide` macros, which expand via the
`FoundationModelsMacros` plugin that ships **only inside Xcode**. With Command
Line Tools alone the build fails with `plugin for module 'FoundationModelsMacros'
not found`.

An earlier revision of this project hand-wrote those conformances
(`init(_:GeneratedContent)`, `generationSchema`, `generatedContent`) so it would
build CLT-only. With Xcode available those ~400 lines are gone, and `@Guide`
descriptions are now attached where they belong — to the field they describe.
Xcode also brings Previews and Instruments.

## The UI

`MarloApp` is a `MenuBarExtra` with `.window` style: click the menu-bar icon for a
resizable panel, no Dock icon, no window to manage. `Window` id `main` gives a
full window for long sessions; `Settings` puts tool and network switches in the
standard ⌘, location.

Two things about the design are deliberate:

- **The transcript renders snapshots by replacement, never by appending.**
  `ChatViewModel.streamingText` is assigned from each `ResponseSnapshot`, so a
  revision cannot corrupt what is on screen.
- **Approval is `async`.** `ToolEventSink.ApprovalHandler` returns via
  `await`, and the SwiftUI sheet resumes a `CheckedContinuation`. A synchronous
  handler would have to block a thread inside the agent actor, which can
  deadlock it — and the CLI could not keep its blocking `readLine()` prompt.

Read-only tools run without asking. `rememberFact` is the one mutating tool, and
it raises an approval sheet showing its exact arguments and a Cancel/Allow pair.

## Safety and licensing

Apple's acceptable-use requirements and the `fm` legal notice both restrict
programmatic access to Apple's models. The supported path is a signed app using
the framework directly — which is what this project is. It is intended for local,
personal use; do not wrap it in a proxy or ship it commercially.

That restriction is about Apple's models, not this repository's code: marlo is
released under the MIT License (see [LICENSE](LICENSE)).

## Next steps

1. A global hotkey (⌥Space) to summon the panel without reaching for the icon.
2. Package a real `.app` bundle: Info.plist with `LSUIElement`, an icon, and
   codesigning. Today `swift run MarloApp` works but has no bundle identity, so
   notifications and login-item registration are unavailable.
3. Persist transcripts (the framework's `Transcript` type is `Codable`) with a
   session sidebar.
4. More tools: files, shell, web fetch, clipboard — read-only by default.
5. Auto-summarize old turns as the context window fills instead of hard-failing.
6. Run `marlo --selftest` in CI so no tool regresses into a stub or a silent
   decode failure.

## License

MIT — see [LICENSE](LICENSE).
