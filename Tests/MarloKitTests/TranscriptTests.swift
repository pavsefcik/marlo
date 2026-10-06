import Foundation
import FoundationModels
import Testing
@testable import MarloKit

/// A tool that exists only to give the transcript a definition to record.
private struct StubTool<A: Generable>: Tool {
    let name: String
    let description: String
    func call(arguments: A) async throws -> String { "stub result" }
}

private func stub(_ name: String) -> any Tool {
    switch name {
    case "getWeather": StubTool<WeatherArguments>(name: name, description: "Weather.")
    case "getCurrentTime": StubTool<TimeArguments>(name: name, description: "Time.")
    default: StubTool<CityArguments>(name: name, description: "City facts.")
    }
}

/// A transcript that records instructions plus a tool call and its output, as a
/// real turn would leave behind.
private func transcript(calling name: String, output: String) -> Transcript {
    let tool = stub(name)
    // `GeneratedContent(json:)` throws; the tests build the argument blob from a
    // literal that is known to be valid, so a nil fallback is unreachable but
    // keeps the helper non-throwing.
    let arguments = (try? GeneratedContent(json: "{}")) ?? GeneratedContent("")
    return Transcript(entries: [
        .instructions(Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "Be helpful."))],
            toolDefinitions: [Transcript.ToolDefinition(tool: tool)]
        )),
        .prompt(Transcript.Prompt(segments: [
            .text(Transcript.TextSegment(content: "what is it?"))
        ])),
        .toolCalls(Transcript.ToolCalls([
            Transcript.ToolCall(id: "call-1", toolName: name, arguments: arguments)
        ])),
        .toolOutput(Transcript.ToolOutput(
            id: "out-1",
            toolName: name,
            segments: [.text(Transcript.TextSegment(content: output))]
        )),
    ])
}

@Suite("Transcript restriction")
struct TranscriptRestrictionTests {
    @Test("a restricted transcript drops the tool definition")
    func dropsDefinition() {
        let source = transcript(calling: "getWeather", output: "22C")
        let restricted = source.restricted(to: [])

        let definitions = restricted.compactMap { entry -> [Transcript.ToolDefinition]? in
            guard case .instructions(let i) = entry else { return nil }
            return i.toolDefinitions
        }.flatMap { $0 }
        #expect(definitions.isEmpty)
    }

    @Test("a restricted transcript drops the call and its output")
    func dropsCallAndOutput() {
        let restricted = transcript(calling: "getWeather", output: "22C").restricted(to: [])
        let hasCalls = restricted.contains { if case .toolCalls = $0 { return true } else { return false } }
        let hasOutput = restricted.contains { if case .toolOutput = $0 { return true } else { return false } }
        #expect(!hasCalls)
        #expect(!hasOutput)
    }

    @Test("the text of a hidden tool's output is kept as established context")
    func keepsOutputText() {
        // Without this the fact is lost and the model invents a replacement.
        let restricted = transcript(calling: "getWeather", output: "22C and clear").restricted(to: [])

        let instructions = restricted.compactMap { entry -> Transcript.Instructions? in
            guard case .instructions(let i) = entry else { return nil }
            return i
        }.first

        let text = instructions?.segments.compactMap { segment -> String? in
            guard case .text(let t) = segment else { return nil }
            return t.content
        }.joined() ?? ""
        #expect(text.contains("22C and clear"))
        #expect(text.contains("getWeather"))
    }

    @Test("a visible tool is left completely alone")
    func keepsVisibleTool() {
        let source = transcript(calling: "getWeather", output: "22C")
        let restricted = source.restricted(to: ["getWeather"])
        #expect(restricted == source)
    }

    @Test("restricting is idempotent")
    func idempotent() {
        // This is why the rewrite preserves entry ids: a fresh id on each pass
        // would make every application a new transcript.
        let once = transcript(calling: "getWeather", output: "22C").restricted(to: [])
        let twice = once.restricted(to: [])
        #expect(once == twice)
    }

    @Test("one hidden tool does not disturb another that stays visible")
    func partialRestriction() {
        let source = Transcript(entries: [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: "Be helpful."))],
                toolDefinitions: [
                    Transcript.ToolDefinition(tool: stub("getWeather")),
                    Transcript.ToolDefinition(tool: stub("getCurrentTime")),
                ]
            )),
            .toolOutput(Transcript.ToolOutput(
                id: "out-1",
                toolName: "getWeather",
                segments: [.text(Transcript.TextSegment(content: "22C"))]
            )),
            .toolOutput(Transcript.ToolOutput(
                id: "out-2",
                toolName: "getCurrentTime",
                segments: [.text(Transcript.TextSegment(content: "noon"))]
            )),
        ])
        let restricted = source.restricted(to: ["getCurrentTime"])

        let names = restricted.compactMap { entry -> String? in
            guard case .toolOutput(let o) = entry else { return nil }
            return o.toolName
        }
        #expect(names == ["getCurrentTime"])

        let definitions = restricted.compactMap { entry -> [Transcript.ToolDefinition]? in
            guard case .instructions(let i) = entry else { return nil }
            return i.toolDefinitions
        }.flatMap { $0 }.map(\.name)
        #expect(definitions == ["getCurrentTime"])
    }

    @Test("an empty transcript stays empty")
    func empty() {
        #expect(Transcript().restricted(to: []).isEmpty)
    }
}

@Suite("Agent session rebuild")
struct AgentSessionRebuildTests {
    /// The bug this guards: a session rebuilt with fewer tools used to carry the
    /// old definitions in its transcript, so the model would narrate a result
    /// for a tool that was no longer callable.
    @Test("disabling a tool removes its definition from the session")
    func disablingDropsDefinition() async {
        let tool: [AnyAssistantTool] = [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(WeatherTool()),
        ]
        let agent = Agent(definitions: tool)
        await agent.setTool("getWeather", enabled: false)

        let definitions = await agent.sessionToolNames
        #expect(definitions == ["getCurrentTime"])

        await agent.setAllTools(enabled: false)
        #expect(await agent.sessionToolNames.isEmpty)

        await agent.setAllTools(enabled: true)
        #expect(Set(await agent.sessionToolNames) == ["getCurrentTime", "getWeather"])
    }

    @Test("the enabled set is what the caller asked for")
    func enabledNames() async {
        let tool: [AnyAssistantTool] = [
            AnyAssistantTool(CurrentTimeTool()),
            AnyAssistantTool(WeatherTool()),
            AnyAssistantTool(WikipediaTool()),
        ]
        let agent = Agent(definitions: tool)
        await agent.setEnabledTools(["getWeather"])
        #expect(await agent.enabledToolNames == ["getWeather"])
    }
}
