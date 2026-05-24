#if os(iOS)
import Foundation

/// Loads maintainer-authored "What's new" content from the bundled
/// `whatsnew.json` asset. Ported from the Android `WhatsNewRepository`:
/// the JSON is a versionString → per-locale map; this repo picks the
/// locale block that best matches the resolved app language tag and
/// surfaces it as a ``ResolvedWhatsNew``.
///
/// **Maintainer ritual** (matches the Android side): every release
/// worth surfacing in-app adds a new top-level entry to
/// `whatsnew.json` BEFORE the version is tagged / merged to main. Pure
/// bug-fix releases can be skipped — the gate stays quiet when no
/// entry is registered.
///
/// **Locale resolution**: Traditional Chinese tags (`zh-Hant*`, bare
/// `zh`, `zh-TW`, `zh-HK`, …) map to the `zh-TW` block; Simplified
/// tags (`zh-Hans*`, `zh-CN`, `zh-SG`) map to a `zh-Hans` block when
/// authored, otherwise fall through to `en` — a Simplified reader
/// gets English rather than Traditional, which would otherwise render
/// awkwardly. Everything non-Chinese falls back to `en`.
struct WhatsNewRepository {
    /// Resolved entry for the current locale — what the UI actually
    /// renders. Decoupled from the on-disk ``WhatsNewEntry`` so the
    /// view doesn't have to deal with the optional/empty edge cases the
    /// repo already filters out.
    struct ResolvedWhatsNew: Equatable {
        let version: String
        let title: String
        let highlights: [String]
    }

    private let bundle: Bundle
    private let resourceName: String

    /// Nonisolated so `UpdateNotifyCoordinator`'s (also nonisolated)
    /// `init` can construct one without a MainActor hop. The struct
    /// only reads bundle resources and never touches actor-isolated
    /// state, so there's no isolation to preserve here.
    nonisolated init(bundle: Bundle = .main, resourceName: String = "whatsnew") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    /// Resolved entry for `version` in the locale implied by
    /// `languageTag`, or `nil` if the asset is missing/malformed, has no
    /// entry for that version, or the entry is empty after filtering.
    func entry(forVersion version: String, languageTag: String) -> ResolvedWhatsNew? {
        guard let byVersion = loadByVersion() else { return nil }
        return Self.select(
            versionEntry: byVersion[version],
            version: version,
            languageTag: languageTag
        )
    }

    /// Resolved entry for the newest registered version, ignoring the
    /// running build's version. Backs the Settings → What's New entry,
    /// which has to surface the latest authored content even on the
    /// build that ships it.
    func latestEntry(languageTag: String) -> ResolvedWhatsNew? {
        guard let byVersion = loadByVersion(), !byVersion.isEmpty else { return nil }
        // Sort by parsed AppVersion so "1.10.0" outranks "1.9.0" (lexical
        // sort would invert them). Falls back to lexical ordering when
        // any key fails to parse, which matters for a maintainer typo —
        // surfacing *something* beats surfacing nothing.
        let pairs = byVersion.keys.compactMap { key -> (String, AppVersion)? in
            guard let v = AppVersion(key) else { return nil }
            return (key, v)
        }
        let latestKey: String? = pairs
            .max(by: { $0.1 < $1.1 })?
            .0 ?? byVersion.keys.sorted().last
        guard let latestKey else { return nil }
        return Self.select(
            versionEntry: byVersion[latestKey],
            version: latestKey,
            languageTag: languageTag
        )
    }

    /// True when the asset has at least one usable entry. Used by the
    /// Settings row to hide the "What's New" button on a build that
    /// shipped without any registered content yet.
    func hasAnyContent(languageTag: String) -> Bool {
        latestEntry(languageTag: languageTag) != nil
    }

    // MARK: - Internal

    private typealias ByVersion = [String: [String: WhatsNewEntry]]

    private func loadByVersion() -> ByVersion? {
        guard
            let url = bundle.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ByVersion.self, from: data)
    }

    /// Pure selector — kept static so tests can drive it without mounting
    /// a bundle. Matches the Android `select` logic.
    static func select(
        versionEntry: [String: WhatsNewEntry]?,
        version: String,
        languageTag: String
    ) -> ResolvedWhatsNew? {
        guard let versionEntry else { return nil }
        let localeKey: String = {
            // Distinguish Simplified ("zh-Hans*", "zh-CN", "zh-SG") from
            // Traditional ("zh-Hant*", "zh-TW", "zh-HK", bare "zh").
            // Simplified resolves to "zh-Hans", which is intentionally
            // allowed to fall through to "en" below when whatsnew.json
            // has no Simplified block — preferable to serving Traditional
            // text to a Simplified reader.
            guard languageTag.lowercased().hasPrefix("zh") else { return "en" }
            let locale = Locale(identifier: languageTag)
            switch locale.language.script?.identifier {
            case "Hans": return "zh-Hans"
            case "Hant": return "zh-TW"
            default:
                switch locale.region?.identifier {
                case "CN", "SG": return "zh-Hans"
                default: return "zh-TW"
                }
            }
        }()
        let entry = versionEntry[localeKey] ?? versionEntry["en"]
        guard let entry,
              let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let highlights = entry.highlights,
              !highlights.isEmpty
        else {
            return nil
        }
        return ResolvedWhatsNew(version: version, title: title, highlights: highlights)
    }
}
#endif
