import Foundation

/// The project version, in one place.
///
/// Three things need to agree on this number: the CLI (`marlo --version`), the
/// `.app` bundle `run-app.sh` assembles, and the release tags. Before this
/// existed, `run-app.sh` hardcoded `1.0` in its Info.plist and nothing else knew
/// a version at all, so the three could drift. `run-app.sh` now reads this file,
/// making a version bump a one-line change here.
public enum MarloVersion {
    /// Semantic version. Tag releases as `v` + this string.
    public static let current = "1.0.0"

    /// Human-readable line, e.g. for `marlo --version`.
    public static var line: String {
        "marlo \(current)"
    }
}
