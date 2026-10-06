import Foundation
import FoundationModels
import Testing
@testable import MarloKit

@Suite("Command table")
struct CommandTableTests {
    @Test("no two commands share a name or alias")
    func noCollisions() {
        var seen: [String: String] = [:]
        for command in MarloCommands.all {
            for spelling in [command.name] + command.aliases {
                if let owner = seen[spelling] {
                    Issue.record("'\(spelling)' is claimed by both '\(owner)' and '\(command.name)'")
                }
                seen[spelling] = command.name
            }
        }
    }

    @Test("every command has a summary and a valid name")
    func wellFormed() {
        for command in MarloCommands.all {
            #expect(!command.summary.isEmpty, "\(command.name) has no summary")
            #expect(!command.name.isEmpty)
            #expect(!command.name.hasPrefix("/"), "\(command.name) should not carry its slash")
            #expect(command.name == command.name.lowercased())
            #expect(!command.name.contains(" "))
        }
    }

    @Test("lookup accepts a name, an alias, and a leading slash")
    func lookup() {
        #expect(MarloCommands.command(named: "help")?.name == "help")
        #expect(MarloCommands.command(named: "/help")?.name == "help")
        #expect(MarloCommands.command(named: "/?")?.name == "help")
        #expect(MarloCommands.command(named: "q")?.name == "quit")
        #expect(MarloCommands.command(named: "/exit")?.name == "quit")
        #expect(MarloCommands.command(named: "/nope") == nil)
    }

    @Test("completion offers every spelling without the slash")
    func spellings() {
        // The editor adds the slash itself, because libedit replaces the whole
        // word including it.
        #expect(MarloCommands.allSpellings.allSatisfy { !$0.hasPrefix("/") })
        #expect(MarloCommands.allSpellings.contains("help"))
        #expect(MarloCommands.allSpellings.contains("?"))
        #expect(MarloCommands.allSpellings.contains("clear"))
    }

    @Test("help lists every command exactly once")
    func helpIsComplete() {
        let help = MarloCommands.helpText()
        for command in MarloCommands.all {
            let occurrences = help.components(separatedBy: command.usage).count - 1
            #expect(occurrences == 1, "\(command.usage) appears \(occurrences) times in help")
        }
    }

    @Test("help is aligned into columns")
    func helpAlignment() {
        // Every description should start at the same column, which is what makes
        // the list readable.
        let lines = MarloCommands.helpText()
            .split(separator: "\n")
            .filter { $0.hasPrefix("  /") }
        let columns = lines.compactMap { line -> Int? in
            // Column of the double space that precedes the summary.
            guard let range = line.range(of: "  ") else { return nil }
            return line.distance(from: line.startIndex, to: range.lowerBound)
        }
        #expect(!columns.isEmpty)
        #expect(Set(columns).count == 1, "descriptions start at \(Set(columns).sorted())")
    }

    @Test("the commands the user was promised are all present")
    func expectedCommands() {
        let names = Set(MarloCommands.all.map(\.name))
        for expected in [
            "help", "new", "tools", "style", "offline", "instructions",
            "model", "save", "resume", "sessions", "tokens", "quit",
        ] {
            #expect(names.contains(expected), "missing /\(expected)")
        }
    }
}

@Suite("Session naming")
struct SessionNamingTests {
    @Test("a message becomes a readable slug")
    func slug() {
        #expect(SessionStore.slug(from: "What's the weather in Lisbon?") == "what-s-the-weather-in-lisbon")
        #expect(SessionStore.slug(from: "  Spaces   and\nnewlines ") == "spaces-and-newlines")
        #expect(SessionStore.slug(from: "ÉMOJI 🎉 test") == "émoji-test")
    }

    @Test("a slug is never empty and never too long")
    func slugEdges() {
        #expect(SessionStore.slug(from: "") == "session")
        #expect(SessionStore.slug(from: "!!!") == "session")
        #expect(SessionStore.slug(from: String(repeating: "a", count: 200)).count <= 48)
    }

    @Test("a slug has no path separators")
    func slugIsFilesystemSafe() {
        // A slug becomes a filename, so a slash or a dot-dot would be a problem.
        let slug = SessionStore.slug(from: "../../etc/passwd")
        #expect(!slug.contains("/"))
        #expect(!slug.contains(".."))
    }
}

@Suite("Saved sessions")
struct SessionStoreTests {
    /// A throwaway directory so tests never touch the real store.
    private func tempStore() -> SessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("marlo-tests-\(UUID().uuidString)")
        return SessionStore(directory: directory)
    }

    private func transcript(asking questions: [String]) -> Transcript {
        var entries: [Transcript.Entry] = []
        for question in questions {
            entries.append(.prompt(Transcript.Prompt(segments: [
                .text(Transcript.TextSegment(content: question))
            ])))
            entries.append(.response(Transcript.Response(segments: [
                .text(Transcript.TextSegment(content: "answer to \(question)"))
            ])))
        }
        return Transcript(entries: entries)
    }

    @Test("a saved session round-trips")
    func roundTrip() throws {
        let store = tempStore()
        let original = transcript(asking: ["what is a monad?"])
        let name = try store.save(
            transcript: original,
            name: "monads",
            model: .system,
            hadCustomInstructions: false
        )
        #expect(name == "monads")

        let loaded = try store.load("monads")
        #expect(loaded.transcript == original)
        #expect(loaded.model == .system)
        #expect(loaded.firstMessage == "what is a monad?")
    }

    @Test("an unnamed session is named from its first message")
    func derivedName() throws {
        let store = tempStore()
        let name = try store.save(
            transcript: transcript(asking: ["What's the weather in Lisbon?"]),
            name: nil,
            model: .system,
            hadCustomInstructions: false
        )
        #expect(name == "what-s-the-weather-in-lisbon")
    }

    @Test("a requested name is not overwritten by a second save")
    func requestedNameIsKept() throws {
        let store = tempStore()
        let first = try store.save(
            transcript: transcript(asking: ["one"]),
            name: "notes",
            model: .system,
            hadCustomInstructions: false
        )
        let second = try store.save(
            transcript: transcript(asking: ["two"]),
            name: "notes",
            model: .system,
            hadCustomInstructions: false
        )
        #expect(first == "notes")
        #expect(second == "notes-2")
        // Both survive: the user named it, so it must not be silently replaced.
        #expect(Set(store.names) == ["notes", "notes-2"])
    }

    @Test("listing is newest first and carries a summary")
    func listing() async throws {
        let store = tempStore()
        try store.save(transcript: transcript(asking: ["first"]), name: "a", model: .system, hadCustomInstructions: false)
        try await Task.sleep(for: .milliseconds(20))
        try store.save(transcript: transcript(asking: ["second", "third"]), name: "b", model: .system, hadCustomInstructions: false)

        let list = store.list()
        #expect(list.map(\.name) == ["b", "a"])
        #expect(store.mostRecent?.name == "b")
        #expect(list[0].turns == 2)
        #expect(list[0].summary.contains("2 turns"))
        #expect(list[0].summary.contains("second"))
    }

    @Test("an empty store lists nothing and has no recent session")
    func empty() {
        let store = tempStore()
        #expect(store.list().isEmpty)
        #expect(store.mostRecent == nil)
        #expect(store.names.isEmpty)
    }

    @Test("deleting removes it from the list")
    func delete() throws {
        let store = tempStore()
        try store.save(transcript: transcript(asking: ["x"]), name: "gone", model: .system, hadCustomInstructions: false)
        #expect(store.names == ["gone"])
        try store.delete("gone")
        #expect(store.names.isEmpty)
    }

    @Test("a corrupt file is skipped rather than crashing the list")
    func corrupt() throws {
        let store = tempStore()
        try store.save(transcript: transcript(asking: ["good"]), name: "good", model: .system, hadCustomInstructions: false)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try "not json".write(
            to: store.directory.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )
        #expect(store.names == ["good"])
    }

    @Test("a resumed transcript still refuses tools that are gone")
    func resumeRestrictsTools() throws {
        // The point of saving is to reopen later, possibly with a different tool
        // set. Restriction has to be applied again on load or the model will
        // narrate a tool result it cannot produce.
        let store = tempStore()
        let withToolCall = Transcript(entries: [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: "be helpful"))],
                toolDefinitions: []
            )),
            .toolOutput(Transcript.ToolOutput(
                id: "out",
                toolName: "getCurrentTime",
                segments: [.text(Transcript.TextSegment(content: "3:38 AM"))]
            )),
        ])
        try store.save(transcript: withToolCall, name: "with-tool", model: .system, hadCustomInstructions: false)

        let loaded = try store.load("with-tool")
        let restricted = loaded.transcript.restricted(to: [])
        let hasOutput = restricted.contains {
            if case .toolOutput = $0 { return true }
            return false
        }
        #expect(!hasOutput)
    }

    @Test("the first message and turn count read the transcript correctly")
    func inspection() {
        let t = transcript(asking: ["one", "two", "three"])
        #expect(SessionStore.firstUserMessage(in: t) == "one")
        #expect(SessionStore.userTurnCount(in: t) == 3)
        #expect(SessionStore.firstUserMessage(in: Transcript()) == nil)
        #expect(SessionStore.userTurnCount(in: Transcript()) == 0)
    }
}
