// `WhatsNewFlowBuilder` — how the What's New sheet's pages are stacked
// across skipped versions after an upgrade, and what Settings → What's New
// replays. Pure: the catalog, the summary and the seen marker are passed in,
// so nothing here touches `Defaults` or the bundled JSON.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewFlowBuilderTests {
    // MARK: - Upgrade

    @Test func pagesFromEverySkippedReleaseComeOldestFirst() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.3.0",
            releases: ["2.3.0": [page("c")], "2.2.0": [page("b1"), page("b2")]]
        ))
        #expect(flow.pages.map(\.id) == ["b1", "b2", "c"])
    }

    @Test func theLastSeenReleaseAndAnyLaterThanTheInstalledOneAreLeftOut() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.2.0",
            releases: ["2.1.0": [page("seen")], "2.2.0": [page("new")], "2.3.0": [page("ahead")]]
        ))
        #expect(flow.pages.map(\.id) == ["new"])
    }

    @Test func pagesTheirCheckRejectsAreDropped() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.2.0",
            releases: ["2.2.0": [page("keep"), page("skip")]],
            isApplicable: { $0.id != "skip" }
        ))
        #expect(flow.pages.map(\.id) == ["keep"])
    }

    @Test func withNoMarkerOnlyTheInstalledReleaseCounts() throws {
        let flow = try #require(upgrade(
            from: nil, to: "2.3.0",
            releases: ["2.2.0": [page("old")], "2.3.0": [page("current")]]
        ))
        #expect(flow.pages.map(\.id) == ["current"])
    }

    @Test func theSummaryFollowsThePages() throws {
        let flow = try #require(upgrade(
            from: "2.2.0", to: "2.3.0",
            releases: ["2.3.0": [page("a")]],
            summary: summary("2.3.0")
        ))
        #expect(flow.pages.map(\.id) == ["a"])
        #expect(flow.summary?.version == "2.3.0")
    }

    @Test func aSummaryAloneIsAFlow() throws {
        let flow = try #require(upgrade(from: "2.2.0", to: "2.3.0", releases: [:], summary: summary("2.3.0")))
        #expect(flow.pages.isEmpty)
        #expect(flow.summary != nil)
    }

    @Test func nothingToShowIsNoFlow() {
        #expect(upgrade(from: "2.2.0", to: "2.3.0", releases: [:]) == nil)
        #expect(upgrade(
            from: "2.2.0", to: "2.3.0",
            releases: ["2.3.0": [page("a")]],
            isApplicable: { _ in false }
        ) == nil)
    }

    @Test func versionsCompareNumericallyAndPadMissingComponents() throws {
        let flow = try #require(upgrade(
            from: "1.9.0", to: "1.10",
            releases: ["1.10.0": [page("ten")], "1.9.5": [page("nine")]]
        ))
        #expect(flow.pages.map(\.id) == ["nine", "ten"])
    }

    @Test func aMalformedReleaseKeyIsSkipped() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.3.0",
            releases: ["2.2.0-beta": [page("typo")], "2.3.0": [page("ok")]]
        ))
        #expect(flow.pages.map(\.id) == ["ok"])
    }

    // MARK: - Replay

    @Test func replayShowsTheNewestReleaseWithItsSummary() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            releases: ["2.2.0": [page("old")], "2.3.0": [page("new")]],
            latestSummary: summary("2.3.0"),
            summaryFor: { _ in nil }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.pages.map(\.id) == ["new"])
        #expect(flow.summary?.version == "2.3.0")
    }

    @Test func replayFollowsTheCatalogWhenItIsAheadOfTheJSON() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            releases: ["2.3.0": [page("new")]],
            latestSummary: summary("2.2.0"),
            summaryFor: { $0 == "2.3.0" ? summary("2.3.0") : nil }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.pages.map(\.id) == ["new"])
        #expect(flow.summary?.version == "2.3.0")
    }

    @Test func replayFollowsTheJSONWhenItIsAheadOfTheCatalog() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            releases: ["2.2.0": [page("old")]],
            latestSummary: summary("2.3.0"),
            summaryFor: { _ in nil }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.pages.isEmpty)
    }

    @Test func replayIgnoresTheApplicabilityCheck() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            releases: ["2.3.0": [page("a", applicable: false)]],
            latestSummary: nil,
            summaryFor: { _ in nil }
        ))
        #expect(flow.pages.map(\.id) == ["a"])
    }

    @Test func replayWithNothingAuthoredIsNoFlow() {
        #expect(WhatsNewFlowBuilder.replay(language: .en, releases: [:], latestSummary: nil, summaryFor: { _ in nil }) == nil)
    }

    // MARK: - Helpers

    private func upgrade(
        from lastSeen: String?,
        to current: String,
        releases: [String: [WhatsNewPage]],
        summary: WhatsNewRepository.ResolvedWhatsNew? = nil,
        isApplicable: (WhatsNewPage) -> Bool = { _ in true }
    ) -> WhatsNewPresentation? {
        WhatsNewFlowBuilder.upgrade(
            from: lastSeen.flatMap(AppVersion.init),
            to: AppVersion(current)!,
            version: current,
            language: .en,
            releases: releases,
            summary: summary,
            isApplicable: isApplicable
        )
    }

    private func page(_ id: String, applicable: Bool = true) -> WhatsNewPage {
        .feature(
            id: id,
            visual: nil,
            title: WhatsNewText(en: "title", zhHant: "標題"),
            body: WhatsNewText(en: "body", zhHant: "內文"),
            isApplicable: { _ in applicable }
        )
    }

    private func summary(_ version: String) -> WhatsNewRepository.ResolvedWhatsNew {
        WhatsNewRepository.ResolvedWhatsNew(
            version: version,
            title: "What's new in \(version)",
            items: [.init(symbol: nil, title: nil, body: "Something")]
        )
    }
}
