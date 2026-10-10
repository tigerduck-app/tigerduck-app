import Foundation

/// One run of the What's New sheet: feature pages, then the summary.
/// Either half may be missing, never both — ``WhatsNewFlowBuilder``
/// returns `nil` instead of an empty flow.
struct WhatsNewPresentation: Identifiable, Equatable {
    let version: String
    /// The language the summary was looked up in; the pages show theirs
    /// in the same one.
    let language: WhatsNewLanguage
    let pages: [WhatsNewPage]
    let summary: WhatsNewRepository.ResolvedWhatsNew?

    /// Sheet identity. Built from content rather than random so the same
    /// flow observed twice (e.g. a re-render between launch and present)
    /// keeps one sheet.
    var id: String {
        ([version, "\(language)"] + pages.map(\.id) + [summary == nil ? "-" : "summary"]).joined(separator: "|")
    }

    /// Pages hold closures, so equality goes by identity.
    static func == (lhs: WhatsNewPresentation, rhs: WhatsNewPresentation) -> Bool {
        lhs.id == rhs.id
    }
}

/// Pure assembly of a What's New flow from the catalog, the summary
/// lookup and the seen marker — kept free of `Defaults` and bundles so
/// tests drive it directly.
enum WhatsNewFlowBuilder {
    /// The flow shown after an upgrade from `lastSeen` to `current`.
    ///
    /// Pages come from every release in `(lastSeen, current]`, oldest
    /// first, minus those `isApplicable` rejects. With no `lastSeen`
    /// (an upgrade from a build that predates the marker) only the
    /// installed version's pages count — dumping the whole history on
    /// that user would be worse than showing them less. The summary is
    /// the installed version's only.
    static func upgrade(
        from lastSeen: AppVersion?,
        to current: AppVersion,
        version: String,
        language: WhatsNewLanguage,
        releases: [String: [WhatsNewPage]],
        summary: WhatsNewRepository.ResolvedWhatsNew?,
        isApplicable: (WhatsNewPage) -> Bool
    ) -> WhatsNewPresentation? {
        let pages = parsed(releases)
            .filter { release in
                guard release.version <= current else { return false }
                if let lastSeen { return lastSeen < release.version }
                return release.version == current
            }
            .flatMap(\.pages)
            .filter(isApplicable)
        return make(version: version, language: language, pages: pages, summary: summary)
    }

    /// The flow behind Settings → What's New: the newest release, at most
    /// the installed one, that has a summary or pages `isApplicable` keeps.
    /// A page that would not show after an upgrade does not show on a replay
    /// either, and a release whose pages all drop out counts as having none.
    /// Pages registered ahead of their release's bump stay out until a build
    /// reports that version. `latestSummary` is the newest authored summary up
    /// to the same ceiling; `summaryFor` looks one up by version, used when the
    /// catalog's newest release is ahead of the JSON's.
    static func replay(
        language: WhatsNewLanguage,
        upTo current: AppVersion,
        releases: [String: [WhatsNewPage]],
        latestSummary: WhatsNewRepository.ResolvedWhatsNew?,
        summaryFor: (String) -> WhatsNewRepository.ResolvedWhatsNew?,
        isApplicable: (WhatsNewPage) -> Bool
    ) -> WhatsNewPresentation? {
        // Filtered before the newest release is picked, so one whose pages
        // all drop out can't hide an older release's pages or summary.
        let reached = parsed(releases)
            .filter { $0.version <= current }
            .map { Release(key: $0.key, version: $0.version, pages: $0.pages.filter(isApplicable)) }
            .filter { !$0.pages.isEmpty }
        let newestPages = reached.last
        let summaryVersion = latestSummary.flatMap { AppVersion($0.version) }

        if let newestPages, summaryVersion.map({ $0 < newestPages.version }) ?? true {
            return make(
                version: newestPages.key,
                language: language,
                pages: newestPages.pages,
                summary: summaryFor(newestPages.key)
            )
        }
        guard let latestSummary, let summaryVersion else { return nil }
        let pages = reached
            .filter { $0.version == summaryVersion }
            .flatMap(\.pages)
        return make(version: latestSummary.version, language: language, pages: pages, summary: latestSummary)
    }

    // MARK: - Private

    private struct Release {
        let key: String
        let version: AppVersion
        let pages: [WhatsNewPage]
    }

    /// Releases with a parseable key and at least one page, oldest first.
    /// A typo'd key is skipped rather than guessed at.
    private static func parsed(_ releases: [String: [WhatsNewPage]]) -> [Release] {
        releases
            .compactMap { key, pages in
                guard !pages.isEmpty, let version = AppVersion(key) else { return nil }
                return Release(key: key, version: version, pages: pages)
            }
            .sorted { $0.version < $1.version }
    }

    private static func make(
        version: String,
        language: WhatsNewLanguage,
        pages: [WhatsNewPage],
        summary: WhatsNewRepository.ResolvedWhatsNew?
    ) -> WhatsNewPresentation? {
        guard !pages.isEmpty || summary != nil else { return nil }
        return WhatsNewPresentation(version: version, language: language, pages: pages, summary: summary)
    }
}
