import Foundation
import FoundationModels

/// A tool the assistant can call.
///
/// **Important constraint.** On macOS 27 with Command Line Tools only, building
/// a tool's schema at runtime (`GenerationSchema(root:dependencies:)` over a
/// `DynamicGenerationSchema`) makes the model fail with
/// "Resource (Local Model Asset) unavailable error". The typed path — a
/// `Generable` argument struct — works. So `arguments` is a Swift type, not a
/// JSON blob, and each tool decodes its own arguments.
///
/// The `@Generable` macro that would normally decorate those argument types needs
/// Xcode; with CLT only they are hand-written in HandRolledGenerable.swift.
///
/// This mirrors Anthropic's tool-use model closely: a declared input schema, a
/// description telling the model when to reach for it, and a function to run.
protocol AssistantTool: Sendable {
    associatedtype Arguments: Generable

    /// Name the model sees and calls.
    var name: String { get }
    /// Tells the model *when* to use this tool. The single most important
    /// sentence for getting the model to pick the right tool.
    var summary: String { get }
    /// Side-effecting tools pause for approval when a user is at the keyboard.
    var isMutating: Bool { get }
    func run(_ arguments: Arguments) async throws -> String
}

extension AssistantTool {
    var isMutating: Bool { false }
}

// MARK: - Type erasure

/// Lets `Agent` hold a heterogeneous tool list and bridge each entry to a
/// framework `Tool` once a `ToolEventSink` exists.
struct AnyAssistantTool: Sendable {
    let name: String
    let summary: String
    let isMutating: Bool
    let bridge: @Sendable (ToolEventSink) -> any Tool

    init<T: AssistantTool>(_ tool: T) {
        self.name = tool.name
        self.summary = tool.summary
        self.isMutating = tool.isMutating
        self.bridge = { sink in BridgedTool(base: tool, sink: sink) }
    }
}

/// Adapts a typed `AssistantTool` to FoundationModels' `Tool` protocol.
struct BridgedTool<T: AssistantTool>: Tool {
    let base: T
    let sink: ToolEventSink

    var name: String { base.name }
    var description: String { base.summary }

    func call(arguments: T.Arguments) async throws -> String {
        let rendered = arguments.generatedContent.jsonString
        sink.emit(.toolStarted(name: base.name, arguments: rendered))

        if base.isMutating, !sink.requestApproval(name: base.name, arguments: rendered) {
            let denial = "error: the user declined to run this tool"
            sink.emit(.toolFinished(name: base.name, result: denial))
            return denial
        }

        do {
            let result = try await base.run(arguments)
            sink.emit(.toolFinished(name: base.name, result: result))
            return result
        } catch {
            // Feed failures back to the model rather than aborting the turn, so
            // it can correct its arguments and try again.
            let failure = "error: \(error.localizedDescription)"
            sink.emit(.toolFinished(name: base.name, result: failure))
            return failure
        }
    }
}

// MARK: - Shared HTTP client

enum ToolNetworkError: LocalizedError {
    case unreachable(String)
    case badStatus(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "the service could not be reached (\(detail))"
        case .badStatus(let code): "the service returned HTTP \(code)"
        case .malformed: "the service returned an unexpected response"
        }
    }
}

/// A response that arrived but did not match the expected shape. Named
/// separately from a network failure so bugs surface as bugs.
struct ToolDecodeError: LocalizedError {
    var service: String
    var detail: String

    var errorDescription: String? {
        "\(service) returned data in an unexpected shape (\(detail))"
    }
}

enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "marlo/0.1 (local assistant)"]
        return URLSession(configuration: configuration)
    }()

    /// GET with one retry for transient failures, plus a flexible JSON decoder.
    static func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let data = try await getData(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let failure as DecodingError {
            // Include the field and a body snippet: a silent type mismatch here
            // has repeatedly looked like "no data" rather than a bug.
            let detail = describe(failure)
            throw ToolDecodeError(service: url.host ?? "service", detail: detail)
        }
    }

    /// Turn a DecodingError into a message that names the offending field.
    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            "expected \(type) at \(path(context.codingPath))"
        case .valueNotFound(let type, let context):
            "missing \(type) at \(path(context.codingPath))"
        case .keyNotFound(let key, let context):
            "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            "malformed data at \(path(context.codingPath))"
        @unknown default:
            "unreadable response"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        let joined = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return joined.isEmpty ? "the root" : joined
    }

    static func getData(_ url: URL) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ToolNetworkError.badStatus(http.statusCode)
                }
                return data
            } catch let failure as ToolNetworkError {
                throw failure
            } catch {
                lastError = error
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
        throw ToolNetworkError.unreachable(lastError?.localizedDescription ?? "unknown")
    }

    /// The ADS-B feed reports `alt_baro` as either an integer or the string
    /// "ground". Decode either shape as an optional Int.
    struct LooseInt: Decodable {
        let value: Int?

        init(value: Int?) { self.value = value }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) { value = int }
            else if let string = try? container.decode(String.self) {
                value = Int(string)
            } else {
                value = nil
            }
        }
    }

    /// airport-data.com returns `latitude`/`longitude` as *strings*
    /// ("40.639928"), while most APIs return numbers. Accept either.
    struct LooseDouble: Decodable {
        let value: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let double = try? container.decode(Double.self) { value = double }
            else if let string = try? container.decode(String.self) {
                value = Double(string)
            } else {
                value = nil
            }
        }
    }
}

// MARK: - getCurrentTime

struct CurrentTimeTool: AssistantTool {
    let name = "getCurrentTime"
    let summary = "Get the current date and time. Use for any question about today, now, or the time."

    typealias Arguments = TimeArguments

    func run(_ arguments: TimeArguments) async throws -> String {
        guard let zone = TimeZone(identifier: arguments.timeZone) else {
            // Returned as the tool result, not thrown, so the model can recover.
            return "error: unknown time zone '\(arguments.timeZone)'. Use an IANA identifier such as Europe/Berlin or UTC."
        }
        var formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

// MARK: - getWeather

struct WeatherTool: AssistantTool {
    let name = "getWeather"
    let summary = """
    Get the current real-world weather for a city. Use for any question about \
    weather, temperature, or conditions. Pass a plain city name.
    """

    typealias Arguments = WeatherArguments

    func run(_ arguments: WeatherArguments) async throws -> String {
        // Open-Meteo: free, no account, no API key.
        let useFahrenheit = arguments.unit.lowercased().hasPrefix("f")

        do {
            let place = try await OpenMeteo.geocode(arguments.city)
            let reading = try await OpenMeteo.currentConditions(
                latitude: place.latitude,
                longitude: place.longitude,
                useFahrenheit: useFahrenheit
            )
            let symbol = useFahrenheit ? "F" : "C"
            let rounded = Int(reading.temperature.rounded())
            return """
            The weather in \(place.label) is \(rounded)°\(symbol) with \
            \(reading.conditions), wind \(Int(reading.windSpeed.rounded())) km/h.
            """
        } catch let failure as WeatherLookupError {
            return "error: \(failure.localizedDescription)"
        }
    }
}

enum WeatherLookupError: LocalizedError {
    case cityNotFound(String)
    case unreachable(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .cityNotFound(let query): "no city named '\(query)' was found"
        case .unreachable(let detail): "the weather service could not be reached (\(detail))"
        case .malformed: "the weather service returned an unexpected response"
        }
    }
}

struct Place {
    var name: String
    var region: String?
    var country: String
    var latitude: Double
    var longitude: Double

    var label: String {
        var parts = [name]
        if let region, region != name { parts.append(region) }
        if !country.isEmpty { parts.append(country) }
        return parts.joined(separator: ", ")
    }
}

struct WeatherReading {
    var temperature: Double
    var conditions: String
    var windSpeed: Double
}

/// Shared Open-Meteo helpers, reused by the weather, air-quality and
/// sunrise/sunset tools.
enum OpenMeteo {
    static func geocode(_ query: String) async throws -> Place {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]

        let payload: GeocodingResponse = try await HTTP.getJSON(components.url!, as: GeocodingResponse.self)
        guard let first = payload.results?.first else {
            throw WeatherLookupError.cityNotFound(query)
        }
        return Place(
            name: first.name,
            region: first.admin1,
            country: first.country ?? first.countryCode ?? "",
            latitude: first.latitude,
            longitude: first.longitude
        )
    }

    static func currentConditions(
        latitude: Double,
        longitude: Double,
        useFahrenheit: Bool
    ) async throws -> WeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            .init(name: "temperature_unit", value: useFahrenheit ? "fahrenheit" : "celsius"),
        ]

        let payload: ForecastResponse = try await HTTP.getJSON(components.url!, as: ForecastResponse.self)
        guard let current = payload.current else { throw WeatherLookupError.malformed }
        return WeatherReading(
            temperature: current.temperature_2m,
            conditions: describe(current.weather_code),
            windSpeed: current.wind_speed_10m
        )
    }

    /// WMO weather interpretation codes used by Open-Meteo.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "clear skies"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61, 63, 65: "rain"
        case 66, 67: "freezing rain"
        case 71, 73, 75: "snow"
        case 77: "snow grains"
        case 80, 81, 82: "rain showers"
        case 85, 86: "snow showers"
        case 95: "a thunderstorm"
        case 96, 99: "a thunderstorm with hail"
        default: "unclear conditions (code \(code))"
        }
    }
}

// MARK: - Wire types

struct GeocodingResponse: Decodable {
    var results: [Entry]?

    struct Entry: Decodable {
        var name: String
        var latitude: Double
        var longitude: Double
        var country: String?
        var countryCode: String?
        var admin1: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, country, admin1
            case countryCode = "country_code"
        }
    }
}

struct ForecastResponse: Decodable {
    var current: Current?

    struct Current: Decodable {
        var temperature_2m: Double
        var weather_code: Int
        var wind_speed_10m: Double
    }
}

// MARK: - Long-term memory

/// A plain newline-delimited file the model can read and append to.
struct MemoryStore: Sendable {
    let url: URL

    init(url: URL = MemoryStore.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("marlo/memory.jsonl")
    }

    func remember(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record: [String: String] = [
            "text": text,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        var data = try JSONEncoder().encode(record)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    func recall(matching query: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }

        return contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let record = try? JSONDecoder().decode([String: String].self, from: data)
                else { return nil }
                return record["text"]
            }
            .filter { fact in
                let lower = fact.lowercased()
                return words.isEmpty || words.contains { lower.contains($0) }
            }
    }
}

struct RememberFactTool: AssistantTool {
    let name = "rememberFact"
    let summary = "Save one fact about the user to long-term memory. Use when the user says to remember something."
    let isMutating = true

    typealias Arguments = RememberArguments
    let store: MemoryStore

    func run(_ arguments: RememberArguments) async throws -> String {
        try store.remember(arguments.text)
        return "Stored: \(arguments.text)"
    }
}

struct RecallMemoryTool: AssistantTool {
    let name = "recallMemory"
    let summary = "Search saved notes for facts the user previously asked to remember."
    let store: MemoryStore

    typealias Arguments = RecallArguments

    func run(_ arguments: RecallArguments) async throws -> String {
        let hits = try store.recall(matching: arguments.query)
        return hits.isEmpty ? "no stored facts matched that query" : hits.joined(separator: "\n")
    }
}

// MARK: - wikipediaSummary

struct WikipediaTool: AssistantTool {
    let name = "wikipediaSummary"
    let summary = """
    Look up an encyclopedic summary and basic facts about a person, place, \
    country, company, invention or event. Use for 'who is', 'what is' and \
    'tell me about' questions rather than answering from memory.
    """

    typealias Arguments = WikipediaArguments

    func run(_ arguments: WikipediaArguments) async throws -> String {
        guard let summary = try? await Wikipedia.summary(of: arguments.subject) else {
            return "error: nothing was found for '\(arguments.subject)'"
        }
        return "\(summary.title): \(summary.extract)"
    }
}

struct WikipediaSummary: Decodable {
    var title: String
    var extract: String
    var description: String?
    var type: String?
    var coordinates: Coordinates?

    struct Coordinates: Decodable {
        var lat: Double
        var lon: Double
    }

    var isDisambiguation: Bool { type?.contains("disambiguation") ?? false }
}

enum Wikipedia {
    /// Resolve a loose subject into a real article title, then fetch its summary.
    /// Searching first is what makes 'nvim' or 'Ada Lovelace' land correctly.
    static func summary(of subject: String) async throws -> WikipediaSummary? {
        let title = (try? await bestTitle(for: subject)) ?? subject

        var components = URLComponents()
        components.scheme = "https"
        components.host = "en.wikipedia.org"
        // `percentEncodedPath` is required here: assigning to `path` would encode
        // the already-escaped '%' again (%20 -> %2520) and 404 every multi-word
        // title. Single-word titles like "Tokyo" would still work, hiding it.
        let escaped = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        components.percentEncodedPath = "/api/rest_v1/page/summary/\(escaped)"

        let summary: WikipediaSummary = try await HTTP.getJSON(components.url!, as: WikipediaSummary.self)
        // A disambiguation page is not an answer; ask for something narrower.
        return summary.isDisambiguation ? nil : summary
    }

    static func bestTitle(for subject: String) async throws -> String? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: subject),
            .init(name: "format", value: "json"),
            .init(name: "srlimit", value: "1"),
        ]
        let response: SearchResponse = try await HTTP.getJSON(components.url!, as: SearchResponse.self)
        return response.query?.search.first?.title
    }
}

struct SearchResponse: Decodable {
    var query: Query?
    struct Query: Decodable { var search: [Hit] }
    struct Hit: Decodable { var title: String }
}

// MARK: - convertCurrency

struct CurrencyTool: AssistantTool {
    let name = "convertCurrency"
    let summary = """
    Convert an amount between currencies using current reference exchange rates. \
    Use for any money conversion or exchange-rate question.
    """

    typealias Arguments = ExchangeRateArguments

    func run(_ arguments: ExchangeRateArguments) async throws -> String {
        let from = arguments.fromCurrency.uppercased()
        let to = arguments.toCurrency.uppercased()

        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        components.queryItems = [
            .init(name: "base", value: from),
            .init(name: "symbols", value: to),
        ]

        let payload: RateResponse = try await HTTP.getJSON(components.url!, as: RateResponse.self)
        guard let rate = payload.rates[to] else {
            return "error: no exchange rate for \(from) to \(to). Use three-letter codes such as USD, EUR, JPY, GBP."
        }

        let converted = arguments.amount * rate
        return String(
            format: "%.2f %@ = %.2f %@ (rate %.4f, reference rates dated %@)",
            arguments.amount, from, converted, to, rate, payload.date
        )
    }
}

struct RateResponse: Decodable {
    var date: String
    var rates: [String: Double]
}

// MARK: - getCryptoPrice

struct CryptoPriceTool: AssistantTool {
    let name = "getCryptoPrice"
    let summary = "Get the current spot price in US dollars for a cryptocurrency such as BTC, ETH or SOL."

    typealias Arguments = CryptoPriceArguments

    func run(_ arguments: CryptoPriceArguments) async throws -> String {
        let symbol = arguments.coin.uppercased()
        let url = URL(string: "https://api.coinbase.com/v2/prices/\(symbol)-USD/spot")!

        struct Payload: Decodable {
            struct DataField: Decodable { var amount: String; var base: String }
            var data: DataField
        }

        let payload: Payload = try await HTTP.getJSON(url, as: Payload.self)
        guard let price = Double(payload.data.amount) else { throw ToolNetworkError.malformed }
        return String(format: "1 %@ = $%.2f USD", payload.data.base, price)
    }
}

// MARK: - airQuality

struct AirQualityTool: AssistantTool {
    let name = "airQuality"
    let summary = "Get the current air quality and pollution level for a city."

    typealias Arguments = CityArguments

    func run(_ arguments: CityArguments) async throws -> String {
        let place = try await OpenMeteo.geocode(arguments.city)

        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "pm2_5,pm10,european_aqi"),
        ]

        let payload: AirQualityResponse = try await HTTP.getJSON(components.url!, as: AirQualityResponse.self)
        guard let current = payload.current else { throw ToolNetworkError.malformed }

        let band: String
        switch current.european_aqi {
        case ..<20: band = "good"
        case ..<40: band = "fair"
        case ..<60: band = "moderate"
        case ..<80: band = "poor"
        case ..<100: band = "very poor"
        default: band = "extremely poor"
        }

        return """
        Air quality in \(place.label): European AQI \(current.european_aqi) (\(band)), \
        PM2.5 \(Int(current.pm2_5.rounded())) µg/m³, PM10 \(Int(current.pm10.rounded())) µg/m³.
        """
    }
}

struct AirQualityResponse: Decodable {
    var current: Current?
    struct Current: Decodable {
        var pm2_5: Double
        var pm10: Double
        var european_aqi: Int
    }
}

// MARK: - sunriseSunset

struct SunTool: AssistantTool {
    let name = "sunriseSunset"
    let summary = "Get today's sunrise, sunset and daylight length for a city."

    typealias Arguments = CityArguments

    func run(_ arguments: CityArguments) async throws -> String {
        let place = try await OpenMeteo.geocode(arguments.city)

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "daily", value: "sunrise,sunset,daylight_duration"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]

        let payload: SunResponse = try await HTTP.getJSON(components.url!, as: SunResponse.self)
        guard let sunrise = payload.daily.sunrise.first,
              let sunset = payload.daily.sunset.first else {
            throw ToolNetworkError.malformed
        }

        // Open-Meteo returns local ISO timestamps; the clock time is the tail.
        let clock = { (iso: String) in String(iso.suffix(5)) }
        var daylight = "unknown"
        if let seconds = payload.daily.daylight_duration.first {
            let total = Int(seconds)
            daylight = "\(total / 3600)h \((total % 3600) / 60)m"
        }

        return """
        In \(place.label) the sun rises at \(clock(sunrise)) and sets at \
        \(clock(sunset)) local time, giving \(daylight) of daylight.
        """
    }
}

struct SunResponse: Decodable {
    var daily: Daily
    struct Daily: Decodable {
        var sunrise: [String]
        var sunset: [String]
        /// A fractional number of seconds (e.g. 40304.48). Declaring this as
        /// `[Int]` makes decoding fail for every location.
        var daylight_duration: [Double]
    }
}

// MARK: - recentEarthquakes

struct EarthquakeTool: AssistantTool {
    let name = "recentEarthquakes"
    let summary = "List recent significant earthquakes worldwide from the US Geological Survey."

    typealias Arguments = EarthquakeArguments

    func run(_ arguments: EarthquakeArguments) async throws -> String {
        let days = max(1, min(arguments.withinDays, 30))
        let start = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )

        var components = URLComponents(string: "https://earthquake.usgs.gov/fdsnws/event/1/query")!
        components.queryItems = [
            .init(name: "format", value: "geojson"),
            .init(name: "minmagnitude", value: String(arguments.minimumMagnitude)),
            .init(name: "starttime", value: start),
            .init(name: "orderby", value: "time"),
            .init(name: "limit", value: "8"),
        ]

        let payload: QuakeResponse = try await HTTP.getJSON(components.url!, as: QuakeResponse.self)
        guard !payload.features.isEmpty else {
            return "No earthquakes of magnitude \(arguments.minimumMagnitude) or above in the last \(days) days."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let lines = payload.features.map { feature -> String in
            let date = Date(timeIntervalSince1970: feature.properties.time / 1000)
            let place = feature.properties.place ?? "unknown location"
            return "M\(feature.properties.mag ?? 0) — \(place), \(formatter.string(from: date)) UTC"
        }
        return "Recent earthquakes:\n" + lines.joined(separator: "\n")
    }
}

struct QuakeResponse: Decodable {
    var features: [Feature]

    struct Feature: Decodable {
        var properties: Properties
        struct Properties: Decodable {
            var mag: Double?
            var place: String?
            var time: Double
        }
    }
}

// MARK: - upcomingPublicHolidays

struct HolidayTool: AssistantTool {
    let name = "upcomingPublicHolidays"
    let summary = "List upcoming public holidays for a country."

    typealias Arguments = HolidayArguments

    func run(_ arguments: HolidayArguments) async throws -> String {
        let code = try await CountryCodes.resolve(arguments.country)

        let url = URL(string: "https://date.nager.at/api/v3/NextPublicHolidays/\(code)")!
        let holidays: [Holiday] = try await HTTP.getJSON(url, as: [Holiday].self)
        guard !holidays.isEmpty else { return "No upcoming public holidays found for \(code)." }

        let lines = holidays.prefix(6).map { "\($0.date) — \($0.name)" }
        return "Upcoming public holidays in \(code):\n" + lines.joined(separator: "\n")
    }
}

struct Holiday: Decodable {
    var date: String
    var name: String
}

enum CountryCodes {
    private static let cache = Cache()

    /// Accepts a two-letter code or a country name and returns the code.
    static func resolve(_ input: String) async throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2 { return trimmed.uppercased() }

        if let cached = cache.value(for: trimmed.lowercased()) { return cached }

        struct Entry: Decodable { var countryCode: String; var name: String }
        let url = URL(string: "https://date.nager.at/api/v3/AvailableCountries")!
        let countries: [Entry] = try await HTTP.getJSON(url, as: [Entry].self)

        var table: [String: String] = [:]
        for country in countries {
            table[country.name.lowercased()] = country.countryCode
        }
        cache.merge(table)

        guard let match = table[trimmed.lowercased()] else { throw ToolNetworkError.malformed }
        return match
    }

    /// Country-name to code table, filled once and reused.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: String] = [:]

        func value(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return table[key]
        }

        func merge(_ new: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            table.merge(new) { _, new in new }
        }
    }
}

// MARK: - liveAirTraffic

/// What is actually available, and what is not.
///
/// There is **no keyless source of future flight schedules**. Every schedule API
/// (AviationStack, AirLabs, FlightAware, Schiphol) requires an API key, so a
/// question like "what is the next flight leaving JFK" cannot be answered
/// truthfully from public data alone.
///
/// What *is* available is observed ADS-B traffic: aircraft transmitting near an
/// airport right now. That answers "what is flying near JFK" — bounded to
/// aircraft in range, which is honest but narrower than a timetable. The tool
/// description says so explicitly, so the model does not promise more than it
/// can deliver.
///
/// OpenSky was the other candidate and is avoided on purpose: its anonymous
/// quota is roughly 400 credits/day, and a single departure query costs several.
/// Probing exhausted it and returned `429` with an 86,201-second retry. adsb.lol
/// has no such limit in testing.
struct AirTrafficTool: AssistantTool {
    let name = "liveAirTraffic"
    let summary = """
    Show aircraft currently transmitting near an airport, from live ADS-B data. \
    Use for 'what is flying near/around <airport>' questions. Give the airport \
    code (JFK, LHR) or its name (Heathrow). This reports aircraft observed in \
    the air near the airport within roughly the last minute. It is NOT a flight \
    timetable: it cannot show scheduled or future departures and arrivals, so do \
    not use it to answer questions about upcoming flights.
    """

    typealias Arguments = AirportArguments

    func run(_ arguments: AirportArguments) async throws -> String {
        let query = arguments.airport.trimmingCharacters(in: .whitespaces)

        guard let airport = try await Airports.lookup(query: query) else {
            return "error: no airport found matching '\(query)'. Try an IATA code such as JFK or LHR."
        }

        let url = URL(
            string: "https://api.adsb.lol/v2/point/\(airport.latitude)/\(airport.longitude)/15"
        )!

        let payload: ADSBResponse = try await HTTP.getJSON(url, as: ADSBResponse.self)
        let airborne = payload.ac.filter { ($0.gs ?? 0) > 50 }
        guard !airborne.isEmpty else {
            return "No aircraft are currently transmitting near \(airport.name) — live ADS-B observations, not a timetable."
        }

        let lines = airborne.prefix(8).map { aircraft -> String in
            let callsign = aircraft.flight?.trimmingCharacters(in: .whitespaces) ?? "unknown"
            var line = callsign
            if let type = aircraft.t { line += " (\(type))" }
            if let altitude = aircraft.altBaro.value {
                line += ", \(altitude) ft"
            } else {
                line += ", altitude unavailable"
            }
            if let speed = aircraft.gs, let track = aircraft.track {
                line += String(format: ", %.0f kt heading %.0f°", speed, track)
            }
            return line
        }

        return """
        Aircraft currently in the air near \(airport.name) — \
        live ADS-B observations, not a timetable:
        """ + "\n" + lines.joined(separator: "\n")
    }
}

struct ADSBResponse: Decodable {
    var ac: [Aircraft]

    struct Aircraft: Decodable {
        var flight: String?
        var t: String?
        var alt_baro: HTTP.LooseInt?
        var gs: Double?
        var track: Double?

        var altBaro: HTTP.LooseInt { alt_baro ?? HTTP.LooseInt(value: nil) }
    }
}

struct Airport {
    var name: String
    var latitude: Double
    var longitude: Double
}

enum Airports {
    private static let cache = Cache()

    /// Resolve an airport from either a 3-letter IATA code, a 4-letter ICAO code,
    /// or a plain name like "Heathrow". Codes go to airport-data.com; names fall
    /// back to Wikipedia's coordinates, which is what makes "near Heathrow" work
    /// without shipping a 9 MB airport database.
    static func lookup(query: String) async throws -> Airport? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let key = trimmed.uppercased()
        if let cached = cache.value(for: key) { return cached }

        if key.count == 3 || key.count == 4, key.allSatisfy(\.isLetter) {
            if let airport = try? await lookup(code: key) {
                cache.store(airport, for: key)
                return airport
            }
        }

        // Treat it as a name. Wikipedia's summary carries the coordinates.
        guard let summary = try? await Wikipedia.summary(of: trimmed),
              let coordinates = summary.coordinates else { return nil }

        let airport = Airport(
            name: summary.title,
            latitude: coordinates.lat,
            longitude: coordinates.lon
        )
        cache.store(airport, for: key)
        return airport
    }

    private static func lookup(code: String) async throws -> Airport? {
        struct Entry: Decodable {
            var name: String?
            var latitude: HTTP.LooseDouble?
            var longitude: HTTP.LooseDouble?
        }

        let field = code.count == 3 ? "iata" : "icao"
        let url = URL(string: "https://airport-data.com/api/ap_info.json?\(field)=\(code)")!
        let entry: Entry = try await HTTP.getJSON(url, as: Entry.self)

        guard let name = entry.name,
              let latitude = entry.latitude?.value,
              let longitude = entry.longitude?.value else { return nil }

        return Airport(name: name, latitude: latitude, longitude: longitude)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: Airport] = [:]

        func value(for key: String) -> Airport? {
            lock.lock(); defer { lock.unlock() }
            return table[key]
        }

        func store(_ airport: Airport, for key: String) {
            lock.lock(); defer { lock.unlock() }
            table[key] = airport
        }
    }
}
