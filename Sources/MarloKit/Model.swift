import Foundation
import FoundationModels

/// Which model a session runs on.
///
/// The framework offers exactly two: the on-device model and Private Cloud
/// Compute. This is a thin enum rather than a general registry because those
/// are the only two, and because their availability differs for reasons the
/// user needs to see — PCC requires Apple Intelligence and a context it
/// considers trustworthy, and reports itself available in places where every
/// request then fails.
public enum MarloModel: String, CaseIterable, Sendable {
    case system
    case pcc

    public var label: String {
        switch self {
        case .system: "System (on-device)"
        case .pcc: "Private Cloud Compute"
        }
    }

    public var blurb: String {
        switch self {
        case .system:
            "Apple's on-device model. Everything stays on this Mac."
        case .pcc:
            "Apple's larger server model. Requires Apple Intelligence and a supported context."
        }
    }

    /// The model as the framework's protocol type.
    ///
    /// Built per call rather than stored: `SystemLanguageModel` and
    /// `PrivateCloudComputeLanguageModel` are the only two, and asking for
    /// availability is cheap.
    public var languageModel: any LanguageModel {
        switch self {
        case .system: SystemLanguageModel.default
        case .pcc: PrivateCloudComputeLanguageModel()
        }
    }

    /// Whether the model can be used right now, and why not when it cannot.
    ///
    /// PCC is checked by trying it: `isAvailable` is true in contexts where
    /// every request then fails with "not available in this context", so
    /// reporting that flag verbatim would be a lie the user discovers on their
    /// first question.
    public var availability: ModelAvailability {
        switch self {
        case .system:
            return .available

        case .pcc:
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else {
                return .unavailable("Private Cloud Compute is not available on this Mac.")
            }
            // `isAvailable` is documented as the cheap check. The quota status
            // is the part that actually reflects whether requests will work.
            if case .belowLimit = model.quotaUsage.status {
                return .available
            }
            return .unavailable("Private Cloud Compute quota is exhausted. \(model.quotaUsage)")
        }
    }

    public enum ModelAvailability: Sendable {
        case available
        case unavailable(String)

        public var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        public var reason: String? {
            if case .unavailable(let text) = self { return text }
            return nil
        }
    }
}
