import MarloKit
import SwiftUI

// MARK: - Tool card

/// A tool call, shown inline in the transcript. The card is the unit of trust in
/// this UI: it shows exactly what ran, with what arguments, and what came back.
struct ToolCardView: View {
    let run: ToolRun

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon
                Text(run.name)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Text(run.prettyArguments)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)

            if !run.resultPreview.isEmpty {
                Divider()
                Text(run.resultPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(run.failed ? Color.red : Color.primary)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if run.isRunning {
            ProgressView().controlSize(.small)
        } else if run.failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .foregroundStyle(message.role == .user ? Color.secondary : Color.accentColor)
                    .font(.caption)
                Text(message.role == .user ? "You" : "Marlo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(message.tools) { tool in
                ToolCardView(run: tool)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Approval sheet

/// Blocks the turn until the user decides. A mutating tool cannot run until this
/// is answered, and "Cancel" is the default action.
struct ApprovalView: View {
    let approval: PendingApproval
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Approve tool run?", systemImage: "exclamationmark.shield")
                .font(.headline)

            Text("**\(approval.toolName)** wants to run with these arguments:")
                .font(.callout)

            ScrollView {
                Text(approval.prettyArguments)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))

            Text("This tool can change state. Nothing has run yet.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onResolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow Once") { onResolve(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Tools popover

struct ToolsView: View {
    @Bindable var model: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Allow network tools", isOn: Binding(
                get: { model.networkEnabled },
                set: { model.setNetworkTools(enabled: $0) }
            ))
            .font(.callout)

            Text("Off keeps everything on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.tools) { tool in
                        Toggle(isOn: Binding(
                            get: { tool.enabled },
                            set: { model.toggleTool(tool.name, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.name)
                                        .font(.system(.callout, design: .monospaced))
                                    if tool.mutating {
                                        Text("asks approval")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.orange.opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(tool.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Bindable var model: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask something, or ask it to use a tool…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(model.send)
                .disabled(!model.isAvailable)

            if model.isResponding {
                Button {
                    model.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.isAvailable)
                .help("Send")
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @Bindable var model: ChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty && model.streamingText.isEmpty {
                        EmptyStateView()
                    }

                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }

                    if model.isResponding || !model.streamingText.isEmpty {
                        // Rendered from the full snapshot each time: assignment,
                        // never append.
                        MessageRow(message: ChatMessage(
                            role: .assistant,
                            text: model.streamingText,
                            tools: model.streamingTools
                        ))
                        .id("streaming")
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .id("error")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Marlo")
                .font(.title2).fontWeight(.semibold)
            Text("A local assistant running on this Mac. Nothing leaves the machine unless you allow a network tool.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([
                    "What's the weather in Lisbon?",
                    "Who was Ada Lovelace?",
                    "Convert 100 USD to JPY",
                    "Remember that I prefer metric units",
                ], id: \.self) { example in
                    Text("· \(example)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 24)
    }
}
