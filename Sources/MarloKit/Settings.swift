import Foundation

/// What Marlo should sound like.
///
/// The on-device model follows a length hint quite literally — measured at
/// roughly 27% of answer length between "keep answers short" and no hint at all —
/// so this is a real setting rather than a nicety. `balanced` is the default
/// because the earlier hard-coded "keep answers short and direct" was what made
/// ordinary questions come back clipped.
public enum ResponseStyle: String, CaseIterable, Sendable {
    case concise
    case balanced
    case expansive

    public var label: String {
        switch self {
        case .concise: "Concise"
        case .balanced: "Balanced"
        case .expansive: "Expansive"
        }
    }

    public var blurb: String {
        switch self {
        case .concise: "Short answers. Good for quick lookups."
        case .balanced: "Match the depth the question deserves."
        case .expansive: "Explain at length, with context and detail."
        }
    }

    /// Appended to the base instructions. Kept as a separate clause so the base
    /// prompt stays about behaviour and only this varies with the setting.
    ///
    /// Public because the agent takes it as a separate argument rather than a
    /// whole replacement prompt: the base instructions are not the user's to
    /// rewrite, only the length hint is.
    public var instruction: String {
        switch self {
        case .concise:
            "Keep answers short: a sentence or two unless asked for more."
        case .balanced:
            """
            Answer at the depth the question deserves. A quick question gets a \
            quick answer; a question that asks you to explain something deserves \
            a clear, developed answer with the reasoning shown.
            """
        case .expansive:
            """
            Answer thoroughly and at length. Develop the explanation, give \
            context and examples, and do not compress a rich subject into a \
            summary unless asked to.
            """
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
///
/// Every field has a working default, so a fresh install needs no setup. The
/// stored tool selection is authoritative once the user touches it: the master
/// switch turns tools off and back on without discarding which ones were on,
/// which is the behaviour a single switch implies.
public struct MarloSettings: Sendable, Equatable {
    /// The master switch. Off means every tool is hidden and no routing happens
    /// at all — the model answers from its own knowledge in one step.
    public var toolsEnabled: Bool

    /// Tools the user has left on. Only consulted when `toolsEnabled`.
    public var enabledTools: Set<String>

    public var responseStyle: ResponseStyle

    /// Above this many enabled tools, a turn is routed before it is answered:
    /// the model picks which tools it needs, and only those are declared. Below
    /// it, declaring them all costs less than the routing round-trip.
    public var routingThreshold: Int

    /// The base instructions, or nil for the built-in ones. Stored as an
    /// override rather than a copy of the default so a future change to
    /// `Agent.defaultInstructions` reaches anyone who never edited theirs.
    public var instructionsOverride: String?

    /// Which model to run on.
    public var model: MarloModel

    /// Curated, not everything. Twelve declarations cost roughly 1,150 tokens on
    /// *every* request before the user has typed anything, and most of these
    /// lookups are occasional. The rest are one toggle away.
    public static let defaultTools: Set<String> = [
        "getCurrentTime",
        "getWeather",
        "rememberFact",
        "recallMemory",
    ]

    public static let minimumRoutingThreshold = 2

    public init(
        toolsEnabled: Bool = true,
        enabledTools: Set<String> = MarloSettings.defaultTools,
        responseStyle: ResponseStyle = .balanced,
        routingThreshold: Int = 4,
        instructionsOverride: String? = nil,
        model: MarloModel = .system
    ) {
        self.toolsEnabled = toolsEnabled
        self.enabledTools = enabledTools
        self.responseStyle = responseStyle
        self.routingThreshold = max(routingThreshold, MarloSettings.minimumRoutingThreshold)
        self.instructionsOverride = instructionsOverride
        self.model = model
    }

    /// The instructions to run with: the override if set, otherwise the default.
    public var instructions: String {
        instructionsOverride ?? Agent.defaultInstructions
    }
}

/// Reads and writes `MarloSettings`, and hands out the current value.
///
/// A reference type so the agent and any UI share one source of truth rather
/// than each keeping a copy that can drift.
public final class SettingsStore: @unchecked Sendable {
    private enum Key {
        static let toolsEnabled = "marlo.toolsEnabled"
        static let enabledTools = "marlo.enabledTools"
        static let responseStyle = "marlo.responseStyle"
        static let routingThreshold = "marlo.routingThreshold"
        /// Set once the user has made any tool choice, so an upgrade that adds a
        /// new tool does not silently switch it on for them.
        static let toolsConfigured = "marlo.toolsConfigured"
        static let instructions = "marlo.instructions"
        static let model = "marlo.model"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: MarloSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = SettingsStore.load(from: defaults)
    }

    public var current: MarloSettings {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Replaces the stored settings and notifies observers.
    public func update(_ settings: MarloSettings) {
        lock.lock()
        cached = settings
        let value = cached
        lock.unlock()
        store(value)
    }

    /// Convenience for the single-switch case.
    public func setToolsEnabled(_ enabled: Bool) {
        var settings = current
        settings.toolsEnabled = enabled
        update(settings)
    }

    public func setEnabledTools(_ names: Set<String>) {
        var settings = current
        settings.enabledTools = names
        update(settings)
    }

    public func setResponseStyle(_ style: ResponseStyle) {
        var settings = current
        settings.responseStyle = style
        update(settings)
    }

    public func setRoutingThreshold(_ threshold: Int) {
        var settings = current
        settings.routingThreshold = max(threshold, MarloSettings.minimumRoutingThreshold)
        update(settings)
    }

    /// Set the instructions. Passing nil restores the built-in ones.
    public func setInstructions(_ text: String?) {
        var settings = current
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.instructionsOverride = (trimmed?.isEmpty ?? true) ? nil : trimmed
        update(settings)
    }

    public func setModel(_ choice: MarloModel) {
        var settings = current
        settings.model = choice
        update(settings)
    }

    // MARK: Persistence

    private func store(_ settings: MarloSettings) {
        defaults.set(settings.toolsEnabled, forKey: Key.toolsEnabled)
        defaults.set(Array(settings.enabledTools).sorted(), forKey: Key.enabledTools)
        defaults.set(settings.responseStyle.rawValue, forKey: Key.responseStyle)
        defaults.set(settings.routingThreshold, forKey: Key.routingThreshold)
        defaults.set(settings.model.rawValue, forKey: Key.model)
        if let text = settings.instructionsOverride {
            defaults.set(text, forKey: Key.instructions)
        } else {
            defaults.removeObject(forKey: Key.instructions)
        }
        defaults.set(true, forKey: Key.toolsConfigured)
    }

    private static func load(from defaults: UserDefaults) -> MarloSettings {
        var settings = MarloSettings()

        // `enabledTools` is only meaningful once the user has chosen. Before
        // that, the curated default applies. After that, their set wins — even
        // if it is empty — so turning everything off stays off across launches.
        if defaults.bool(forKey: Key.toolsConfigured),
           let stored = defaults.stringArray(forKey: Key.enabledTools) {
            settings.enabledTools = Set(stored)
        } else if defaults.bool(forKey: Key.toolsConfigured) {
            settings.enabledTools = []
        }

        if defaults.object(forKey: Key.toolsEnabled) != nil {
            settings.toolsEnabled = defaults.bool(forKey: Key.toolsEnabled)
        }

        if let raw = defaults.string(forKey: Key.responseStyle),
           let style = ResponseStyle(rawValue: raw) {
            settings.responseStyle = style
        }

        let threshold = defaults.integer(forKey: Key.routingThreshold)
        if threshold > 0 {
            settings.routingThreshold = max(threshold, MarloSettings.minimumRoutingThreshold)
        }

        if let text = defaults.string(forKey: Key.instructions), !text.isEmpty {
            settings.instructionsOverride = text
        }

        if let raw = defaults.string(forKey: Key.model),
           let choice = MarloModel(rawValue: raw) {
            settings.model = choice
        }

        return settings
    }
}
