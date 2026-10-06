import CReadline
import Foundation
import MarloKit

/// The editor currently installed as libedit's completion source.
///
/// libedit stores a bare C function pointer, which cannot capture context, so
/// the callback reaches the editor through this. There is exactly one line
/// editor per process and it is installed once before any reading begins, so a
/// single reference is sufficient.
nonisolated(unsafe) private var installedEditor: LineEditor?

/// Reads one line from the terminal, with history and tab completion.
///
/// Backed by the system readline (`libedit`) through `CReadline`. When stdin is
/// not a terminal there is nothing to complete and nothing to remember, so it
/// falls back to plain reads and piped input keeps working.
///
/// Completion is not purely cosmetic here. marlo's commands take arguments that
/// are enumerable — tool names, styles, session names — and getting one wrong
/// produces an error message rather than a result. Completing them is the
/// cheapest way to make the CLI feel like it knows its own shape.
final class LineEditor: @unchecked Sendable {
    /// Words offered for the first argument of each command.
    private let toolNames: () -> [String]
    private let sessionNames: () -> [String]

    /// Holds the C strings handed to libedit so they outlive the callback.
    ///
    /// libedit copies what it is given, but only after the callback returns, so
    /// the pointer has to stay valid until then. Caching the whole candidate
    /// list for the current completion is simpler than tracking one string, and
    /// the lists are tiny.
    private var completionBuffer: [UnsafeMutablePointer<CChar>] = []
    private var bufferedText: String?

    init(
        toolNames: @escaping () -> [String],
        sessionNames: @escaping () -> [String]
    ) {
        self.toolNames = toolNames
        self.sessionNames = sessionNames
    }

    deinit {
        releaseBuffer()
    }

    /// Wire the completion callback into libedit. Call once, before reading.
    func install() {
        installedEditor = self
        CReadline.marlo_readline_setup(LineEditor.completionCallback)
        isInstalled = true
    }

    private var isInstalled = false

    /// Non-capturing, as a C function pointer must be.
    private static let completionCallback: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> UnsafePointer<CChar>? = { line, word, index in
        guard let line, let word, let editor = installedEditor else { return nil }
        return editor.completionPointer(
            line: String(cString: line),
            word: String(cString: word),
            index: Int(index)
        )
    }

    /// Read a line. Returns nil at end of input.
    func read(prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1, isInstalled else {
            // No terminal: no editing, no completion. Read raw so a pipe works.
            guard let raw = CReadline.marlo_readline_plain() else { return nil }
            defer { free(raw) }
            return String(cString: raw)
        }

        guard let raw = CReadline.marlo_readline(prompt) else { return nil }
        defer { free(raw) }
        let line = String(cString: raw)
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            CReadline.marlo_readline_add_history(line)
        }
        return line
    }

    // MARK: Completion

    /// The candidate at `index`, as a pointer libedit copies after the call.
    ///
    /// libedit asks repeatedly, incrementing `index`, so the candidate list is
    /// computed once per distinct `text` and then indexed into.
    private func completionPointer(line: String, word: String, index: Int) -> UnsafePointer<CChar>? {
        let candidates = candidates(line: line, word: word)
        guard index >= 0, index < candidates.count else { return nil }

        // Recompute the buffer only when the input changes; libedit calls this
        // in a tight loop with the same line and rising indices.
        let key = line + "\u{0}" + word
        if key != bufferedText {
            releaseBuffer()
            completionBuffer = candidates.map { strdup($0) }
            bufferedText = key
        }
        guard index < completionBuffer.count else { return nil }
        return UnsafePointer(completionBuffer[index])
    }

    private func releaseBuffer() {
        for pointer in completionBuffer { free(pointer) }
        completionBuffer = []
        bufferedText = nil
    }

    /// Candidates for the word being completed, in the context of the line.
    ///
    /// Context comes from the words *before* the one being completed: a line
    /// with no space before the word is a command name, and a line with one is
    /// that command's first argument.
    func candidates(line: String, word: String) -> [String] {
        let words = line
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
        // Drop the word under the cursor; it is partial by definition.
        let preceding = words.dropLast()

        // No command yet: complete the command name itself.
        //
        // libedit replaces the *whole word* with what is returned, and the word
        // here includes the leading slash. So the candidates must carry it too:
        // returning `help` for `/hel` would erase the slash and turn a command
        // into a prompt.
        guard let commandWord = preceding.first else {
            guard word.hasPrefix("/") else { return [] }
            let prefix = word.dropFirst().lowercased()
            return MarloCommands.allSpellings
                .filter { $0.hasPrefix(prefix) }
                .map { "/" + $0 }
                .sorted()
        }

        guard let command = MarloCommands.command(named: commandWord) else { return [] }
        let argumentPrefix = word.lowercased()

        // `/tools` takes an action and then names, so it is the one command
        // completed at two depths. At depth 1 both are useful; at depth 2 only
        // names are, since a second action word would be a typo.
        if command.name == "tools" {
            let actions = ["on", "off", "only", "all", "none"]
            let atNames = preceding.count >= 2
            let pool = atNames ? toolNames() : actions + toolNames()
            guard preceding.count <= 2 else { return [] }
            return pool
                .filter { $0.lowercased().hasPrefix(argumentPrefix) }
                .sorted()
        }

        // Every other command takes a single argument.
        guard preceding.count <= 1 else { return [] }

        if command.name == "resume" {
            return sessionNames()
                .filter { $0.lowercased().hasPrefix(argumentPrefix) }
                .sorted()
        }

        guard case .options(let options) = command.completion else { return [] }
        return options.filter { $0.lowercased().hasPrefix(argumentPrefix) }
    }
}
