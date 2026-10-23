import Foundation

struct WhatsNewPresentation: Identifiable, Equatable {
    let version: String
    let language: WhatsNewLanguage
    let pages: [WhatsNewPage]
    let summary: WhatsNewRepository.ResolvedWhatsNew?

    var id: String {
        ([version, "\(language)"] + pages.map(\.id) + [summary == nil ? "-" : "summary"]).joined(separator: "|")
    }

    static func == (lhs: WhatsNewPresentation, rhs: WhatsNewPresentation) -> Bool {
        lhs.id == rhs.id
    }
}

enum WhatsNewFlowBuilder {
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

    static func replay(
        language: WhatsNewLanguage,
        upTo current: AppVersion,
        releases: [String: [WhatsNewPage]],
        latestSummary: WhatsNewRepository.ResolvedWhatsNew?,
        summaryFor: (String) -> WhatsNewRepository.ResolvedWhatsNew?,
        isApplicable: (WhatsNewPage) -> Bool
    ) -> WhatsNewPresentation? {
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

    private struct Release {
        let key: String
        let version: AppVersion
        let pages: [WhatsNewPage]
    }

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
