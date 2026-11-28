import Foundation

enum WhatsNewStep {
    case page(WhatsNewPage)
    case summary(WhatsNewRepository.ResolvedWhatsNew)

    var id: String {
        switch self {
        case .page(let page): page.id
        case .summary(let summary): "summary:\(summary.version)"
        }
    }
}

struct WhatsNewPresentation: Identifiable, Equatable {
    let version: String
    let language: WhatsNewLanguage
    let steps: [WhatsNewStep]

    var id: String {
        ([version, "\(language)"] + steps.map(\.id)).joined(separator: "|")
    }

    func advanceTitleKey(at step: Int) -> LocalizedStringResource {
        step == steps.count - 1 ? "whats_new_continue" : "action_next"
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
        summaries: [WhatsNewRepository.ResolvedWhatsNew],
        isApplicable: (WhatsNewPage) -> Bool
    ) -> WhatsNewPresentation? {
        func isShown(_ release: AppVersion) -> Bool {
            guard release <= current else { return false }
            if let lastSeen { return lastSeen < release }
            return release == current
        }
        let pageGroups = parsed(releases)
            .filter { isShown($0.version) }
            .map { (version: $0.version, withinVersion: 0, steps: $0.pages.filter(isApplicable).map(WhatsNewStep.page)) }
        let summaryGroups = summaries.compactMap { summary -> (version: AppVersion, withinVersion: Int, steps: [WhatsNewStep])? in
            guard let summaryVersion = AppVersion(summary.version), isShown(summaryVersion) else { return nil }
            return (version: summaryVersion, withinVersion: 1, steps: [.summary(summary)])
        }
        let steps = (pageGroups + summaryGroups)
            .sorted { ($0.version, $0.withinVersion) < ($1.version, $1.withinVersion) }
            .flatMap(\.steps)
        return make(version: version, language: language, steps: steps)
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
        let summaryStep = summary.map { [WhatsNewStep.summary($0)] } ?? []
        return make(version: version, language: language, steps: pages.map(WhatsNewStep.page) + summaryStep)
    }

    private static func make(
        version: String,
        language: WhatsNewLanguage,
        steps: [WhatsNewStep]
    ) -> WhatsNewPresentation? {
        guard !steps.isEmpty else { return nil }
        return WhatsNewPresentation(version: version, language: language, steps: steps)
    }
}
