import Foundation
import FoundationModels

// MARK: - Tool argument types
//
// These use the `@Generable` and `@Guide` macros, which need the
// `FoundationModelsMacros` compiler plugin that ships inside Xcode. With Command
// Line Tools only, this file must be replaced by hand-written conformances (see
// the `hand-rolled-generable` note in README.md).
//
// `@Guide` descriptions are not decoration: they are the only place the model
// learns what a field means. "unit" as a bare String gets "metric" or "Kelvin";
// constraining it to an `anyOf` list makes the tool work.

// MARK: getCurrentTime

@Generable
public struct TimeArguments: Sendable {
    @Guide(description: "IANA time zone identifier, e.g. 'Europe/Berlin' or 'UTC'.")
    public var timeZone: String
}

// MARK: getWeather / getWeather-equivalent tools

@Generable
public struct WeatherArguments: Sendable {
    @Guide(description: "City name, e.g. 'Tokyo'.")
    public var city: String

    @Guide(description: "Temperature unit.", .anyOf(["celsius", "fahrenheit"]))
    public var unit: String
}

@Generable
public struct CityArguments: Sendable {
    @Guide(description: "City name, e.g. 'Kyoto'.")
    public var city: String
}

// MARK: wikipediaSummary

@Generable
public struct WikipediaArguments: Sendable {
    @Guide(description: "A person, place, thing or event to look up, e.g. 'Ada Lovelace'.")
    public var subject: String
}

// MARK: convertCurrency

@Generable
public struct ExchangeRateArguments: Sendable {
    @Guide(description: "How much money to convert, e.g. 100.")
    public var amount: Double

    @Guide(description: "Three-letter currency code to convert from, e.g. 'USD'.")
    public var fromCurrency: String

    @Guide(description: "Three-letter currency code to convert to, e.g. 'JPY'.")
    public var toCurrency: String
}

// MARK: getCryptoPrice

@Generable
public struct CryptoPriceArguments: Sendable {
    @Guide(description: "Cryptocurrency ticker symbol, e.g. 'BTC', 'ETH' or 'SOL'.")
    public var coin: String
}

// MARK: recentEarthquakes

@Generable
public struct EarthquakeArguments: Sendable {
    @Guide(description: "Smallest magnitude to report, e.g. 4.5.")
    public var minimumMagnitude: Double

    @Guide(description: "How many days back to search, e.g. 7.", .range(1...30))
    public var withinDays: Int
}

// MARK: upcomingPublicHolidays

@Generable
public struct HolidayArguments: Sendable {
    @Guide(description: "Country name or two-letter code, e.g. 'Japan' or 'JP'.")
    public var country: String
}

// MARK: liveAirTraffic

@Generable
public struct AirportArguments: Sendable {
    @Guide(description: "Airport IATA code such as 'JFK' or 'LHR', or an airport name such as 'Heathrow'.")
    public var airport: String
}

// MARK: memory

@Generable
public struct RememberArguments: Sendable {
    @Guide(description: "The single fact to store, written as a standalone sentence.")
    public var text: String
}

@Generable
public struct RecallArguments: Sendable {
    @Guide(description: "Words to search the assistant's long-term notes for.")
    public var query: String
}
