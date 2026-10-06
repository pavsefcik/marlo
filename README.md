# marlo

**A local chatbot for your Mac.** It runs entirely on-device on Apple's
Foundation Models framework — no cloud, no account, no API key, no server
process. Close the lid, turn off Wi-Fi: it still answers.

That is the whole product. The app is a menu-bar chat panel: type a question, get
an answer, nothing leaves the machine.

The repository also contains a much larger set of machinery — twelve tools that
call real APIs, a two-step tool router, a slash-command system, saved sessions —
which the **CLI** uses and the **app** deliberately does not. Everything is in
`Sources/MarloKit`, built and tested, ready to be switched on. See
[Dormant machinery](#dormant-machinery).

```
marlo/
  Sources/MarloKit/          shared library
    Agent.swift                session, streaming, retries, tool bridging, routing
    AssistantTool.swift        tool definitions + memory store
    Arguments.swift            Generable argument types (@Generable + @Guide)
    ToolRouter.swift           two-step tool selection and its reply parser
    TranscriptHygiene.swift    restricts history to the visible tool set
    Settings.swift             persisted preferences and response style
    Commands.swift             the in-session command table
    CommandRunner.swift        executes commands, shared by CLI and app
    SessionStore.swift         saved conversations on disk
    Model.swift                model choice and its real availability
  Sources/CReadline/         C wrapper over libedit (history, completion)
  Sources/MarloUI/           SwiftUI menu-bar app — a plain local chatbot
    MarloApp.swift             MenuBarExtra scene, status bar, settings
    ChatViewModel.swift        agent ↔ SwiftUI bridge; hides all tools
    Views.swift                transcript, composer, empty state
  Sources/MarloCLI/          the CLI — uses the whole tool set
    main.swift                 REPL, one-shot, piped input, --selftest
    LineEditor.swift           readline wrapper and completion sources
  Tests/MarloKitTests/       router, transcript hygiene, settings, commands, sessions
```

The app and the CLI share `MarloKit` and the same `UserDefaults`, but not the same
feature set: the app hides every tool, the CLI offers all of them.

```
              ┌───────────────────────────────┐
              │  MarloKit                     │
              │  Agent · tools · router ·     │
              │  commands · sessions          │
              └───────┬───────────────┬───────┘
                      │               │
        tools hidden  │               │  tools on
                      ▼               ▼
                 MarloApp          marlo
                (chatbot)           (CLI)
```

## Quick start

```bash
swift build
./run-app.sh                      # build, bundle, launch the menu-bar app
swift run marlo "explain monads"  # the CLI
swift test
```

`./run-app.sh` builds, wraps the binary in a minimal `.app` bundle, ad-hoc signs
it and launches it — `swift run MarloApp` alone will not show the menu-bar icon,
because macOS needs a bundle identity to hand out a `MenuBarExtra`.

| | |
|---|---|
| `./run-app.sh` | build, bundle, launch |
| `./run-app.sh --release` | release build |
| `./run-app.sh --rebuild` | clean build first |
| `./run-app.sh --install` | put it in `~/Applications` |
| `./run-app.sh --stop` | quit any running instance |

Requirements: macOS 27, Apple Intelligence enabled, and `fm license` accepted
(`sudo fm license`). **Xcode is required** — `Arguments.swift` uses the
`@Generable` macro, whose compiler plugin ships only in Xcode.

## Dormant machinery

The app is a plain chatbot. Everything below still exists, still builds, and is
still covered by the test suite — the app just does not switch it on. It is two
lines in `ChatViewModel.init` to bring back:

```swift
disabled: Set(definitions.map(\.name)),   // <- hide the tools
routingEnabled: false,                     // <- and the router
```

Nothing was deleted, because it all works and it may be wanted later. The
sections that follow describe **the CLI**, which uses the whole set. If you only
want the chatbot, they can be skipped.

| Piece | Where | State |
|---|---|---|
| 12 tools (`getWeather`, `wikipediaSummary`, …) | `AssistantTool.swift` | built, tested, `--selftest` calls each one; app hides them all |
| Two-step tool router | `ToolRouter.swift` | tested; app disables routing |
| Slash commands + tab completion | `Commands.swift`, `CommandRunner.swift`, `LineEditor.swift` | tested; CLI only |
| Saved sessions | `SessionStore.swift` | tested; CLI only |
| Tool approval sheet | was `ApprovalView` | unused in the app; the CLI still prompts in the terminal |

With every tool hidden the app declares **no** tool schemas, so a fresh session
costs about **215 tokens** instead of ~1,150 — and no tool can fire, because the
model is never shown one. Verified by asking the most tool-shaped questions there
are ("what's the weather in Lisbon right now?"): zero tool calls.

## CLI

Everything in this section applies to `marlo`, not the app.

The version has one source of truth, `MarloVersion.current` in
`Sources/MarloKit/Version.swift`, surfaced by `marlo --version` and read by
`run-app.sh` for the bundle's `CFBundleShortVersionString`. Bumping it in one
place is enough; tag the release `v` + that version.

### Slash commands

Type `/` for the list or tab-complete; ↑↓ walks history.

| | |
|---|---|
| `/help`, `/?` | show the command list |
| `/new`, `/clear` | start a new conversation |
| `/tools` | list tools and which are on |
| `/tools on\|off <names>` | enable or disable tools |
| `/tools only\|all\|none` | restrict, enable, or disable every tool |
| `/style` | concise, balanced or expansive answers |
| `/offline [on\|off]` | toggle every network tool |
| `/instructions [text\|edit\|reset]` | show or change the system instructions |
| `/model [system\|pcc]` | show or switch the model |
| `/save [name]` | save this conversation |
| `/sessions` | list saved conversations |
| `/resume [name]` | resume one; no name reopens the newest |
| `/tokens` | context usage |
| `/quit`, `/exit`, `/q` | leave |

Two shared pieces make that true rather than aspirational:

- `MarloCommands` (`Sources/MarloKit/Commands.swift`) is the single source for
  `/help`, the CLI's `/` list, and tab completion.
- `CommandRunner` (`Sources/MarloKit/CommandRunner.swift`) executes them. It
  returns a `CommandOutcome` — text, whether the conversation was replaced, and
  any work only the interface can do. `/quit` becomes `followUp: .quit`;
  `/instructions edit` becomes `.editInstructions`, which the CLI answers with a
  multi-line prompt. A test asserts every command in the table is handled by the
  runner, so adding one to the list without implementing it fails the build.

Tab completion is context-aware: `/hel` completes to `/help`, `/style exp` to
`/style expansive`, and `/tools only getW` to `/tools only getWeather`. The
system readline (`libedit`) is reached through a small C target because its
completion hooks are mutable globals that Swift 6 will not let code touch; when
stdin is not a terminal it falls back to plain reads, so piped input still works.

Sessions are stored as JSON in `~/Library/Application Support/marlo/sessions/`,
under the same directory as the memory file. A session file contains the full
transcript, so it holds everything typed in that conversation.

### Asking without a tool call

The model can only call a tool it can see, and a tool it cannot see stops
counting against the 8192 token window. So "answer from your own knowledge" is
expressed by not declaring tools: with tools off there is a single tool-free
pass, and with them on the router narrows the set per turn. What you should
*not* do is carry over a transcript whose definitions mention a tool you have
since hidden — see finding 6.

```bash
marlo --offline "explain photosynthesis"          # no network tools
marlo --no-tools "who was Ada Lovelace?"          # nothing but the model
marlo --without wikipediaSummary "who was Alan Turing?"
marlo --tools getWeather,getCurrentTime "weather in Tokyo and the time here"
```

Mid-session, the conversation is carried across the swap, so `/offline` after a
Wikipedia lookup keeps what was learned while the next turn answers from the
model:

```
› Who was Ada Lovelace?      ▸ wikipediaSummary …
› /offline                   network tools off — answers come from the model alone
› Who was Alan Turing?       (no tool call)
```

The commands are `/tools on|off <name>` to toggle one, `/tools only <a,b>` to
restrict, `/tools all`, `/tools none`, `/offline [on|off]` for every network tool
at once, and `/style [concise|balanced|expansive]` for answer length. `/tools`
prints `[on ]`/`[off]` per tool and the routing threshold in force. All of these
persist between runs.

The transcript swap is not a plain `LanguageModelSession(model:tools:transcript:)`
— see finding 6 below for what that gets wrong.

## Tools

The default set is four tools, not all twelve: `getCurrentTime`, `getWeather`,
`rememberFact`, `recallMemory`. Everything else is one toggle away, and if a
question needs it the router can only reach a tool that is already enabled.

| Tool | Source | Notes |
|---|---|---|
| `getCurrentTime` | system clock | offline, on by default |
| `rememberFact` / `recallMemory` | local JSONL | offline, mutating → approval, on by default |
| `getWeather` | Open-Meteo | current conditions, °C/°F, on by default |
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

**5. Tool schemas cost context every turn, and the estimate undercounts.**
Declaring a tool is not free and not per-use: the framework frames every
declared tool's schema into every request. Measured on this build:

| | tokens |
|---|---|
| default instructions | 164 |
| 12 tool schemas, declared | 1,157 |
| 12 tools as plain text in a prompt | 333 |
| `input.totalTokenCount`, 12 tools declared | **1,420** |
| same prompt, 2 tools declared | 474 |
| same prompt, 0 tools declared | 187 |

So an idle twelve-tool session spends ~1,150 tokens before the user types
anything. Two consequences shaped the current design: `usedTokens()` (transcript +
schemas) reports ~1,195 where the session's real input count is 1,420, so the
meter now shows the framework's own number once a turn has run; and tools are no
longer all switched on by default.

**6. A smaller tool set does not shrink the transcript — and the model will
narrate a result for a tool that is gone.**
Past tool definitions are recorded in the transcript's `instructions` entry.
Rebuilding a session with `LanguageModelSession(model:tools:transcript:)` carries
them over, so the model holds a definition it cannot call. It then invents the
result rather than admitting the gap:

```
before the fix: "We were just discussing the current time in Tokyo. I checked
                 the local time tool. The time is 9:34 AM in Tokyo."
after:          "We just talked about the current time in Tokyo, which is 9:34 AM."
```

Dropping the output entirely is not the answer either — the fact is lost and the
next question gets a fabricated one. `Transcript.restricted(to:)` therefore
filters the definitions, drops the calls and outputs that belong to hidden tools,
and **folds their text into the instructions as established context**. It is
idempotent (entry ids are preserved), and it cut one three-tool transcript from
621 to 293 tokens while keeping every fact.

## Two-step tool selection

With more than a few tools enabled, a turn is answered in two passes. The first
has **no tools at all** and reads a compact list of names and one-line summaries;
it replies with the names it needs, or `NONE`. Only those tools are declared for
the second pass.

| tools enabled | declare all | route first |
|---|---|---|
| 4 | ~320 | ~258 + 0.35 s |
| 12 | ~960 | ~514 + 0.35 s |
| 12, nothing needed | ~960 | ~330, then 0 |

Below the threshold (default 4, `MarloSettings.routingThreshold`) declaring
everything is cheaper than the extra round-trip, so routing does not run.

Three properties matter more than the saving:

- **Routing can only narrow.** Its answer is intersected with the enabled set, so
  a routing mistake can never enable a tool the user turned off.
- **It fails safe and visibly.** An unreadable reply falls back to *all enabled*
  tools and emits `AgentEvent.routing(fallback: true)`; the reply has been seen to
  arrive as `"convertCurrency, 100 USD to JPY"`, so parsing looks for known names
  on whole-word boundaries rather than trusting the reply's shape.
- **Off means off.** With tools disabled there is no router turn at all, just one
  tool-free pass.

`toolCallingMode: .disallowed` is set on the router session but is *not* relied
for enforcement: with five tools declared and that mode set, the model still
called one. Having no tools is what actually prevents it.

## Answer length

The old default instructions ended with "Keep answers short and direct." Held
against an otherwise identical prompt and the same model, that one sentence was
worth about a quarter of the answer:

| instructions | avg words |
|---|---|
| ending "keep answers short" | 338 |
| balanced (default) | 437 |
| expansive | 577 |
| concise | 249 |

Answer length is now a setting (`ResponseStyle`, or `/style` by hand) rather than
an invisible default, and the base prompt instead asks the model to answer from
its own knowledge when it can and *not* to reach for a tool merely because one
exists. Merely declaring tools suppressed prose by around 10% in the same probe
(307 → 277 words), which routing now mostly avoids.

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
resizable panel, no Dock icon, no window to manage. Settings (⌘,) has one
control: answer length.

The panel is a transcript, a composer, and a footer with a context meter and a
new-conversation button. The footer also carries the window button: **it breaks
the panel out of the menu bar into a normal, focusable app window** (with a Dock
icon, so ⌘-Tab and the Window menu work). Closing that window — or the footer's
collapse button — puts the app back in the menu bar and takes the Dock icon away
again, so the menu-bar extra stays the default way to reach Marlo.

One thing about the design is deliberate: **the transcript renders snapshots by
replacement, never by appending.** `ChatViewModel.streamingText` is assigned from
each `ResponseSnapshot`, because the framework yields the complete text so far
and a snapshot may revise text already emitted. Appending deltas would corrupt
what is on screen.

`ToolEventSink.ApprovalHandler` is still `async` for the same reason it always
was — a synchronous handler would have to block a thread inside the agent actor,
which can deadlock it, and the CLI could not keep its blocking `readLine()`
prompt. The app installs no handler and therefore refuses any tool, which is moot
while every tool is hidden but means a stray tool could not run by accident.

## Safety and licensing

Apple's acceptable-use requirements and the `fm` legal notice both restrict
programmatic access to Apple's models. The supported path is a signed app using
the framework directly — which is what this project is. It is intended for local,
personal use; do not wrap it in a proxy or ship it commercially.

That restriction is about Apple's models, not this repository's code: marlo is
released under the MIT License (see [LICENSE](LICENSE)).

## Next steps

For the chatbot:

1. A global hotkey (⌥Space) to summon the panel without reaching for the icon.
2. A real `.app` bundle with an icon and a Developer ID signature. `run-app.sh`
   produces an ad-hoc signed bundle, which is enough to launch but not to ship,
   and is why macOS logs Intents-registration errors on startup.
3. Persist transcripts so a conversation survives a quit. `Transcript` is
   `Codable` and `SessionStore` already writes it — this is CLI-only today, so
   the work is a UI for it rather than a format.
4. Auto-summarize old turns as the 8192-token window fills, instead of
   hard-failing with `contextOverflow`.

If the dormant machinery is ever switched on again:

5. `marlo --selftest` calls every tool directly and should run in CI, so no tool
   regresses into a stub or a silent decode failure.
6. Measure the router rather than trusting it: a table of messages with their
   expected tool sets, run against the real model, would catch a routing
   regression the way `--selftest` catches a broken tool.
7. More tools: files, shell, web fetch, clipboard — read-only by default. Each
   one costs roughly 95 tokens per request when declared, which is why routing
   exists.

## License

MIT — see [LICENSE](LICENSE).
