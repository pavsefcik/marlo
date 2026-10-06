import Foundation
import FoundationModels

/// Saved conversations, as JSON on disk.
///
/// `Transcript` is `Codable`, so a session is essentially the transcript plus
/// enough context to restore it sensibly: when it was saved, how many turns it
/// has, and the first thing the user asked, which is the only good name for it.
public struct SavedSession: Sendable, Identifiable, Equatable {
    public var id: String { name }
    /// Slug used as the filename and typed after `/resume`.
    public let name: String
    /// The first thing the user asked, or nil for an empty session.
    public let firstMessage: String?
    public let savedAt: Date
    /// Number of user turns, for a one-line summary.
    public let turns: Int
    /// Model and instructions in force when it was saved, so a resume can say
    /// when they differ from now.
    public let model: MarloModel
    public let hadCustomInstructions: Bool

    /// A short human line, e.g. `2h ago · 4 turns · what's the weather in Lisbon`.
    public var summary: String {
        let age = SavedSession.relative(savedAt)
        let turnText = turns == 1 ? "1 turn" : "\(turns) turns"
        let topic = firstMessage.map { String($0.prefix(48)) } ?? "(empty)"
        return "\(age) · \(turnText) · \(topic)"
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// The on-disk shape. Separate from `SavedSession` so the list view does not
/// have to decode every transcript to show names and dates.
struct SessionFile: Codable {
    var name: String
    var savedAt: Date
    var model: String
    var hadCustomInstructions: Bool
    var firstMessage: String?
    var turns: Int
    var transcript: Transcript
}

public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL = SessionStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("marlo/sessions")
    }

    // MARK: Writing

    /// Save a transcript, returning the name it was stored under.
    ///
    /// A name given by the user wins; otherwise one is derived from the first
    /// message, and made unique if it collides. The name is what `/resume`
    /// takes, so it has to be predictable rather than clever.
    @discardableResult
    public func save(
        transcript: Transcript,
        name requested: String?,
        model: MarloModel,
        hadCustomInstructions: Bool
    ) throws -> String {
        let firstMessage = SessionStore.firstUserMessage(in: transcript)
        let base = SessionStore.slug(from: requested ?? firstMessage ?? "session")
        let name = try uniqueName(base, requested: requested != nil)

        let file = SessionFile(
            name: name,
            savedAt: Date(),
            model: model.rawValue,
            hadCustomInstructions: hadCustomInstructions,
            firstMessage: firstMessage,
            turns: SessionStore.userTurnCount(in: transcript),
            transcript: transcript
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = SessionStore.dateEncoding
        try encoder.encode(file).write(to: url(for: name), options: .atomic)
        try writeLastUsed(name)
        return name
    }

    /// ISO-8601 with fractional seconds.
    ///
    /// The plain `.iso8601` strategy truncates to whole seconds, which makes two
    /// sessions saved in the same second indistinguishable — and since the list
    /// is ordered by this timestamp, "the most recent" would then be arbitrary.
    static let dateEncoding: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: date))
    }

    static let dateDecoding: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not an ISO-8601 date: \(text)"
            )
        }
        return date
    }

    /// Shared because `ISO8601DateFormatter` is expensive to build and this runs
    /// per session file. `nonisolated(unsafe)` because the type is not Sendable
    /// but `ISO8601DateFormatter` is documented thread-safe for formatting and
    /// parsing once its options are set, which happens exactly once here.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Reading

    public func load(_ name: String) throws -> (transcript: Transcript, model: MarloModel, savedAt: Date, firstMessage: String?) {
        let data = try Data(contentsOf: url(for: SessionStore.slug(from: name)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SessionStore.dateDecoding
        let file = try decoder.decode(SessionFile.self, from: data)
        let model = MarloModel(rawValue: file.model) ?? .system
        try writeLastUsed(file.name)
        return (file.transcript, model, file.savedAt, file.firstMessage)
    }

    /// The saved sessions, newest first.
    public func list() -> [SavedSession] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SessionStore.dateDecoding

        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SavedSession? in
                guard let data = try? Data(contentsOf: url),
                      let file = try? decoder.decode(SessionFile.self, from: data)
                else { return nil }
                return SavedSession(
                    name: file.name,
                    firstMessage: file.firstMessage,
                    savedAt: file.savedAt,
                    turns: file.turns,
                    model: MarloModel(rawValue: file.model) ?? .system,
                    hadCustomInstructions: file.hadCustomInstructions
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: url(for: SessionStore.slug(from: name)))
    }

    /// Every saved name, for completion.
    public var names: [String] {
        list().map(\.name)
    }

    /// The most recently saved session, for a bare `/resume`.
    public var mostRecent: SavedSession? {
        list().first
    }

    // MARK: Naming

    private func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).json")
    }

    /// A collision only matters when the user named it: they asked for that
    /// name, so the first free variant is used rather than overwriting. A name
    /// derived from a message is just an identifier and may be reused.
    private func uniqueName(_ base: String, requested: Bool) throws -> String {
        guard requested else { return base }
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: url(for: candidate).path) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private var lastUsedURL: URL {
        directory.appendingPathComponent(".last")
    }

    private func writeLastUsed(_ name: String) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? name.write(to: lastUsedURL, atomically: true, encoding: .utf8)
    }

    /// Lowercase, hyphenated, filesystem-safe, and never empty.
    public static func slug(from text: String) -> String {
        let allowed = text.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let joined = String(allowed)
        let parts = joined.split(separator: "-").map(String.init)
        let result = parts.joined(separator: "-")
        if result.isEmpty { return "session" }
        return String(result.prefix(48))
    }

    // MARK: Transcript inspection

    /// Text of the first user message, which is the only natural title a
    /// conversation has.
    public static func firstUserMessage(in transcript: Transcript) -> String? {
        for entry in transcript {
            guard case .prompt(let prompt) = entry else { continue }
            let text = prompt.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined(separator: " ")
            if !text.isEmpty { return text }
        }
        return nil
    }

    public static func userTurnCount(in transcript: Transcript) -> Int {
        transcript.reduce(0) { count, entry in
            if case .prompt = entry { return count + 1 }
            return count
        }
    }
}
