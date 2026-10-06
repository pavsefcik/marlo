import Foundation

/// One in-session command.
///
/// The table below is the single source of truth for three things that would
/// otherwise drift apart: what `/help` prints, what typing `/` lists, and what
/// tab-completion offers. Adding a command in one place should add it
/// everywhere, so nothing here is derived by hand.
public struct MarloCommand: Sendable, Identifiable, Equatable {
    /// The canonical name, without the leading slash.
    public let name: String
    /// Other accepted spellings, without slashes.
    public let aliases: [String]
    /// Argument hint for help output, e.g. `on|off <name>`. Nil when the
    /// command takes no arguments.
    public let argument: String?
    /// One line describing what it does.
    public let summary: String
    /// How to supply completions for this command's first argument.
    public let completion: Completion

    public var id: String { name }

    /// The name as typed, with its slash.
    public var invocation: String { "/" + name }

    /// The command as shown in help: name plus argument hint.
    public var usage: String {
        argument.map { "\(invocation) \($0)" } ?? invocation
    }

    /// What a completion source offers for this command's argument.
    public enum Completion: Sendable, Equatable {
        /// A fixed set of words.
        case options([String])
        /// Nothing sensible to offer.
        case none
    }

    public init(
        name: String,
        aliases: [String] = [],
        argument: String? = nil,
        summary: String,
        completion: Completion = .none
    ) {
        self.name = name
        self.aliases = aliases
        self.argument = argument
        self.summary = summary
        self.completion = completion
    }
}

public enum MarloCommands {
    /// Every command, in the order `/help` and the menu show them.
    public static let all: [MarloCommand] = [
        MarloCommand(
            name: "help",
            aliases: ["?", "h"],
            summary: "Show this list"
        ),
        MarloCommand(
            name: "new",
            aliases: ["clear"],
            summary: "Start a new conversation"
        ),
        MarloCommand(
            name: "tools",
            argument: "[on|off|only|all|none] [names]",
            summary: "List or change which tools may run",
            completion: .options(["on", "off", "only", "all", "none"])
        ),
        MarloCommand(
            name: "style",
            argument: "[concise|balanced|expansive]",
            summary: "How long answers should be",
            completion: .options(ResponseStyle.allCases.map(\.rawValue))
        ),
        MarloCommand(
            name: "offline",
            argument: "[on|off]",
            summary: "Turn every network tool on or off",
            completion: .options(["on", "off"])
        ),
        MarloCommand(
            name: "instructions",
            argument: "[text|edit|reset]",
            summary: "Show or change the system instructions",
            completion: .options(["edit", "reset"])
        ),
        MarloCommand(
            name: "model",
            argument: "[system|pcc]",
            summary: "Show or switch the model",
            completion: .options(["system", "pcc"])
        ),
        MarloCommand(
            name: "save",
            argument: "[name]",
            summary: "Save this conversation"
        ),
        MarloCommand(
            name: "resume",
            argument: "[name]",
            summary: "Resume a saved conversation"
        ),
        MarloCommand(
            name: "sessions",
            summary: "List saved conversations"
        ),
        MarloCommand(
            name: "tokens",
            summary: "Show context usage"
        ),
        MarloCommand(
            name: "quit",
            aliases: ["exit", "q"],
            summary: "Leave marlo"
        ),
    ]

    /// Look up a command by any of its names, with or without a slash.
    public static func command(named name: String) -> MarloCommand? {
        let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let lowered = bare.lowercased()
        return all.first { $0.name == lowered || $0.aliases.contains(lowered) }
    }

    /// Every spelling a user could type, canonical names first. Used to build
    /// completion candidates.
    public static var allSpellings: [String] {
        all.flatMap { [$0.name] + $0.aliases }
    }

    /// The grouped, aligned help block, as `/help` prints it.
    public static func helpText() -> String {
        let width = all.map(\.usage.count).max() ?? 0
        let lines = all.map { command -> String in
            let padding = String(repeating: " ", count: max(0, width - command.usage.count))
            return "  \(command.usage)\(padding)  \(command.summary)"
        }
        return ([
            "COMMANDS",
            "",
        ] + lines + [
            "",
            "Tool choices, answer style and instructions are remembered between runs.",
            "With more than four tools on, each turn first picks which ones it needs,",
            "so the rest cost nothing until they are used.",
        ]).joined(separator: "\n")
    }
}
