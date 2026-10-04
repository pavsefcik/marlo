# marlo

A local, on-device assistant for macOS, built on Apple's **Foundation Models**
framework. No network, no API keys, no `fm serve` process.

This repository is the working prototype: a CLI agent loop with real tool
calling, streaming, approval gating, long-term memory, and context accounting.
It is the foundation for a SwiftUI menu-bar app.

Tools run against real data. `getWeather` calls the free, keyless
[Open-Meteo](https://open-meteo.com) API (geocoding + current conditions);
`getCurrentTime` uses the system clock; memory is a local JSONL file. Nothing is
faked — if a tool cannot reach its source, it says so instead of inventing an
answer.

```
marlo/                 Swift package (this prototype)
  Sources/Marlo/
    main.swift              CLI: REPL, one-shot, piped input
    Agent.swift             session, streaming, retries, tool bridging
    AssistantTool.swift     tool definitions + memory store
    HandRolledGenerable.swift  Generable conformances (macro-free)
```

## Quick start

```bash
cd marlo
swift build

./.build/debug/marlo --selftest        # call every tool directly, no model
./.build/debug/marlo "What's the weather in Tokyo?"
./.build/debug/marlo            # interactive session
echo "What time is it in UTC?" | ./.build/debug/marlo
```

Requirements: macOS 27, Apple Intelligence enabled, and `fm license` accepted
(`sudo fm license`). Command Line Tools are enough — see **Xcode** below.

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

**4. Streaming rewrites, not just appends.**
`ResponseStream` yields cumulative snapshots. `Agent.stream` emits a delta when a
snapshot extends the previous one, and re-emits the whole text when it rewrites
it. A rich UI should re-render from the full snapshot instead.

**5. Tool schemas cost context every turn.**
`/tokens` reports conversation + tool schema cost. With four tools and default
instructions, an idle session sits near **1000 of 8192 tokens** (~12%) before the
user types anything. Keep tool descriptions short and the tool count low.

## Xcode

The `@Generable` macro cannot be expanded with Command Line Tools alone
(`plugin for module 'FoundationModelsMacros' not found`), because the compiler
plugin ships inside Xcode. `HandRolledGenerable.swift` writes out what the macro
would synthesize, so the project builds and runs today.

`FoundationModels` itself, `SwiftUI`, and streaming all work CLT-only. Xcode is
needed for the macros, Previews, Instruments, and any signed/distributable build.
Installing it removes the hand-rolled conformances; no other change is required.

6. **A stub that looks real is worse than an error.** The first version of
   `getWeather` returned a hardcoded `22°C and clear` for every city. The tool
   call was genuinely happening, so output *looked* correct — including a
   `(demo data)` suffix on stderr that the model silently dropped when it
   restated the result as fact. If a tool cannot get real data, it must fail
   loudly, never fabricate.

7. **Silent decode failures read as "no data".** Three separate bugs hid behind
   `try?`-swallowed `DecodingError`s: airport coordinates arriving as strings
   (`"40.639928"`) instead of numbers, `daylight_duration` returning a fraction
   (`40304.48`) while declared `[Int]`, and Wikipedia titles being
   double-encoded (`%20` → `%2520`) so every multi-word lookup 404'd while
   single-word ones worked. `HTTP.getJSON` now reports the failing field and
   service, and `--selftest` exercises every tool.

8. **Use `percentEncodedPath`, not `path`.** Assigning an already-escaped string
   to `URLComponents.path` re-encodes `%`, silently corrupting any URL with a
   space in it.

## Safety and licensing

Apple's acceptable-use requirements and the `fm` legal notice both restrict
programmatic access to Apple's models. The supported path is a signed app using
the framework directly — which is what this project is. It is intended for local,
personal use; do not wrap it in a proxy or ship it commercially.

## Next steps

1. `marlo-ui`: SwiftUI `MenuBarExtra` app with a global hotkey, snapshot
   streaming, tool cards, and a context meter.
2. Tool approval cards showing arguments and a diff before a mutating tool runs.
3. Persist transcripts (the framework's `Transcript` type is `Codable`) with a
   session sidebar.
4. More tools: files, shell, web fetch, clipboard — read-only by default.
5. Auto-summarize old turns as the context window fills instead of hard-failing.
6. Add `marlo selftest` to CI so no tool regresses into a stub or a silent
   decode failure.
