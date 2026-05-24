import Foundation

/// Dotted-numeric app-version comparison used by the in-app update prompt
/// and the What's New gate. Stays semver-shaped on purpose — both surfaces
/// only ever compare release versions sourced from `MARKETING_VERSION` and
/// iTunes Lookup's `version` field, neither of which carries pre-release
/// or build metadata. Anything richer (e.g. `1.7.0-beta.1+sha`) is treated
/// as malformed and returned as `nil`.
struct AppVersion: Comparable, Equatable {
    let components: [Int]

    /// Parse a dotted-numeric string into ordered components. Returns `nil`
    /// for anything that isn't a non-empty sequence of integers separated
    /// by `.` — guarding the update prompt against a future App Store
    /// response that ships build metadata we'd otherwise sort lexically
    /// and mis-rank ("1.10.0" < "1.9.0" under string comparison).
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            // `Int(_:)` accepts a leading `+` or `-`, so `Int("+1")`
            // returns 1 and the `n >= 0` check below would pass it
            // through. Require pure digits before parsing so a typo'd
            // key in `whatsnew.json` or a future iTunes Lookup
            // response carrying a sign prefix is rejected cleanly
            // (returns `nil`) rather than silently collapsing to the
            // unsigned variant.
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else {
                return nil
            }
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    /// Compare component-wise, padding the shorter side with zeros so
    /// `1.7` and `1.7.0` are equal and `1.7.0 < 1.7.1`.
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for i in 0..<width {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Current marketing version baked into the app bundle. Falls back to
    /// `"0.0.0"` so the update check fails closed (newer-on-store wins)
    /// rather than treating a missing key as "infinitely new"; a DEBUG
    /// assertion surfaces the underlying bundle misconfiguration so the
    /// fallback does not silently inert the feature in development.
    static var current: AppVersion {
        if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let parsed = AppVersion(raw) {
            return parsed
        }
        assertionFailure("CFBundleShortVersionString missing or unparseable — AppVersion.current using 0.0.0 fallback.")
        return AppVersion("0.0.0")!
    }
}
