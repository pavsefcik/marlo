import Foundation
import FoundationModels

// MARK: - Hand-rolled Generable conformances
//
// The `@Generable` macro is provided by the `FoundationModelsMacros` compiler
// plugin, which ships inside Xcode.app. With Command Line Tools only, the macro
// cannot be expanded ("plugin for module 'FoundationModelsMacros' not found").
//
// A macro is sugar: it synthesises exactly the members below. Writing them by
// hand keeps marlo building today. Each type has three parts:
//
//   1. `static var generationSchema` — the constraints the model decodes against
//   2. `init(_ content: GeneratedContent)` — decode model output into the type
//   3. `var generatedContent` — encode the type back for the model
//
// `PartiallyGenerated` defaults to `Self`, which is what we want for streaming.
//
// NOTE: these are deliberately simple. Optional properties need
// `.init(name:description:type: String?.self)` plus `value(String?.self, ...)`
// in the decoder; add that only when a tool actually needs it.

// MARK: Tool: getCurrentTime

struct TimeArguments: Generable {
    var timeZone: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(timeZone: String) {
        self.timeZone = timeZone
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: TimeArguments.self,
            description: "Arguments for getCurrentTime",
            properties: [
                .init(
                    name: "timeZone",
                    description: "IANA time zone identifier, e.g. 'Europe/Berlin' or 'UTC'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.timeZone = try content.value(String.self, forProperty: "timeZone")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["timeZone": timeZone])
    }
}

// MARK: Tool: getWeather

struct WeatherArguments: Generable {
    var city: String
    var unit: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(city: String, unit: String) {
        self.city = city
        self.unit = unit
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: WeatherArguments.self,
            description: "Arguments for getWeather",
            properties: [
                .init(name: "city", description: "City name, e.g. 'Tokyo'.", type: String.self),
                .init(
                    name: "unit",
                    description: "Temperature unit. Either 'celsius' or 'fahrenheit'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.city = try content.value(String.self, forProperty: "city")
        self.unit = try content.value(String.self, forProperty: "unit")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["city": city, "unit": unit])
    }
}

// MARK: Tool: wikipediaSummary / wikipediaSearch / exchangeRate / cryptoPrice /
//            sunriseSunset / airQuality / recentEarthquakes /
//            upcomingPublicHolidays / liveAirTraffic

struct WikipediaArguments: Generable {
    var subject: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(subject: String) {
        self.subject = subject
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: WikipediaArguments.self,
            description: "Arguments for wikipediaSummary",
            properties: [
                .init(
                    name: "subject",
                    description: "A person, place, thing or event to look up, e.g. 'Ada Lovelace'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.subject = try content.value(String.self, forProperty: "subject")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["subject": subject])
    }
}

struct ExchangeRateArguments: Generable {
    var amount: Double
    var fromCurrency: String
    var toCurrency: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(amount: Double, fromCurrency: String, toCurrency: String) {
        self.amount = amount
        self.fromCurrency = fromCurrency
        self.toCurrency = toCurrency
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: ExchangeRateArguments.self,
            description: "Arguments for convertCurrency",
            properties: [
                .init(name: "amount", description: "How much money to convert, e.g. 100.", type: Double.self),
                .init(
                    name: "fromCurrency",
                    description: "Three-letter currency code to convert from, e.g. 'USD'.",
                    type: String.self
                ),
                .init(
                    name: "toCurrency",
                    description: "Three-letter currency code to convert to, e.g. 'JPY'.",
                    type: String.self
                ),
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.amount = try content.value(Double.self, forProperty: "amount")
        self.fromCurrency = try content.value(String.self, forProperty: "fromCurrency")
        self.toCurrency = try content.value(String.self, forProperty: "toCurrency")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "amount": amount,
            "fromCurrency": fromCurrency,
            "toCurrency": toCurrency,
        ])
    }
}

struct CryptoPriceArguments: Generable {
    var coin: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(coin: String) {
        self.coin = coin
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: CryptoPriceArguments.self,
            description: "Arguments for getCryptoPrice",
            properties: [
                .init(
                    name: "coin",
                    description: "Cryptocurrency ticker symbol, e.g. 'BTC', 'ETH' or 'SOL'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.coin = try content.value(String.self, forProperty: "coin")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["coin": coin])
    }
}

struct CityArguments: Generable {
    var city: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(city: String) {
        self.city = city
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: CityArguments.self,
            description: "Arguments for a city-based lookup",
            properties: [
                .init(name: "city", description: "City name, e.g. 'Kyoto'.", type: String.self)
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.city = try content.value(String.self, forProperty: "city")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["city": city])
    }
}

struct EarthquakeArguments: Generable {
    var minimumMagnitude: Double
    var withinDays: Int

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(minimumMagnitude: Double, withinDays: Int) {
        self.minimumMagnitude = minimumMagnitude
        self.withinDays = withinDays
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: EarthquakeArguments.self,
            description: "Arguments for recentEarthquakes",
            properties: [
                .init(
                    name: "minimumMagnitude",
                    description: "Smallest magnitude to report, e.g. 4.5. Use 4.5 unless asked otherwise.",
                    type: Double.self
                ),
                .init(
                    name: "withinDays",
                    description: "How many days back to search, e.g. 7.",
                    type: Int.self
                ),
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.minimumMagnitude = try content.value(Double.self, forProperty: "minimumMagnitude")
        self.withinDays = try content.value(Int.self, forProperty: "withinDays")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "minimumMagnitude": minimumMagnitude,
            "withinDays": withinDays,
        ])
    }
}

struct HolidayArguments: Generable {
    var country: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(country: String) {
        self.country = country
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: HolidayArguments.self,
            description: "Arguments for upcomingPublicHolidays",
            properties: [
                .init(
                    name: "country",
                    description: "Country name or two-letter code, e.g. 'Japan' or 'JP'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.country = try content.value(String.self, forProperty: "country")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["country": country])
    }
}

struct AirportArguments: Generable {
    var airport: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(airport: String) {
        self.airport = airport
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: AirportArguments.self,
            description: "Arguments for liveAirTraffic",
            properties: [
                .init(
                    name: "airport",
                    description: "Airport IATA code such as 'JFK' or 'LHR'.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.airport = try content.value(String.self, forProperty: "airport")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["airport": airport])
    }
}

// MARK: Tool: recallMemory

struct RecallArguments: Generable {
    var query: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(query: String) {
        self.query = query
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: RecallArguments.self,
            description: "Arguments for recallMemory",
            properties: [
                .init(
                    name: "query",
                    description: "Words to search the assistant's long-term notes for.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.query = try content.value(String.self, forProperty: "query")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["query": query])
    }
}

// MARK: Tool: rememberFact

struct RememberArguments: Generable {
    var text: String

    /// Memberwise initialiser for direct calls (self-test, tests).
    init(text: String) {
        self.text = text
    }

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: RememberArguments.self,
            description: "Arguments for rememberFact",
            properties: [
                .init(
                    name: "text",
                    description: "The single fact to store, written as a standalone sentence.",
                    type: String.self
                )
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.text = try content.value(String.self, forProperty: "text")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["text": text])
    }
}
