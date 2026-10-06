import MarloKit
import SwiftUI

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
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Bindable var model: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything…", text: $model.draft, axis: .vertical)
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
                            text: model.streamingText
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
            Text("A local chatbot running entirely on this Mac. Nothing leaves the machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach([
                    "Explain why the sky is blue",
                    "What's the difference between a stack and a queue?",
                    "Summarise the causes of the First World War",
                    "Draft a short email asking to reschedule a meeting",
                ], id: \.self) { example in
                    Text("· \(example)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 24)
    }
}
