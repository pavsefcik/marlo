import MarloKit
import SwiftUI

/// Marlo's app shell.
///
/// A `MenuBarExtra` with a `.window` style gives a real resizable panel that
/// appears under the menu-bar icon on click — the fastest path to the assistant
/// without a Dock icon or a window to manage. The footer's window button breaks
/// free into a normal app window; closing it returns the app to the menu bar.
@main
struct MarloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ChatViewModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // The label stays alive for the app's whole lifetime, which makes it
            // the one reliable place to answer the Dock icon's "reopen" call.
            MenuBarLabel(model: model)
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

/// The menu-bar icon, plus the Dock-icon reopen bridge.
struct MenuBarLabel: View {
    let model: ChatViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A quiet indicator: the icon itself shows when the model is thinking.
        Image(systemName: model.isResponding ? "sparkles.rectangle.stack.fill" : "sparkles")
            // Posted by the delegate when the Dock icon is clicked and the window
            // is gone; the label is always mounted, so it can open it again.
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openMainWindow)) { _ in
                openWindow(id: "main")
            }
    }
}

/// Marlo lives in the menu bar, so it must not take a Dock icon or steal focus
/// on launch. A bare SwiftPM executable does both by default; `LSUIElement` in a
/// bundle's Info.plist would also cover this, but setting the activation policy
/// here means the app behaves correctly even when run straight from
/// `.build/` during development.
///
/// The policy is not permanent: opening the full window promotes the app to
/// `.regular` so the window can be focused and managed like any other app's.
/// Closing that window drops it back into the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The view layer needs the delegate to promote and demote the app; SwiftUI
    /// only hands the adaptor to the `App` body, so stash a reference here.
    static weak var shared: AppDelegate?

    /// The `NSWindow` behind the full-window scene, captured when it appears.
    /// Holding it lets the Dock icon re-show the same window instead of asking
    /// SwiftUI to reconstruct the scene.
    private weak var mainWindow: NSWindow?
    private var mainWindowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Break free of the menu bar: take a Dock icon and become frontmost so the
    /// full window behaves like a normal app window.
    func enterFullMode() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        registerCloseObserver()
    }

    /// Recorded by the full window when it appears, wherever the `Window` scene
    /// opened it — the footer button, state restoration, or the Dock icon.
    func adopt(mainWindow window: NSWindow) {
        // Called on every layout pass of the view that reports its window, so
        // bail out once the window is already known — otherwise `activate()`
        // would keep stealing focus.
        guard mainWindow !== window else { return }
        mainWindow = window
        enterFullMode()
    }

    /// Brings the full window forward, recreating it if SwiftUI has released it.
    func showMainWindow() {
        // Promote unconditionally: the window may reappear without the grabber
        // running again (a retained, merely hidden window), and an accessory app
        // cannot focus a window it shows.
        enterFullMode()
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            // No window left to show: let the scene recreate one, which will
            // call `adopt(mainWindow:)` too.
            NotificationCenter.default.post(name: AppDelegate.openMainWindow, object: nil)
        }
    }

    /// Reopens the main window when the Dock icon is clicked and none is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        showMainWindow()
        return true
    }

    static let openMainWindow = Notification.Name("MarloOpenMainWindow")

    private func registerCloseObserver() {
        guard mainWindowCloseObserver == nil else { return }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            // The observer fires on the main queue (specified above), so this is
            // a formality of the compiler, not a real suspension.
            MainActor.assumeIsolated {
                guard let window, self?.owns(window) == true else { return }
                self?.mainWindow = nil
                self?.exitFullMode()
            }
        }
    }

    /// Whether `window` is the full-window scene's window. Compared by identity,
    /// not title or identifier, so the menu-bar popover can never be mistaken
    /// for it — closing the popover must not drop us out of full mode.
    func owns(_ window: NSWindow) -> Bool {
        mainWindow === window
    }

    /// Collapse back into the menu bar once there is no window to manage.
    func exitFullMode() {
        if let observer = mainWindowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            mainWindowCloseObserver = nil
        }
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
        // The full window promotes the app out of the menu bar the moment it
        // appears, whatever opened it.
        .background {
            if isFullWindow {
                WindowGrabber { AppDelegate.shared?.adopt(mainWindow: $0) }
            }
        }
        .task { await model.start() }
    }
}

/// Reports the `NSWindow` hosting this view, once it exists.
private struct WindowGrabber: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The window only exists after the view joins the hierarchy, so this
        // cannot run during make/update synchronously.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow(window)
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

/// Footer: context meter, window controls, and the new-conversation button.
struct StatusBar: View {
    @Bindable var model: ChatViewModel
    var isFullWindow = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

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
            .help("Tokens in the last request, as the framework counted them")

            if let status = model.status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // The way out of the menu bar. Opening the full window promotes the
            // app (see `WindowGrabber`); closing it drops back to menu-bar-only.
            if isFullWindow {
                Button {
                    dismissWindow(id: "main")
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Collapse back into the menu bar")
            } else {
                Button {
                    // Capture the popover first: the button is inside it, so it
                    // is the current key window.
                    let panel = NSApp.keyWindow
                    // SwiftUI owns the scene: opening it focuses the existing
                    // window if there is one, or creates it otherwise. Either
                    // way the window promotes us out of the menu bar on appear.
                    openWindow(id: "main")
                    // If activation didn't already dismiss the popover, do it.
                    // Skipped when the clicked window is somehow already the
                    // full window, which we must never close from here.
                    DispatchQueue.main.async {
                        guard let panel, panel.isVisible else { return }
                        guard AppDelegate.shared?.owns(panel) != true else { return }
                        panel.close()
                    }
                } label: {
                    Image(systemName: "macwindow.on.rectangle").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open in a full window")
            }

            Button {
                model.newConversation()
            } label: {
                Image(systemName: "square.and.pencil").font(.caption)
            }
            .buttonStyle(.plain)
            .help("New conversation")
            .disabled(!model.hasConversation)
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
            Section("Answers") {
                Picker("Length", selection: Binding(
                    get: { model.settings.responseStyle },
                    set: { model.setResponseStyle($0) }
                )) {
                    ForEach(ResponseStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.settings.responseStyle.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .task { await model.start() }
    }
}
