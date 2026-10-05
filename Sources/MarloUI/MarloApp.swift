import MarloKit
import SwiftUI

/// Marlo's app shell.
///
/// A `MenuBarExtra` with a `.window` style gives a real resizable panel that
/// appears under the menu-bar icon on click — the fastest path to the assistant
/// without a Dock icon or a window to manage. A full window is available from the
/// footer for longer sessions.
@main
struct MarloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ChatViewModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // A quiet indicator: the icon itself shows when the model is thinking.
            Image(systemName: model.isResponding ? "sparkles.rectangle.stack.fill" : "sparkles")
        }
        .menuBarExtraStyle(.window)

        Window("Marlo", id: "main") {
            PanelView(model: model, isFullWindow: true)
                .frame(minWidth: 520, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 680, height: 720)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Marlo lives in the menu bar, so it must not take a Dock icon or steal focus
/// on launch. A bare SwiftPM executable does both by default; `LSUIElement` in a
/// bundle's Info.plist would also cover this, but setting the activation policy
/// here means the app behaves correctly even when run straight from
/// `.build/` during development.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// The panel shown in both the menu-bar popover and the full window.
struct PanelView: View {
    @Bindable var model: ChatViewModel
    var isFullWindow = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.isAvailable {
                UnavailableBanner(reason: model.unavailableReason)
            } else {
                TranscriptView(model: model)
                Divider()
                ComposerView(model: model)
                Divider()
                StatusBar(model: model, isFullWindow: isFullWindow)
            }
        }
        .frame(
            minWidth: isFullWindow ? nil : 420,
            idealWidth: isFullWindow ? nil : 460,
            minHeight: isFullWindow ? nil : 360,
            idealHeight: isFullWindow ? nil : 520
        )
        .task { await model.start() }
        .sheet(item: $model.pendingApproval) { approval in
            ApprovalView(approval: approval) { model.resolveApproval($0) }
        }
    }
}

/// Shown when the model cannot run, with what to do about it.
struct UnavailableBanner: View {
    let reason: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Marlo can't start")
                .font(.headline)
            if let reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Footer: context meter, tool access, and session controls.
struct StatusBar: View {
    @Bindable var model: ChatViewModel
    var isFullWindow = false

    var body: some View {
        HStack(spacing: 10) {
            // Context meter: honest about how full the window is, since overflow
            // is a hard failure. Turns amber then red as it fills.
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2)
                Text("\(model.usedTokens)/\(model.contextLimit)")
                    .font(.system(.caption2, design: .monospaced))
            }
            .foregroundStyle(meterColor)
            .help("Tokens used in this conversation, including tool schemas")

            if let status = model.status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                Toggle("Auto-approve mutating tools", isOn: $model.autoApprove)
                Divider()
                ForEach(model.tools) { tool in
                    Toggle(tool.name, isOn: Binding(
                        get: { tool.enabled },
                        set: { model.toggleTool(tool.name, enabled: $0) }
                    ))
                }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tools")

            Button {
                model.newConversation()
            } label: {
                Image(systemName: "square.and.pencil").font(.caption)
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .disabled(model.messages.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var meterColor: Color {
        switch model.contextFraction {
        case ..<0.6: .secondary
        case ..<0.85: .orange
        default: .red
        }
    }
}

/// Real settings, in the standard ⌘, location.
struct SettingsView: View {
    @Bindable var model: ChatViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Auto-approve mutating tools", isOn: $model.autoApprove)
                Text("When off, Marlo asks before a tool that changes state runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Network") {
                Toggle("Allow network tools", isOn: Binding(
                    get: { model.networkEnabled },
                    set: { model.setNetworkTools(enabled: $0) }
                ))
                Text("Weather, Wikipedia, currency, crypto, air quality, sunrise, earthquakes, holidays and air traffic. Off means every answer comes from the on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Memory") {
                Text(MemoryStore.defaultURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MemoryStore.defaultURL])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { await model.start() }
    }
}
