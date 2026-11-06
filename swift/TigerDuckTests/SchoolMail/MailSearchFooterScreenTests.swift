#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MailSearchFooterScreenTests {
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private struct SearchResults: View {
        let model: MailListViewModel

        var body: some View {
            List {
                MailListRowsSection(viewModel: model, accentColor: .blue, onOpen: { _ in })
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
        }
    }

    @Test("a search on an index still downloading ends in its count, which gives way to the new matches once the pass ends",
          arguments: ClubScreensTests.looks)
    func footer(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let h = MailListViewModelTests.harness(inboxCount: 1_999, warmDelay: {}, catchUpDelay: {})
            await h.fake.update { fake in
                for index in [1_998, 1_994, 1_989] { fake.folders["INBOX"]?[index].summary.subject = "Room 302 改期" }
                fake.folders["INBOX"]?[6].detail?.textBody = "補考在 Room 302"
                fake.hold("searchTexts")
            }
            await h.model.load()
            await h.fake.waitForArrival("searchTexts")
            h.model.searchText = "room 302"
            await h.model.submitSearch()
            #expect(h.model.search.indexProgress?.text() == 0.formatted() + "/" + 2_000.formatted())

            let window = try ClubScreensTests.show(SearchResults(model: h.model), look: look,
                                                   height: look.textSize == .large ? 812 : 2_000)
            defer { window.isHidden = true }
            let partial = String(localized: "school_mail_search_index_partial")
            let showsLateMatch = { shownListLabels(in: window).contains { $0.contains("公告 7") } }
            try await waitUntil { shownListLabels(in: window).contains(partial) }
            let footer = try #require(accessibilityElement(labeled: partial, in: window))
            #expect(footer.accessibilityFrame.minX >= 0 && footer.accessibilityFrame.maxX <= window.bounds.maxX + 0.5)
            #expect(!showsLateMatch())
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-search-partial-\(look.testDescription)-\(Self.language)")

            await h.fake.release("searchTexts")
            await h.model.waitForIndex()
            await h.model.waitForSearchCatchUp()
            try await waitUntil { !shownListLabels(in: window).contains(partial) && showsLateMatch() }
            #expect(showsLateMatch(), "\(shownListLabels(in: window))")
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-search-done-\(look.testDescription)-\(Self.language)")
        }
    }
}
#endif
