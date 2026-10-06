import Foundation
import FoundationModels
import Testing
@testable import MarloKit

/// The router's reply is model output, so parsing has to survive prose, casing,
/// partial names and outright nonsense without either guessing or crashing.
@Suite("Tool router parsing")
struct ToolRouterParsingTests {
    let candidates: Set<String> = [
        "getCurrentTime", "getWeather", "wikipediaSummary", "convertCurrency",
        "getCryptoPrice", "airQuality", "sunriseSunset", "recentEarthquakes",
        "upcomingPublicHolidays", "liveAirTraffic", "rememberFact", "recallMemory",
    ]

    @Test("a clean list parses")
    func cleanList() {
        let outcome = ToolRouter.parse("getWeather, getCurrentTime", candidates: candidates)
        #expect(outcome == .chosen(["getWeather", "getCurrentTime"]))
    }

    @Test("reasoning tacked onto the list is ignored")
    func proseAfterNames() {
        // Observed in a live probe: "convertCurrency, 100 USD to JPY".
        let outcome = ToolRouter.parse("convertCurrency, 100 USD to JPY", candidates: candidates)
        #expect(outcome == .chosen(["convertCurrency"]))
    }

    @Test("case and whitespace do not matter")
    func casing() {
        let outcome = ToolRouter.parse("  GETWEATHER\n GETCURRENTTIME  ", candidates: candidates)
        #expect(outcome == .chosen(["getWeather", "getCurrentTime"]))
    }

    @Test("NONE means no tools")
    func none() {
        #expect(ToolRouter.parse("NONE", candidates: candidates) == .none)
        #expect(ToolRouter.parse("none", candidates: candidates) == .none)
    }

    @Test("an unknown name is not a tool")
    func unknownName() {
        let outcome = ToolRouter.parse("getEverything", candidates: candidates)
        #expect(outcome == .unresolved("no known tool name in reply"))
    }

    @Test("an empty reply is unresolved, not a silent NONE")
    func empty() {
        #expect(ToolRouter.parse("   ", candidates: candidates) == .unresolved("empty reply"))
    }

    @Test("a name inside a longer word does not match")
    func wordBoundaries() {
        // "getWeather" must not be found inside "getWeatherForecast".
        let outcome = ToolRouter.parse("getWeatherForecast for Paris", candidates: candidates)
        #expect(outcome == .unresolved("no known tool name in reply"))
    }

    @Test("names parse when the model wraps them in punctuation")
    func punctuation() {
        let outcome = ToolRouter.parse("- getWeather\n- getCurrentTime.", candidates: candidates)
        #expect(outcome == .chosen(["getWeather", "getCurrentTime"]))
    }

    @Test("a NONE alongside a real name picks the name")
    func noneWithName() {
        let outcome = ToolRouter.parse("NONE, getWeather", candidates: candidates)
        #expect(outcome == .chosen(["getWeather"]))
    }

    @Test("routing can never name a tool that is not a candidate")
    func candidateIntersection() {
        // The only defence that matters: a tool the user turned off must be
        // unreachable even if the model names it.
        let limited: Set<String> = ["getWeather"]
        let outcome = ToolRouter.parse("getWeather, wikipediaSummary", candidates: limited)
        #expect(outcome == .chosen(["getWeather"]))
    }
}

@Suite("Router prompt")
struct ToolRouterPromptTests {
    @Test("the prompt lists each candidate exactly once")
    func listing() {
        let prompt = ToolRouter.prompt(
            message: "weather in Lisbon?",
            previousMessage: nil,
            candidates: [(name: "getWeather", summary: "Current weather."), (name: "getCurrentTime", summary: "The time.")]
        )
        #expect(prompt.contains("- getWeather: Current weather."))
        #expect(prompt.contains("- getCurrentTime: The time."))
        #expect(prompt.contains("User message: weather in Lisbon?"))
    }

    @Test("a previous message is carried so follow-ups can be routed")
    func followUpContext() {
        let prompt = ToolRouter.prompt(
            message: "and in Porto?",
            previousMessage: "what's the weather in Lisbon?",
            candidates: []
        )
        #expect(prompt.contains("Previous user message: what's the weather in Lisbon?"))
        #expect(prompt.contains("User message: and in Porto?"))
    }
}

@Suite("Response style")
struct ResponseStyleTests {
    @Test("every style has distinct guidance")
    func distinct() {
        let texts = ResponseStyle.allCases.map(\.instruction)
        #expect(Set(texts).count == texts.count)
    }

    @Test("the old brevity instruction is gone from the default prompt")
    func brevityRemoved() {
        // This sentence cost roughly a quarter of answer length, measured.
        #expect(!Agent.defaultInstructions.localizedCaseInsensitiveContains("keep answers short"))
    }

    @Test("the default prompt tells the model not to reach for a tool needlessly")
    func toolsAreNotAutomatic() {
        // Multi-line string literals keep their newlines, so compare on a
        // whitespace-normalised copy rather than on the literal spacing.
        let normalised = Agent.defaultInstructions
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        #expect(normalised.contains("do not use a tool merely because one exists"))
    }
}

@Suite("Settings")
struct SettingsTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "marlo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh install gets the curated default, not all twelve tools")
    func curatedDefault() {
        let store = SettingsStore(defaults: freshDefaults())
        #expect(store.current.enabledTools == MarloSettings.defaultTools)
        #expect(store.current.enabledTools.count < 12)
        #expect(store.current.toolsEnabled)
    }

    @Test("the master switch keeps the per-tool selection")
    func masterSwitchPreservesSelection() {
        let defaults = freshDefaults()
        let store = SettingsStore(defaults: defaults)
        store.setEnabledTools(["getWeather"])

        store.setToolsEnabled(false)
        #expect(store.current.enabledTools == ["getWeather"])

        store.setToolsEnabled(true)
        #expect(store.current.enabledTools == ["getWeather"])
    }

    @Test("turning everything off stays off across a relaunch")
    func emptySelectionPersists() {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.setEnabledTools([])

        let second = SettingsStore(defaults: defaults)
        #expect(second.current.enabledTools.isEmpty)
    }

    @Test("choices survive a reload")
    func roundTrip() {
        let defaults = freshDefaults()
        let first = SettingsStore(defaults: defaults)
        first.setEnabledTools(["getWeather", "airQuality"])
        first.setResponseStyle(.expansive)

        let second = SettingsStore(defaults: defaults)
        #expect(second.current.enabledTools == ["getWeather", "airQuality"])
        #expect(second.current.responseStyle == .expansive)
    }

    @Test("the routing threshold cannot be set below the floor")
    func thresholdFloor() {
        let store = SettingsStore(defaults: freshDefaults())
        store.setRoutingThreshold(0)
        #expect(store.current.routingThreshold >= MarloSettings.minimumRoutingThreshold)
    }
}
