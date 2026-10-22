import Foundation

struct AppVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            // `Int(_:)` accepts a sign, so `Int("+1")` is 1 and passes `n >= 0`. Require plain
            // digits so a sign in a `whatsnew.json` key or an iTunes Lookup response gives
            // `nil` instead of collapsing to the unsigned version.
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else {
                return nil
            }
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for i in 0..<width {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static var current: AppVersion {
        if let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let parsed = AppVersion(raw) {
            return parsed
        }
        assertionFailure("CFBundleShortVersionString missing or unparseable — AppVersion.current using 0.0.0 fallback.")
        return AppVersion("0.0.0")!
    }
}
