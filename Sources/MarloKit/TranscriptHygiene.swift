import Foundation
import FoundationModels

extension Transcript {
    /// A copy that references only the tools named in `keeping`.
    ///
    /// Two things have to be dealt with when the visible tool set shrinks.
    ///
    /// **Stale definitions.** The framework records each turn's live tool
    /// definitions in the transcript's `instructions` entry, and keeps the calls
    /// and outputs that followed. Carrying that transcript into a session which
    /// no longer declares one of those tools hands the model a tool it cannot
    /// call — and it narrates a result for it rather than admitting the gap.
    /// The definitions are filtered and the calls that belong to them are
    /// dropped.
    ///
    /// **Lost results.** Dropping a tool's output entirely also drops the fact it
    /// established, and the model will invent a replacement when asked about it
    /// later. So the text of a hidden tool's output is folded into the
    /// instructions as established context. It reads as something the
    /// conversation already knows rather than as a pending tool result, and it
    /// costs a fraction of the schema it replaces.
    ///
    /// Entries that need no change are returned untouched, ids included, so
    /// applying this repeatedly is a no-op. That holds for the folded note too:
    /// once the tool outputs are gone there is nothing left to fold.
    public func restricted(to keeping: Set<String>) -> Transcript {
        // Text of tool outputs that are about to become invisible.
        var established: [String] = []
        for entry in self {
            guard case .toolOutput(let output) = entry, !keeping.contains(output.toolName) else { continue }
            let text = output.segments
                .compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }
                .joined(separator: " ")
            if !text.isEmpty {
                established.append("\(output.toolName) returned: \(text)")
            }
        }

        return Transcript(entries: compactMap { entry -> Transcript.Entry? in
            switch entry {
            case .instructions(var instructions):
                let kept = instructions.toolDefinitions.filter { keeping.contains($0.name) }
                let definitionsChanged = kept.count != instructions.toolDefinitions.count
                guard definitionsChanged || !established.isEmpty else { return entry }

                instructions.toolDefinitions = kept
                if !established.isEmpty {
                    instructions.segments.append(.text(Transcript.TextSegment(
                        content: """
                        Results already established in this conversation:
                        \(established.joined(separator: "\n"))
                        """
                    )))
                }
                return .instructions(instructions)

            case .toolCalls(let calls):
                let kept = calls.filter { keeping.contains($0.toolName) }
                guard kept.count != calls.count else { return entry }
                // Rebuilding preserves the id, which is what keeps this
                // idempotent: a fresh id would make every pass a new entry.
                return kept.isEmpty ? nil : .toolCalls(Transcript.ToolCalls(id: calls.id, kept))

            case .toolOutput(let output):
                return keeping.contains(output.toolName) ? entry : nil

            default:
                return entry
            }
        })
    }
}
