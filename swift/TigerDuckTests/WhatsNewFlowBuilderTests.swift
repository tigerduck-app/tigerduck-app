import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewFlowBuilderTests {

    @Test func pagesFromEverySkippedReleaseComeOldestFirst() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.3.0",
            releases: ["2.3.0": [page("c")], "2.2.0": [page("b1"), page("b2")]]
        ))
        #expect(flow.steps.map(\.id) == ["b1", "b2", "c"])
    }

    @Test func theLastSeenReleaseAndAnyLaterThanTheInstalledOneAreLeftOut() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.2.0",
            releases: ["2.1.0": [page("seen")], "2.2.0": [page("new")], "2.3.0": [page("ahead")]]
        ))
        #expect(flow.steps.map(\.id) == ["new"])
    }

    @Test func pagesTheirCheckRejectsAreDropped() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.2.0",
            releases: ["2.2.0": [page("keep"), page("skip")]],
            isApplicable: { $0.id != "skip" }
        ))
        #expect(flow.steps.map(\.id) == ["keep"])
    }

    @Test func withNoMarkerOnlyTheInstalledReleaseCounts() throws {
        let flow = try #require(upgrade(
            from: nil, to: "2.3.0",
            releases: ["2.2.0": [page("old")], "2.3.0": [page("current")]],
            summaries: [summary("2.2.0"), summary("2.3.0")]
        ))
        #expect(flow.steps.map(\.id) == ["current", "summary:2.3.0"])
    }

    @Test func theSummaryFollowsThePages() throws {
        let flow = try #require(upgrade(
            from: "2.2.0", to: "2.3.0",
            releases: ["2.3.0": [page("a")]],
            summaries: [summary("2.3.0")]
        ))
        #expect(flow.steps.map(\.id) == ["a", "summary:2.3.0"])
    }

    @Test func aSummaryAloneIsAFlow() throws {
        let flow = try #require(upgrade(from: "2.2.0", to: "2.3.0", releases: [:], summaries: [summary("2.3.0")]))
        #expect(flow.steps.map(\.id) == ["summary:2.3.0"])
    }

    @Test func everySkippedVersionGetsItsOwnSummaryOldestFirst() throws {
        let flow = try #require(upgrade(
            from: "2.9.1", to: "4.1.0",
            releases: [:],
            summaries: ["4.0.2", "2.9.1", "4.1.0", "4.0.0", "4.2.0", "4.0.3", "2.9.0", "4.0.1"].map(summary)
        ))
        #expect(flow.steps.map(\.id) == [
            "summary:4.0.0", "summary:4.0.1", "summary:4.0.2", "summary:4.0.3", "summary:4.1.0",
        ])
    }

    @Test func aVersionsPagesComeRightBeforeItsOwnSummary() throws {
        let flow = try #require(upgrade(
            from: "2.2.0", to: "2.5.0",
            releases: ["2.4.0": [page("b1"), page("b2")], "2.3.0": [page("a")]],
            summaries: ["2.5.0", "2.4.0", "2.3.0"].map(summary)
        ))
        #expect(flow.steps.map(\.id) == ["a", "summary:2.3.0", "b1", "b2", "summary:2.4.0", "summary:2.5.0"])
    }

    @Test func aVersionWithoutAnEntryIsSkippedAndItsPagesStillShow() throws {
        let flow = try #require(upgrade(
            from: "4.0.0", to: "4.0.4",
            releases: ["4.0.3": [page("p")]],
            summaries: ["4.0.1", "4.0.4"].map(summary)
        ))
        #expect(flow.steps.map(\.id) == ["summary:4.0.1", "p", "summary:4.0.4"])
    }

    @Test func everyStepButTheLastMovesOnAndTheLastFinishes() throws {
        let flow = try #require(upgrade(
            from: "4.0.0", to: "4.0.2",
            releases: ["4.0.1": [page("p")]],
            summaries: ["4.0.1", "4.0.2"].map(summary)
        ))
        #expect(flow.steps.indices.map { flow.advanceTitleKey(at: $0).key } == [
            "action_next", "action_next", "whats_new_continue",
        ])
        let single = try #require(upgrade(from: "4.0.0", to: "4.0.1", releases: [:], summaries: [summary("4.0.1")]))
        #expect(single.advanceTitleKey(at: 0).key == "whats_new_continue")
    }

    @Test func theIdentityChangesWithTheSummariesItHolds() throws {
        let summaries = ["4.0.3", "4.1.0"].map(summary)
        let longer = try #require(upgrade(from: "4.0.2", to: "4.1.0", releases: [:], summaries: summaries))
        let shorter = try #require(upgrade(from: "4.0.3", to: "4.1.0", releases: [:], summaries: summaries))
        #expect(longer.id != shorter.id)
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
            releases: ["1.10.0": [page("ten")], "1.9.5": [page("nine")]],
            summaries: [summary("1.10.0")]
        ))
        #expect(flow.steps.map(\.id) == ["nine", "ten", "summary:1.10.0"])
    }

    @Test func aMalformedReleaseKeyIsSkipped() throws {
        let flow = try #require(upgrade(
            from: "2.1.0", to: "2.3.0",
            releases: ["2.2.0-beta": [page("typo")], "2.3.0": [page("ok")]],
            summaries: [summary("2.2.0-beta")]
        ))
        #expect(flow.steps.map(\.id) == ["ok"])
    }

    @Test func replayShowsTheNewestReleaseWithItsSummary() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: ["2.2.0": [page("old")], "2.3.0": [page("new")]],
            latestSummary: summary("2.3.0"),
            summaryFor: { _ in nil },
            isApplicable: { _ in true }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.steps.map(\.id) == ["new", "summary:2.3.0"])
    }

    @Test func replayFollowsTheCatalogWhenItIsAheadOfTheJSON() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: ["2.3.0": [page("new")]],
            latestSummary: summary("2.2.0"),
            summaryFor: { $0 == "2.3.0" ? summary("2.3.0") : nil },
            isApplicable: { _ in true }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.steps.map(\.id) == ["new", "summary:2.3.0"])
    }

    @Test func replayFollowsTheJSONWhenItIsAheadOfTheCatalog() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: ["2.2.0": [page("old")]],
            latestSummary: summary("2.3.0"),
            summaryFor: { _ in nil },
            isApplicable: { _ in true }
        ))
        #expect(flow.version == "2.3.0")
        #expect(flow.steps.map(\.id) == ["summary:2.3.0"])
    }

    @Test func replayLeavesOutPagesThatDoNotApply() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: ["2.3.0": [page("skip"), page("keep")]],
            latestSummary: nil,
            summaryFor: { _ in nil },
            isApplicable: { $0.id != "skip" }
        ))
        #expect(flow.steps.map(\.id) == ["keep"])
    }

    @Test func replayFallsBackPastAReleaseWhosePagesAllDropOut() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: ["2.2.0": [page("old")], "2.3.0": [page("skip")]],
            latestSummary: summary("2.2.0"),
            summaryFor: { _ in nil },
            isApplicable: { $0.id != "skip" }
        ))
        #expect(flow.version == "2.2.0")
        #expect(flow.steps.map(\.id) == ["old", "summary:2.2.0"])
    }

    @Test func replayWithNothingAuthoredIsNoFlow() {
        #expect(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("9.9.9")!,
            releases: [:],
            latestSummary: nil,
            summaryFor: { _ in nil },
            isApplicable: { _ in true }
        ) == nil)
    }

    @Test func replayLeavesOutPagesAheadOfTheInstalledVersion() throws {
        let flow = try #require(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("2.2.0")!,
            releases: ["2.2.0": [page("installed")], "2.3.0": [page("ahead")]],
            latestSummary: summary("2.2.0"),
            summaryFor: { _ in nil },
            isApplicable: { _ in true }
        ))
        #expect(flow.version == "2.2.0")
        #expect(flow.steps.map(\.id) == ["installed", "summary:2.2.0"])
    }

    @Test func replayWithOnlyFuturePagesAndNoSummaryIsNoFlow() {
        #expect(WhatsNewFlowBuilder.replay(
            language: .en,
            upTo: AppVersion("2.2.0")!,
            releases: ["2.3.0": [page("ahead")]],
            latestSummary: nil,
            summaryFor: { _ in nil },
            isApplicable: { _ in true }
        ) == nil)
    }

    private func upgrade(
        from lastSeen: String?,
        to current: String,
        releases: [String: [WhatsNewPage]],
        summaries: [WhatsNewRepository.ResolvedWhatsNew] = [],
        isApplicable: (WhatsNewPage) -> Bool = { _ in true }
    ) -> WhatsNewPresentation? {
        WhatsNewFlowBuilder.upgrade(
            from: lastSeen.flatMap(AppVersion.init),
            to: AppVersion(current)!,
            version: current,
            language: .en,
            releases: releases,
            summaries: summaries,
            isApplicable: isApplicable
        )
    }

    private func page(_ id: String) -> WhatsNewPage {
        .feature(
            id: id,
            visual: nil,
            title: WhatsNewText(en: "title", zhHant: "標題"),
            body: WhatsNewText(en: "body", zhHant: "內文")
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
