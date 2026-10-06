import Foundation
import FoundationModels

/// Something a front end has to do itself after a command runs.
///
/// Most commands are just text in and text out. These few are not: they either
/// end the process or need the interface's own input, and no amount of string
/// output substitutes for that.
public enum CommandFollowUp: Sendable, Equatable {
    /// Leave. The CLI exits; the app terminates.
    case quit
    /// Ask the user for new instructions in whatever way that front end can —
    /// a multi-line prompt in the terminal, a text sheet in the app.
    case editInstructions
}

/// What running a command produced.
public struct CommandOutcome: Sendable, Equatable {
    /// Text to show the user. May be empty, and may be several lines.
    public var output: String
    /// The conversation was thrown away or replaced wholesale, so a front end
    /// holding its own copy of the messages must resync from the agent.
    public var conversationReplaced: Bool
    /// Work the front end must do itself, if any.
    public var followUp: CommandFollowUp?

    public init(output: String = "", conversationReplaced: Bool = false, followUp: CommandFollowUp? = nil) {
        self.output = output
        self.conversationReplaced = conversationReplaced
        self.followUp = followUp
    }
}

/// Runs in-session commands against an agent.
///
/// This exists so the CLI and the app cannot disagree about what `/tools off
/// getWeather` does. Both build one of these around the same agent and settings
/// stores, and both render `CommandOutcome.output` however they like.
///
/// An actor because every command touches the agent, which is itself an actor,
/// and because two commands arriving at once would otherwise interleave their
/// settings writes.
public actor CommandRunner {
    private let agent: Agent
    private let settingsStore: SettingsStore
    private let sessions: SessionStore

    public init(agent: Agent, settingsStore: SettingsStore, sessions: SessionStore = SessionStore()) {
        self.agent = agent
        self.settingsStore = settingsStore
        self.sessions = sessions
    }

    /// The store, for a front end that wants to list or delete sessions itself.
    public var sessionStore: SessionStore { sessions }

    /// Run `input` if it is a command.
    ///
    /// Returns nil for anything that is not a slash command, which is the
    /// caller's cue to send it to the model as a prompt. An unknown command is
    /// *not* nil: it produces help text, because "I don't know that command" is
    /// a command outcome, not a question for the model.
    public func run(_ input: String) async -> CommandOutcome? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        // A bare slash means "what commands are there", which is what it means
        // everywhere else that offers slash commands.
        if trimmed == "/" {
            return CommandOutcome(output: MarloCommands.helpText())
        }

        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let word = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        guard let command = MarloCommands.command(named: word) else {
            return CommandOutcome(output: "unknown command: /\(word)\n\n" + MarloCommands.helpText())
        }

        switch command.name {
        case "quit":
            return CommandOutcome(followUp: .quit)

        case "help":
            return CommandOutcome(output: MarloCommands.helpText())

        case "new":
            await agent.reset()
            return CommandOutcome(output: "started a new conversation", conversationReplaced: true)

        case "tokens":
            return CommandOutcome(output: await tokenReport())

        case "style":
            return await runStyle(argument)

        case "tools":
            return await runTools(argument)

        case "offline":
            return await runOffline(argument)

        case "instructions":
            return await runInstructions(argument)

        case "model":
            return await runModel(argument)

        case "save":
            return await save(named: argument.isEmpty ? nil : argument)

        case "sessions":
            return listSessions()

        case "resume":
            return await resume(named: argument.isEmpty ? nil : argument)

        default:
            return CommandOutcome(output: "/\(command.name) is listed but not implemented")
        }
    }

    // MARK: Commands

    private func tokenReport() async -> String {
        let used = await agent.reportedTokens()
        let limit = await agent.contextSize
        let percent = limit > 0 ? used * 100 / limit : 0
        return "\(used) / \(limit) tokens (\(percent)%)"
    }

    private func runStyle(_ argument: String) async -> CommandOutcome {
        guard !argument.isEmpty else {
            let lines = ResponseStyle.allCases.map { style -> String in
                let mark = style == settingsStore.current.responseStyle ? "*" : " "
                return "\(mark) \(style.label.lowercased()) — \(style.blurb)"
            }
            return CommandOutcome(output: (lines + ["", "/style concise | balanced | expansive"]).joined(separator: "\n"))
        }

        guard let style = ResponseStyle(rawValue: argument.lowercased()) else {
            return CommandOutcome(output: "unknown style: \(argument). Use concise, balanced or expansive.")
        }

        settingsStore.setResponseStyle(style)
        await agent.apply(settings: settingsStore.current)
        return CommandOutcome(output: "answers will be \(style.label.lowercased())")
    }

    private func runTools(_ argument: String) async -> CommandOutcome {
        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let action = parts.first?.lowercased() ?? ""
        let names = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []

        guard !action.isEmpty else {
            var lines: [String] = []
            for tool in await agent.describeTools() {
                let flag = tool.mutating ? " [asks approval]" : ""
                let state = tool.enabled ? "on " : "off"
                lines.append("[\(state)] \(tool.name)\(flag)")
                lines.append("    \(tool.summary)")
            }
            lines.append("routing: \(settingsStore.current.routingThreshold)+ enabled tools are narrowed per turn")
            lines.append("")
            lines.append(MarloCommands.command(named: "tools")?.usage ?? "/tools")
            return CommandOutcome(output: lines.joined(separator: "\n"))
        }

        var settings = settingsStore.current
        var lines: [String] = []

        switch action {
        case "on", "off", "enable", "disable":
            let enabled = action == "on" || action == "enable"
            guard !names.isEmpty else {
                return CommandOutcome(output: "usage: /tools \(enabled ? "on" : "off") <name>[,<name>...]")
            }
            for name in names {
                let known = await agent.setTool(name, enabled: enabled)
                if known {
                    if enabled { settings.enabledTools.insert(name) } else { settings.enabledTools.remove(name) }
                    lines.append("\(name): \(enabled ? "enabled" : "disabled")")
                } else {
                    lines.append("unknown tool: \(name)")
                }
            }
            settings.toolsEnabled = !settings.enabledTools.isEmpty

        case "only":
            guard !names.isEmpty else {
                return CommandOutcome(output: "usage: /tools only <name>[,<name>...]")
            }
            let known = Set(await agent.toolNames)
            for name in names where !known.contains(name) { lines.append("unknown tool: \(name)") }
            let keep = names.filter { known.contains($0) }
            await agent.setEnabledTools(Set(keep))
            settings.enabledTools = Set(keep)
            settings.toolsEnabled = !keep.isEmpty
            lines.append("enabled: \(keep.joined(separator: ", "))")

        case "all":
            let all = Set(await agent.toolNames)
            await agent.setEnabledTools(all)
            settings.enabledTools = all
            settings.toolsEnabled = true
            lines.append("all tools enabled")

        case "none":
            await agent.setEnabledTools([])
            settings.toolsEnabled = false
            lines.append("all tools disabled — answers come from the model alone")

        default:
            return CommandOutcome(output: "usage: " + (MarloCommands.command(named: "tools")?.usage ?? "/tools"))
        }

        settingsStore.update(settings)
        await agent.apply(settings: settings)
        return CommandOutcome(output: lines.joined(separator: "\n"))
    }

    private func runOffline(_ argument: String) async -> CommandOutcome {
        let networkNames = await agent.networkToolNames
        let enabled = Set(await agent.enabledToolNames)
        let anyNetworkOn = networkNames.contains { enabled.contains($0) }

        // Bare `/offline` toggles: if any network tool is on, turn them all off;
        // if none are on, turn them all back on. An explicit on/off is absolute.
        let turnOn: Bool
        switch argument.lowercased() {
        case "on", "enable": turnOn = true
        case "off", "disable": turnOn = false
        case "": turnOn = !anyNetworkOn
        default:
            return CommandOutcome(output: "usage: /offline [on|off]")
        }

        var settings = settingsStore.current
        for name in networkNames {
            await agent.setTool(name, enabled: turnOn)
            if turnOn { settings.enabledTools.insert(name) } else { settings.enabledTools.remove(name) }
        }
        settingsStore.update(settings)
        await agent.apply(settings: settings)
        return CommandOutcome(output: turnOn
            ? "network tools on"
            : "network tools off — other tools still apply")
    }

    private func runInstructions(_ argument: String) async -> CommandOutcome {
        switch argument.lowercased() {
        case "":
            let current = await agent.currentInstructions
            return CommandOutcome(output: """
            \(current)

            /instructions <text>   replace them
            /instructions edit     replace them interactively
            /instructions reset    back to the built-in instructions
            """)

        case "edit":
            // Needs the front end: a terminal reads lines, the app shows a sheet.
            return CommandOutcome(followUp: .editInstructions)

        case "reset":
            await agent.resetInstructions()
            settingsStore.setInstructions(nil)
            return CommandOutcome(output: "instructions reset to the defaults")

        default:
            await setInstructions(argument)
            return CommandOutcome(output: "instructions updated (\(argument.count) characters)")
        }
    }

    /// Set the instructions from a front end that gathered them itself.
    public func setInstructions(_ text: String) async {
        await agent.setInstructions(text)
        settingsStore.setInstructions(text)
    }

    /// Replace the instructions with the built-in ones.
    public func resetInstructions() async {
        await agent.resetInstructions()
        settingsStore.setInstructions(nil)
    }

    private func runModel(_ argument: String) async -> CommandOutcome {
        let current = await agent.model

        guard !argument.isEmpty else {
            var lines: [String] = []
            for choice in MarloModel.allCases {
                let mark = choice == current ? "*" : " "
                let availability = choice.availability
                let status = availability.isAvailable ? "" : "  (unavailable)"
                lines.append("\(mark) \(choice.rawValue) — \(choice.blurb)\(status)")
                if let reason = availability.reason {
                    lines.append("    \(reason)")
                }
            }
            lines.append("")
            lines.append("/model system | pcc")
            return CommandOutcome(output: lines.joined(separator: "\n"))
        }

        guard let choice = MarloModel(rawValue: argument.lowercased()) else {
            return CommandOutcome(output: "unknown model: \(argument). Use system or pcc.")
        }

        var caveat = ""
        if case .unavailable(let reason) = choice.availability {
            // Switch anyway if asked explicitly, but say what to expect rather
            // than reporting success and failing on the next question.
            caveat = "note: \(reason)\n"
        }

        await agent.setModel(choice)
        settingsStore.setModel(choice)
        return CommandOutcome(output: caveat + "model is now \(choice.label)")
    }

    private func save(named name: String?) async -> CommandOutcome {
        let transcript = await agent.transcript
        guard !transcript.isEmpty else {
            return CommandOutcome(output: "nothing to save yet")
        }
        do {
            let settings = settingsStore.current
            let stored = try sessions.save(
                transcript: transcript,
                name: name,
                model: settings.model,
                hadCustomInstructions: settings.instructionsOverride != nil
            )
            return CommandOutcome(output: "saved as \(stored)\n/resume \(stored)")
        } catch {
            return CommandOutcome(output: "could not save: \(error.localizedDescription)")
        }
    }

    private func listSessions() -> CommandOutcome {
        let saved = sessions.list()
        guard !saved.isEmpty else {
            return CommandOutcome(output: "no saved conversations yet. /save to keep this one.")
        }
        var lines: [String] = []
        for session in saved {
            lines.append(session.name)
            lines.append("    \(session.summary)")
        }
        lines.append("")
        lines.append("stored in \(sessions.directory.path)")
        lines.append("/resume <name> | /resume to reopen the newest")
        return CommandOutcome(output: lines.joined(separator: "\n"))
    }

    private func resume(named name: String?) async -> CommandOutcome {
        let target: String
        if let name {
            target = name
        } else if let recent = sessions.mostRecent {
            target = recent.name
        } else {
            return CommandOutcome(output: "no saved conversations yet")
        }

        do {
            let loaded = try sessions.load(target)
            // Restore the model first so the transcript is rebuilt against the
            // right model, then let the agent restrict it to the visible tools.
            await agent.setModel(loaded.model)
            settingsStore.setModel(loaded.model)
            await agent.setTranscript(loaded.transcript)

            let turns = SessionStore.userTurnCount(in: loaded.transcript)
            let opening = loaded.firstMessage.map { String($0.prefix(60)) } ?? "(empty)"
            return CommandOutcome(
                output: "resumed \(target) · \(turns) turn\(turns == 1 ? "" : "s") · \(loaded.model.label)\n"
                    + "continuing: \(opening)…",
                conversationReplaced: true
            )
        } catch {
            return CommandOutcome(output: "could not resume \(target): \(error.localizedDescription)\n/sessions lists what is saved")
        }
    }
}
