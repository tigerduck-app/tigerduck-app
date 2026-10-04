import Foundation

/// Loads maintainer-authored "What's new" summaries from the bundled
/// `whatsnew.json` asset. Ported from the Android `WhatsNewRepository`:
/// the JSON is a versionString → per-locale map; this repo picks the
/// locale block that best matches the resolved app language tag and
/// surfaces it as a ``ResolvedWhatsNew`` — the summary page that ends
/// the What's New flow.
///
/// **Maintainer ritual** (matches the Android side): every release
/// worth surfacing in-app adds a new top-level entry to
/// `whatsnew.json` BEFORE the version is tagged / merged to main. Pure
/// bug-fix releases can be skipped — the gate stays quiet when no
/// entry (and no ``WhatsNewCatalog`` page) is registered.
///
/// **Locale resolution**: every Sinitic-family language (Mandarin
/// `zh-Hant*` / `zh-Hans*`, Cantonese `yue`, Wu `wuu`, Min Nan `nan`,
/// Hakka `hak`, Classical `lzh`) falls back to the `zh-TW` block when
/// no closer match is authored — a Chinese-language reader gets
/// readable Chinese text rather than English. Simplified-script tags
/// additionally prefer a `zh-Hans` block first when one is authored.
/// Non-Sinitic languages fall back to `en`.
struct WhatsNewRepository {
    /// Resolved entry for the current locale — what the UI actually
    /// renders. Decoupled from the on-disk ``WhatsNewEntry`` so the
    /// view doesn't have to deal with the optional/empty edge cases the
    /// repo already filters out.
    struct ResolvedWhatsNew: Equatable {
        let version: String
        let title: String
        let items: [Item]

        /// A summary row with its blanks already filtered out: at least
        /// one of `title` / `body` is non-nil. A legacy `highlights`
        /// sentence arrives as a body-only row with no symbol.
        struct Item: Equatable {
            let symbol: String?
            let title: String?
            let body: String?
        }
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
    /// a bundle. See the type doc comment for the locale fallback policy.
    static func select(
        versionEntry: [String: WhatsNewEntry]?,
        version: String,
        languageTag: String
    ) -> ResolvedWhatsNew? {
        guard let versionEntry else { return nil }
        let entry = localeCandidates(for: languageTag)
            .lazy
            .compactMap { versionEntry[$0] }
            .first
        guard let entry,
              let title = nonBlank(entry.title)
        else {
            return nil
        }
        let items = resolvedItems(of: entry)
        guard !items.isEmpty else { return nil }
        return ResolvedWhatsNew(version: version, title: title, items: items)
    }

    /// `items` when the entry authors any usable row, otherwise the
    /// legacy `highlights` sentences as body-only rows. Rows left with
    /// neither a title nor a body are dropped rather than rendered as
    /// an empty line.
    private static func resolvedItems(of entry: WhatsNewEntry) -> [ResolvedWhatsNew.Item] {
        let items: [ResolvedWhatsNew.Item] = (entry.items ?? []).compactMap { item in
            let title = nonBlank(item.title)
            let body = nonBlank(item.body)
            guard title != nil || body != nil else { return nil }
            return ResolvedWhatsNew.Item(symbol: nonBlank(item.symbol), title: title, body: body)
        }
        if !items.isEmpty { return items }
        return (entry.highlights ?? []).compactMap { line in
            nonBlank(line).map { ResolvedWhatsNew.Item(symbol: nil, title: nil, body: $0) }
        }
    }

    private static func nonBlank(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Ordered list of `whatsnew.json` locale keys to try for a given
    /// language tag. The lookup walks this until it finds an authored
    /// block; only the universal `en` tail catches non-Sinitic locales.
    private static func localeCandidates(for languageTag: String) -> [String] {
        // A Chinese-family reader (``WhatsNewLanguage/isChineseFamily(_:)``)
        // prefers Traditional Chinese over English when no closer block exists.
        guard WhatsNewLanguage.isChineseFamily(languageTag) else { return ["en"] }
        let locale = Locale(identifier: languageTag)
        // Simplified-script readers (`zh-Hans*`, `zh-CN`, `zh-SG`) prefer
        // an authored Simplified block when one exists; everyone in the
        // Sinitic family — including Cantonese, Wu, Hakka, etc. — falls
        // back to Traditional (`zh-TW`) before ever reaching English.
        let isSimplified: Bool = {
            if let script = locale.language.script?.identifier { return script == "Hans" }
            if let region = locale.region?.identifier { return region == "CN" || region == "SG" }
            return false
        }()
        return isSimplified ? ["zh-Hans", "zh-TW", "en"] : ["zh-TW", "en"]
    }
}
