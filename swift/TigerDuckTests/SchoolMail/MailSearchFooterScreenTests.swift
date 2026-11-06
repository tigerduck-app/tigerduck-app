#if os(iOS)
import Observation
import os
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

    @Test("a search on an incomplete index ends in its count, spinning only while the pass runs, until the new matches arrive",
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

            h.model.stopPolling()
            await h.fake.release("searchTexts")
            try await waitUntil { !h.model.isSyncing }
            #expect(h.model.search.indexProgress?.text() == MailConstants.indexBatchSize.formatted() + "/" + 2_000.formatted())
            #expect(shownListLabels(in: window).contains(partial))
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-search-paused-\(look.testDescription)-\(Self.language)")

            h.model.startPolling()
            defer { h.model.stopPolling() }
            await h.model.waitForIndex()
            await h.model.waitForSearchCatchUp()
            try await waitUntil { !shownListLabels(in: window).contains(partial) && showsLateMatch() }
            #expect(showsLateMatch(), "\(shownListLabels(in: window))")
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-search-done-\(look.testDescription)-\(Self.language)")
        }
    }

    enum StopBeforeCount: String, CaseIterable { case failed, paused }

    @Test("a pass that stopped before counting leaves the footer saying the search may miss mail",
          arguments: ClubScreensTests.looks, StopBeforeCount.allCases)
    func stoppedBeforeCount(look: ClubScreensTests.Look, stop: StopBeforeCount) async throws {
        try await withAccessibilityAutomation {
            let h = MailListViewModelTests.harness(warmDelay: {})
            switch stop {
            case .failed:
                await h.fake.update { $0.undeletedUIDsError = .unreachable }
                await h.model.load()
                await h.model.waitForIndex()
            case .paused:
                await h.fake.hold("undeletedUIDs")
                await h.model.load()
                await h.fake.waitForArrival("undeletedUIDs")
                h.model.stopPolling()
                await h.fake.release("undeletedUIDs")
                try await waitUntil { !h.model.background.indexer.isRunning }
            }
            #expect(h.model.background.indexer.progress == .counting)
            h.model.searchText = "公告 60"
            await h.model.submitSearch()
            #expect(h.model.displayedRows.map(\.uid) == [60])

            let window = try ClubScreensTests.show(SearchResults(model: h.model), look: look,
                                                   height: look.textSize == .large ? 812 : 2_000)
            defer { window.isHidden = true }
            let partial = String(localized: "school_mail_search_index_partial")
            try await waitUntil { shownListLabels(in: window).contains(partial) }
            let footer = MailListFooter(viewModel: h.model, hasRows: true)
            #expect(footer.text == partial)
            #expect(!footer.showsSpinner)
            let element = try #require(accessibilityElement(labeled: partial, in: window))
            #expect(element.accessibilityFrame.minX >= 0 && element.accessibilityFrame.maxX <= window.bounds.maxX + 0.5)
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-search-\(stop.rawValue)-before-count-\(look.testDescription)-\(Self.language)")
        }
    }

    @Test("the footer leaves while the list shows its own spinner")
    func oneSpinner() async throws {
        try await withAccessibilityAutomation {
            let h = MailListViewModelTests.harness(warmDelay: {})
            await h.fake.hold("searchTexts")
            await h.model.load()
            await h.fake.waitForArrival("searchTexts")
            h.model.searchText = "no such mail"
            await h.model.submitSearch()
            #expect(h.model.displayedRows.isEmpty)
            #expect(h.model.search.indexProgress != nil)

            let window = try ClubScreensTests.show(SearchResults(model: h.model), look: ClubScreensTests.looks[0])
            defer { window.isHidden = true }
            let partial = String(localized: "school_mail_search_index_partial")
            try await waitUntil { shownListLabels(in: window).contains(partial) }
            h.model.status.loadState = .loading
            try await waitUntil { !shownListLabels(in: window).contains(partial) }
            h.model.status.loadState = .loaded
            try await waitUntil { shownListLabels(in: window).contains(partial) }

            h.model.stopPolling()
            await h.fake.release("searchTexts")
        }
    }
}

@MainActor
struct MailListFooterTests {
    @Test func aTickOfTheIndexCountRedrawsTheFooterButNotTheRows() async {
        let h = MailListViewModelTests.harness(warmDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[58].summary.subject = "Room 302 改期"
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        h.model.searchText = "room 302"
        await h.model.submitSearch()
        #expect(h.model.displayedRows.map(\.uid) == [59])
        #expect(h.model.search.indexProgress?.done == 0)

        let rowsChanged = OSAllocatedUnfairLock(initialState: false)
        let footerChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = MailListRowsSection(viewModel: h.model, accentColor: .blue, onOpen: { _ in }).body
        } onChange: { rowsChanged.withLock { $0 = true } }
        withObservationTracking {
            _ = MailListFooter(viewModel: h.model, hasRows: true).body
        } onChange: { footerChanged.withLock { $0 = true } }

        await h.fake.update { fake in
            fake.release("searchTexts")
            fake.holdNext("searchTexts")
        }
        await h.fake.waitForArrival("searchTexts")
        #expect(h.model.search.indexProgress?.done == MailConstants.indexBatchSize)
        #expect(footerChanged.withLock { $0 })
        #expect(!rowsChanged.withLock { $0 })

        h.model.stopPolling()
        await h.fake.release("searchTexts")
    }
}
#endif
