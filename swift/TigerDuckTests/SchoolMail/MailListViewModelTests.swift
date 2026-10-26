#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailListViewModelTests {
    final class SeenLog {
        var noted: [MailboxStatusInfo] = []
        var authFailures = 0
    }

    struct Harness {
        let model: MailListViewModel
        let fake: FakeMailClient
        let cache: MailCache
        let seen: SeenLog
    }

    /// `nonisolated` because the fake-server `update` closures below are nonisolated, and the
    /// suite is `@MainActor` — without it this constant is main-actor isolated and reading it
    /// from one of those closures is an error in the Swift 6 language mode. `MailFolderRole` is
    /// `nonisolated` already, so the value has nothing main-actor about it.
    nonisolated static let sent = MailFolderRole.sent.imapName

    static func harness(
        inboxCount: UInt32 = 60,
        sentUIDs: [UInt32] = [],
        includeSent: Bool = true,
        open: (() async throws -> any MailClient)? = nil,
        signOutEvents: NotificationCenter = NotificationCenter(),
        warmDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(86_400)) },
        catchUpDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(86_400)) }
    ) -> Harness {
        let inbox = (UInt32(1)...inboxCount).map { FakeMailClient.message(uid: $0, subject: "公告 \($0)", seen: $0 % 2 == 0) }
        var folders: [String: [FakeMailClient.Message]] = [
            "INBOX": inbox,
            MailFolderRole.trash.imapName: [FakeMailClient.message(uid: 1, subject: "舊信")],
            "Moodle &irJ6C4oOitZTQA-": [],
        ]
        if includeSent {
            folders[sent] = sentUIDs.map { FakeMailClient.message(uid: $0, subject: "寄件 \($0)") }
        }
        let fake = FakeMailClient(folders: folders)
        let cache = SchoolMailTestDoubles.temporaryCache()
        let seen = SeenLog()
        let session = MailPageSession(idleClose: .milliseconds(10), open: open ?? { fake },
                                      onAuthFailure: { seen.authFailures += 1 }, signOutEvents: signOutEvents)
        let model = MailListViewModel(session: session, cache: cache, noteSeenByPage: { seen.noted.append($0) },
                                      signOutEvents: signOutEvents, warmDelay: warmDelay, catchUpDelay: catchUpDelay)
        return Harness(model: model, fake: fake, cache: cache, seen: seen)
    }

    @Test func loadsFoldersAndTheNewestPage() async {
        let h = Self.harness()
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.rows.count == 50)
        #expect(h.model.rows.first?.uid == 60)
        #expect(h.model.folderRoles[.trash] == MailFolderRole.trash.imapName)
        #expect(h.model.otherFolders == ["Moodle &irJ6C4oOitZTQA-"])
        #expect(h.model.serverStatus == .ok)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == 50)
    }

    @Test func loadsOlderMailAtTheEnd() async throws {
        let h = Self.harness()
        await h.model.load()
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 60)
        #expect(h.model.rows.last?.uid == 1)
    }

    @Test func unreadOnlyFiltersTheList() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        h.model.unreadOnly = true
        #expect(h.model.displayedRows.map(\.uid) == [3, 1])
    }

    @Test func theCachedListStaysUpWhenOffline() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil))
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.rows.map(\.uid) == [9])
        #expect(h.model.serverStatus == .failed)
    }

    @Test func theLastSyncIsWhenTheNewestPageArrived() async throws {
        let h = Self.harness()
        let before = Date()
        await h.model.load()

        let syncedAt = try #require(h.model.syncedAt)
        #expect(syncedAt >= before && syncedAt <= Date())
        let cached = try #require(h.cache.loadPage(folder: "INBOX")?.fetchedAt)
        #expect(abs(cached.timeIntervalSince(syncedAt)) < 0.001)

        h.model.resetForAccountChange()
        #expect(h.model.syncedAt == nil)
    }

    @Test func theCachedListKeepsItsTimeWhenOffline() async throws {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        let fetchedAt = Date().addingTimeInterval(-3600)
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil,
                                        fetchedAt: fetchedAt))
        await h.model.load()

        #expect(h.model.serverStatus == .failed)
        let syncedAt = try #require(h.model.syncedAt)
        #expect(abs(syncedAt.timeIntervalSince(fetchedAt)) < 0.001)
    }

    @Test func aPageCachedWithoutAFetchTimeStillLoads() throws {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let url = cache.pageURL(folder: "INBOX")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":1,"payload":{"folder":"INBOX","uidValidity":7,"messageCount":0,"summaries":[]}}"#
        try Data(json.utf8).write(to: url)

        let page = try #require(cache.loadPage(folder: "INBOX"))

        #expect(page.uidValidity == 7)
        #expect(page.fetchedAt == nil)
    }

    @Test func failingWithNothingCachedShowsTheError() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        await h.model.load()
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError.network.message))
    }

    /// The page with its search index downloaded, the warm and the index starting at once.
    static func indexedHarness() async -> Harness {
        let h = harness(warmDelay: {})
        await h.model.load()
        await h.model.waitForIndex()
        return h
    }

    @Test func searchFindsMailInTheIndexByItsBodyWithoutAskingTheServerToSearch() async {
        let h = Self.harness(warmDelay: {})
        await h.fake.update { $0.folders["INBOX"]?[6].detail?.textBody = "期末考在 Room 302" }
        await h.model.load()
        await h.model.waitForIndex()
        h.model.searchText = "room 302"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback == false)
        #expect(h.model.displayedRows.map(\.uid) == [7])
        #expect(await h.fake.calls.contains("summaries INBOX [7]"))
    }

    @Test func searchFindsLoadedMailTheIndexHasNotReached() async {
        let h = Self.harness()
        await h.model.load()
        h.model.searchText = "公告 60"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback == false)
        #expect(h.model.displayedRows.map(\.uid) == [60])
        #expect(await !h.fake.calls.contains { $0.hasPrefix("searchTexts") })
    }

    @Test func leavingThePageStopsTheIndexDownloadAndComingBackResumesIt() async throws {
        let h = Self.harness(warmDelay: {})
        await h.fake.hold("searchTexts")
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        h.model.stopPolling()
        await h.fake.release("searchTexts")
        try await waitUntil { h.cache.searchIndex.search(folder: "INBOX", query: "公告 60")?.uids == [60] }

        h.model.startPolling()
        await h.model.waitForIndex()
        h.model.stopPolling()

        let batches = await h.fake.calls.filter { $0.hasPrefix("searchTexts INBOX ") }
        #expect(batches == [
            "searchTexts INBOX \(Array((UInt32(41)...60).reversed()))",
            "searchTexts INBOX \(Array((UInt32(21)...40).reversed()))",
            "searchTexts INBOX \(Array((UInt32(1)...20).reversed()))",
        ])
    }

    @Test func theStatusSaysOKOnceTheIndexIsComplete() async {
        let h = await Self.indexedHarness()
        #expect(h.model.statusText == SyncStatusDot.statusText(.ok))
        #expect(!h.model.isSyncing)
    }

    @Test func theStatusCountsTheIndexAfterAFailedPass() async {
        let h = Self.harness(warmDelay: {})
        await h.fake.update { $0.searchTextsError = .serverBusy }
        await h.model.load()
        await h.model.waitForIndex()
        #expect(h.model.serverStatus == .ok)
        #expect(h.model.statusText == "0/61")
        #expect(!h.model.isSyncing)
    }

    @Test func theStatusCountsAPausedPassWithoutSpinning() async throws {
        let h = Self.harness(warmDelay: {})
        await h.fake.hold("searchTexts")
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        #expect(h.model.isSyncing)
        #expect(h.model.statusText == "0/61")

        h.model.stopPolling()
        await h.fake.release("searchTexts")
        try await waitUntil { !h.model.isSyncing }
        #expect(h.model.statusText == "20/61")
    }

    @Test func clearingTheCacheTakesTheStatusBackToSyncing() async {
        let h = await Self.indexedHarness()
        h.cache.clearAll()
        #expect(h.model.statusText == String(localized: "sync_status_syncing"))
        #expect(!h.model.isSyncing)
    }

    @Test func aSearchWaitsOutAFailedPassButAPullDoesNot() async {
        let h = Self.harness(warmDelay: {})
        await h.fake.update { $0.searchTextsError = .serverBusy }
        await h.model.load()
        await h.model.waitForIndex()
        await h.fake.update { $0.searchTextsError = nil }

        h.model.searchText = "公告 60"
        await h.model.submitSearch()
        await h.model.refresh()
        await h.model.waitForIndex()
        #expect(await h.fake.calls.filter { $0 == "undeletedUIDs INBOX" }.count == 1)

        await h.model.refresh(forcingIndex: true)
        await h.model.waitForIndex()
        #expect(await h.fake.calls.filter { $0 == "undeletedUIDs INBOX" }.count == 2)
        #expect(h.cache.searchIndex.search(folder: "INBOX", query: "公告 60")?.uids == [60])
    }

    @Test func aSearchDuringAPassGrowsAsThePassFillsItsFoldersWithoutASecondPass() async {
        let h = Self.harness(warmDelay: {}, catchUpDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[54].detail?.textBody = "期末考在 Room 302"
            fake.folders["INBOX"]?[6].detail?.textBody = "補考也在 Room 302"
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")

        h.model.searchText = "room 302"
        await h.model.submitSearch()
        #expect(h.model.displayedRows.isEmpty)

        await h.fake.release("searchTexts")
        await h.model.waitForIndex()
        await h.model.waitForSearchCatchUp()
        #expect(h.model.displayedRows.map(\.uid) == [55, 7])
        #expect(await h.fake.calls.filter { $0 == "undeletedUIDs INBOX" }.count == 1)
    }

    @Test func aBatchThatLandsAfterThePageClosesCatchesTheSearchUpOnlyWhenItReopens() async throws {
        let h = Self.harness(warmDelay: {}, catchUpDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[54].detail?.textBody = "期末考在 Room 302"
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        h.model.searchText = "room 302"
        await h.model.submitSearch()

        h.model.stopPolling()
        await h.fake.release("searchTexts")
        try await waitUntil { !h.model.isSyncing }
        await h.model.waitForSearchCatchUp()
        #expect(await !h.fake.calls.contains { $0.hasPrefix("summaries ") })

        h.model.startPolling()
        await h.model.waitForSearchCatchUp()
        h.model.stopPolling()
        #expect(h.model.displayedRows.map(\.uid) == [55])
    }

    @Test func aSearchThatEndsAfterThePageClosesLeavesItsCatchUpForTheReopening() async throws {
        let h = Self.harness(warmDelay: {}, catchUpDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[57].summary.subject = "Room 302 改期"
            fake.folders["INBOX"]?[54].detail?.textBody = "Room 302"
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        await h.fake.hold("summaries")
        h.model.searchText = "room 302"
        let search = Task { await h.model.submitSearch() }
        await h.fake.waitForArrival("summaries")
        await h.fake.release("searchTexts")
        try await waitUntil { h.cache.searchIndex.search(folder: "INBOX", query: "room 302")?.uids.contains(55) == true }

        h.model.stopPolling()
        await h.fake.release("summaries")
        await search.value
        await h.model.waitForSearchCatchUp()
        #expect(await h.fake.calls.filter { $0.hasPrefix("summaries ") } == ["summaries INBOX [58]"])

        h.model.startPolling()
        await h.model.waitForSearchCatchUp()
        h.model.stopPolling()
        #expect(h.model.displayedRows.map(\.uid) == [58, 55])
    }

    @Test func aCatchUpThatFailsLeavesItsMatchesForTheNextOne() async {
        let h = Self.harness(warmDelay: {}, catchUpDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[54].detail?.textBody = "Room 302"
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        h.model.searchText = "room 302"
        await h.model.submitSearch()

        await h.fake.update { $0.summariesError = .protocolError("NO") }
        await h.fake.release("searchTexts")
        await h.model.waitForIndex()
        await h.model.waitForSearchCatchUp()
        #expect(h.model.displayedRows.isEmpty)

        await h.fake.update { $0.summariesError = nil }
        h.model.stopPolling()
        h.model.startPolling()
        await h.model.waitForSearchCatchUp()
        h.model.stopPolling()
        #expect(h.model.displayedRows.map(\.uid) == [55])
    }

    @Test func anUnreadOnlySearchPagesOnWhenACatchUpAddsOnlyReadMail() async {
        let h = Self.harness(inboxCount: 120, warmDelay: {}, catchUpDelay: {})
        await h.fake.update { fake in
            for uid in Array(stride(from: 22, through: 120, by: 2)) + [1] {
                fake.folders["INBOX"]?[uid - 1].detail?.textBody = "Room 302"
            }
            fake.hold("searchTexts")
        }
        await h.model.load()
        await h.fake.waitForArrival("searchTexts")
        h.model.unreadOnly = true
        h.model.searchText = "room 302"
        await h.model.submitSearch()

        await h.fake.release("searchTexts")
        await h.model.waitForIndex()
        await h.model.waitForSearchCatchUp()
        #expect(h.model.searchResults?.count == 51)
        #expect(h.model.displayedRows.map(\.uid) == [1])
    }

    @Test func searchResultsPastThePageLoadAtTheEnd() async throws {
        let h = await Self.indexedHarness()
        h.model.searchText = "公告"
        await h.model.submitSearch()
        #expect(h.model.displayedRows.count == 50)
        let last = try #require(h.model.displayedRows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.displayedRows.count == 60)
        #expect(h.model.displayedRows.last?.uid == 1)
    }

    @Test func aFolderRecreatedBeforeTheNextSearchPageIsNotListedAsMatches() async throws {
        let h = await Self.indexedHarness()
        h.model.searchText = "公告"
        await h.model.submitSearch()
        let last = try #require(h.model.displayedRows.last)
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.searchResults?.isEmpty == true)
    }

    @Test func aFolderRecreatedBetweenTheSearchAndItsFirstPageListsNoStaleMail() async {
        let h = Self.harness()
        await h.model.load()
        await h.fake.hold("summaries")
        h.model.searchText = "公告 60"
        let search = Task { await h.model.submitSearch() }
        await h.fake.waitForArrival("summaries")
        await h.fake.update { $0.uidValidity["INBOX"] = 2 }
        await h.fake.release("summaries")
        await search.value

        #expect(h.model.searchResults?.isEmpty == true)
        #expect(!h.model.searchUsedLocalFallback)
    }

    @Test func aSearchPageWithNothingToShowDoesNotStallThePaging() async {
        let h = await Self.indexedHarness()
        await h.fake.update { fake in
            fake.folders["INBOX"] = (UInt32(1)...60).map {
                FakeMailClient.message(uid: $0, subject: "公告 \($0)", deleted: $0 > 10)
            }
        }
        h.model.searchText = "公告"
        await h.model.submitSearch()
        #expect(h.model.displayedRows.map(\.uid) == Array((UInt32(1)...10).reversed()))
    }

    @Test func searchFallsBackToTheIndexMatchesAmongLoadedMailWhenTheServerCannotBeReached() async {
        let h = Self.harness(warmDelay: {})
        await h.fake.update { fake in
            fake.folders["INBOX"]?[49].detail?.textBody = "獎學金申請"
            fake.folders["INBOX"]?[5].detail?.textBody = "獎學金申請"
        }
        await h.model.load()
        await h.model.waitForIndex()
        await h.fake.update { $0.summariesError = .unreachable }
        h.model.searchText = "獎學金"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback)
        #expect(h.model.serverStatus == .failed)
        #expect(h.model.displayedRows.map(\.uid) == [50])
        await h.fake.update { $0.summariesError = nil }
        h.model.searchText = "公告 60"
        await h.model.submitSearch()
        #expect(!h.model.searchUsedLocalFallback)
        #expect(h.model.displayedRows.map(\.uid) == [60])
        h.model.clearSearch()
        #expect(h.model.displayedRows.count == 50)
    }

    @Test func togglingReadUpdatesLocallyAndOnTheServer() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let unread = try #require(h.model.rows.first { !$0.summary.isSeen })
        await h.model.toggleRead(unread)
        #expect(h.model.rows.first { $0.uid == unread.uid }?.summary.isSeen == true)
        #expect(await h.fake.calls.contains("setFlag seen true [\(unread.uid)]"))
    }

    @Test func pollingReloadsWhenNewMailArrives() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4)) }
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 2)
        #expect(h.model.rows.first?.uid == 4)
        #expect(h.seen.noted.map(\.uidNext) == [5])
    }

    @Test func thePollReloadsForMailAlreadyReadElsewhere() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4, seen: true)) }
        await h.model.pollOnce()
        #expect(h.model.rows.first?.uid == 4)
    }

    @Test func thePollLeavesACurrentListAloneAfterTheNewestMailWasDeleted() async {
        let h = Self.harness(inboxCount: 3)
        await h.fake.update {
            $0.folders["INBOX"]?.removeAll { $0.summary.uid == 3 }
            $0.uidNext["INBOX"] = 4
        }
        await h.model.load()
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
        #expect(h.seen.noted.map(\.uidNext) == [4])
    }

    @Test func aPollWithNoNewMailMovesTheLastUpdateUp() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let loadedAt = try #require(h.model.syncedAt)
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
        #expect(try #require(h.model.syncedAt) > loadedAt)
    }

    @Test func aPollsMovedUpTimeIsCached() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.model.pollOnce()

        let polledAt = try #require(h.model.syncedAt)
        for folder in ["INBOX", Self.sent] {
            let cached = try #require(h.cache.loadPage(folder: folder)?.fetchedAt)
            #expect(abs(cached.timeIntervalSince(polledAt)) < 0.001)
        }
    }

    @Test func aPollAfterAFailedLoadKeepsTheCachedTime() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let cachedAt = try #require(h.model.syncedAt)

        await h.fake.update { $0.pageError = .serverBusy }
        let visit = MailListViewModel(
            session: MailPageSession(idleClose: .milliseconds(10), open: { h.fake }, signOutEvents: NotificationCenter()),
            cache: h.cache, noteSeenByPage: { _ in }, signOutEvents: NotificationCenter(),
            warmDelay: { try? await Task.sleep(for: .seconds(86_400)) }
        )
        await visit.load()
        #expect(visit.serverStatus == .failed)
        await h.fake.update { $0.pageError = nil }
        await visit.pollOnce()

        let syncedAt = try #require(visit.syncedAt)
        #expect(abs(syncedAt.timeIntervalSince(cachedAt)) < 0.001)
    }

    @Test func thePollReloadsAllMailForMailSentElsewhere() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        #expect(h.model.selection == .allMail)
        await h.fake.update { $0.folders[Self.sent]?.append(FakeMailClient.message(uid: 1, subject: "寄件 1")) }
        await h.model.pollOnce()
        #expect(h.model.rows.contains { $0.folder == Self.sent && $0.uid == 1 })
    }

    @Test func aPollWhoseSentReloadFailedKeepsTheLastUpdate() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let loadedAt = try #require(h.model.syncedAt)
        await h.fake.update {
            $0.folders[Self.sent]?.append(FakeMailClient.message(uid: 1))
            $0.pageErrors[Self.sent] = .serverBusy
        }
        await h.model.pollOnce()
        #expect(h.model.syncedAt == loadedAt)
    }

    @Test func aFailedSentStatusStillLetsThePollFindNewMail() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.fake.update {
            $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4))
            $0.statusErrors[Self.sent] = .serverBusy
        }
        await h.model.pollOnce()
        #expect(h.model.rows.contains { $0.folder == "INBOX" && $0.uid == 4 })
    }

    @Test func aPollWhoseReloadFailedKeepsTheLastUpdate() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let loadedAt = try #require(h.model.syncedAt)
        await h.fake.update {
            $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4))
            $0.pageError = .serverBusy
        }
        await h.model.pollOnce()
        #expect(h.model.syncedAt == loadedAt)
    }

    @Test func aFailedReloadLeavesTheMarker() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.fake.update {
            $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4))
            $0.pageError = .serverBusy
        }
        await h.model.pollOnce()
        #expect(h.seen.noted.isEmpty)
    }

    @Test func returningToTheAppPollsWithoutWaitingAMinute() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 4)) }
        h.model.startPolling(pollFirst: true)
        try await waitUntil { h.model.rows.first?.uid == 4 }
        h.model.stopPolling()
    }

    @Test func switchingFoldersLoadsThatFolder() async {
        let h = Self.harness()
        await h.model.load()
        await h.model.select(.real(MailFolderRole.trash.imapName))
        #expect(h.model.rows.map(\.summary.subject) == ["舊信"])
        #expect(h.model.selection == .real(MailFolderRole.trash.imapName))
    }

    @Test func listDatesShowTheTimeTodayAndTheDateOtherwise() {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00+08:00")!
        #expect(MailDateFormatter.listString(for: now.addingTimeInterval(-3300), now: now) == "11:05")
        #expect(MailDateFormatter.listString(for: now.addingTimeInterval(-13 * 3600), now: now) == "9/15")
    }

    @Test func settingFlagsAfterAFolderChangeDropsTheCacheAndReloads() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let unread = try #require(h.model.rows.first { !$0.summary.isSeen })
        await h.fake.update { $0.setFlagError = .folderChanged }
        await h.model.toggleRead(unread)
        #expect(h.model.rows.first { $0.uid == unread.uid }?.summary.isSeen == unread.summary.isSeen)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 2)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == h.model.rows.count)
    }

    @Test func aFolderChangeDropsTheCacheEvenWhenTheRecoveryReloadFails() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 999, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 777)], oldestLoadedSequence: nil))
        let unread = try #require(h.model.rows.first { !$0.summary.isSeen })
        await h.fake.update {
            $0.setFlagError = .folderChanged
            $0.pageError = .unreachable
        }
        await h.model.toggleRead(unread)
        #expect(h.cache.loadPage(folder: "INBOX") == nil)
    }

    @Test func authFailureShowsTheErrorAndNeverLoops() async {
        let h = Self.harness(open: { throw MailClientError.authenticationFailed })
        await h.model.load()
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError.credentials.message))
        await h.model.pollOnce()
        #expect(h.seen.noted.isEmpty)
    }

    @Test func switchingFoldersWhileASearchIsInFlightDiscardsTheStaleResults() async throws {
        let h = Self.harness()
        await h.model.load()
        h.model.searchText = "公告 60"
        await h.fake.hold("summaries")
        let searchTask = Task { await h.model.submitSearch() }
        await h.fake.waitForArrival("summaries")
        await h.model.select(.real(MailFolderRole.trash.imapName))
        await h.fake.release("summaries")
        await searchTask.value
        #expect(h.model.searchResults == [])
        #expect(h.model.rows.map(\.summary.subject) == ["舊信"])
        #expect(h.model.selection == .real(MailFolderRole.trash.imapName))
    }

    @Test func pollingReloadDoesNotDiscardPaginatedOlderMail() async throws {
        let h = Self.harness()
        await h.model.load()
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 60)
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 61)) }
        await h.model.pollOnce()
        #expect(h.model.rows.count == 61)
        #expect(h.model.rows.first?.uid == 61)
        #expect(h.model.rows.last?.uid == 1)
    }

    @Test func aRefreshAfterPaginatingKeepsThePaginationCursor() async throws {
        let h = Self.harness()
        await h.model.load()
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 60)
        let pagesBeforePoll = await h.fake.calls.filter { $0 == "page INBOX" }.count
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 61)) }
        await h.model.pollOnce()
        let pagesAfterPoll = await h.fake.calls.filter { $0 == "page INBOX" }.count
        #expect(pagesAfterPoll > pagesBeforePoll)
        let lastAfterPoll = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: lastAfterPoll)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == pagesAfterPoll)
    }

    @Test func paginatingAcrossAFolderRecreationRecoversInsteadOfMerging() async throws {
        let h = Self.harness(inboxCount: 60)
        await h.model.load()
        #expect(h.model.rows.count == 50)
        let last = try #require(h.model.rows.last)
        await h.fake.update { fake in
            fake.uidValidity["INBOX"] = 2
            fake.folders["INBOX"] = (UInt32(1)...3).map { FakeMailClient.message(uid: $0, subject: "新信 \($0)") }
        }
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.map(\.uid) == [3, 2, 1])
        #expect(h.model.rows.allSatisfy { $0.summary.subject?.hasPrefix("新信") == true })
        #expect(h.cache.loadPage(folder: "INBOX")?.uidValidity == 2)
    }

    @Test func aSecondLoadForTheSameFolderWhileOneIsInFlightIsANoOp() async throws {
        let h = Self.harness()
        async let first: Void = h.model.load()
        async let second: Void = h.model.load()
        _ = await (first, second)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
    }

    @Test func aRefreshRemovesAMessageDeletedElsewhereWithinItsWindow() async throws {
        let h = Self.harness(inboxCount: 5)
        await h.model.load()
        #expect(h.model.rows.map(\.uid) == [5, 4, 3, 2, 1])
        await h.fake.update { $0.folders["INBOX"]?.removeAll { $0.summary.uid == 3 } }
        await h.model.load()
        #expect(h.model.rows.map(\.uid) == [5, 4, 2, 1])
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.map(\.uid) == [5, 4, 2, 1])
    }

    @Test func anEmptyFreshPageEmptiesTheList() async throws {
        let h = Self.harness(inboxCount: 5)
        await h.model.load()
        #expect(h.model.rows.count == 5)
        await h.fake.update { $0.folders["INBOX"] = [] }
        await h.model.load()
        #expect(h.model.rows.isEmpty)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.isEmpty == true)
    }

    @Test func anAllDeletedWindowKeepsTheLoadedListInsteadOfBlankingIt() async throws {
        let h = Self.harness(inboxCount: 60)
        await h.model.load()
        #expect(h.model.rows.count == 50)
        await h.fake.update { fake in
            fake.folders["INBOX"] = (fake.folders["INBOX"] ?? []).map { message in
                var message = message
                if message.summary.uid >= 11 { message.summary.isDeleted = true }
                return message
            }
        }
        await h.model.load()
        #expect(!h.model.rows.isEmpty)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.isEmpty == false)
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.contains { $0.uid == 10 })
    }

    @Test func anAllDeletedWindowWalksBackToMailTheServerStillServes() async throws {
        let h = Self.harness(inboxCount: 60)
        await h.fake.update { fake in
            fake.folders["INBOX"] = (fake.folders["INBOX"] ?? []).map { message in
                var message = message
                if message.summary.uid >= 11 { message.summary.isDeleted = true }
                return message
            }
        }
        await h.model.load()
        #expect(h.model.rows.map(\.uid) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == 10)
    }

    @Test func pagingBackRelistsTheRowsAPreviousVisitCached() async throws {
        let h = Self.harness(inboxCount: 120)
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 120,
                                        summaries: (UInt32(21)...120).reversed().map { SchoolMailTestDoubles.summary(uid: $0) },
                                        oldestLoadedSequence: 21, uidNext: 121))
        let deleted: Set<UInt32> = [60, 70, 71]
        await h.fake.update { fake in
            fake.folders["INBOX"] = fake.folders["INBOX"]?.map { message in
                var message = message
                if message.summary.uid == 69 { message.summary.isSeen = true }
                if deleted.contains(message.summary.uid) { message.summary.isDeleted = true }
                return message
            }
        }
        await h.model.load()
        #expect(!h.model.rows.contains { $0.uid == 71 })
        let last = try #require(h.model.rows.last)
        #expect(last.uid == 21)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.first { $0.uid == 69 }?.summary.isSeen == true)
        #expect(!h.model.rows.contains { deleted.contains($0.uid) })
        #expect(h.model.rows.last?.uid == 1)
        #expect(h.model.rows.count == 117)
    }

    @Test func aPageOfOnlyDeletedMailDoesNotEndThePaging() async throws {
        let h = Self.harness(inboxCount: 110)
        await h.fake.update { fake in
            fake.folders["INBOX"] = fake.folders["INBOX"]?.map { message in
                var message = message
                if (11...60).contains(message.summary.uid) { message.summary.isDeleted = true }
                return message
            }
        }
        await h.model.load()
        let last = try #require(h.model.rows.last)
        #expect(last.uid == 61)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.last?.uid == 1)
        #expect(h.model.rows.count == 60)
    }

    @Test func theCacheKeepsTheNewestRowsAndPagesBackFromTheNewestWindow() async throws {
        let h = Self.harness(inboxCount: 260)
        await h.model.load()
        for _ in 1...5 {
            let last = try #require(h.model.rows.last)
            await h.model.loadMoreIfNeeded(after: last)
        }
        #expect(h.model.rows.count == 260)
        await h.model.load()
        let cached = try #require(h.cache.loadPage(folder: "INBOX"))
        #expect(cached.summaries.map(\.uid) == Array((UInt32(61)...260).reversed()))
        #expect(cached.oldestLoadedSequence == 211)
        #expect(h.model.rows.count == 260)
    }
    @Test func changesReportedForAFolderTheListNoLongerShowsAreIgnored() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        let trash = MailFolderRole.trash.imapName
        await h.model.select(.real("INBOX"))
        #expect(h.model.selection == .real("INBOX"))

        h.model.removeLocally(folder: trash, uid: 4)
        #expect(h.model.rows.map(\.uid) == [4, 3, 2, 1])
        h.model.markSeenLocally(folder: trash, uid: 3, seen: true)
        #expect(h.model.rows.first { $0.uid == 3 }?.summary.isSeen == false)

        h.model.markSeenLocally(folder: "INBOX", uid: 3, seen: true)
        #expect(h.model.rows.first { $0.uid == 3 }?.summary.isSeen == true)
        h.model.removeLocally(folder: "INBOX", uid: 4)
        #expect(h.model.rows.map(\.uid) == [3, 2, 1])
    }

    @Test func aNewUIDValidityFromThePollReloadsTheList() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        let before = await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count

        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count == before)

        await h.fake.update {
            $0.uidValidity["INBOX"] = 2
            $0.folders["INBOX"] = [FakeMailClient.message(uid: 1)]
        }
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count > before)
        #expect(h.model.rows.filter { $0.folder == "INBOX" }.map(\.uid) == [1])
    }

    static func mergedHarness(inboxCount: UInt32 = 5, sentUIDs: [UInt32] = [1, 2, 3]) async -> Harness {
        let h = harness(inboxCount: inboxCount, sentUIDs: sentUIDs)
        await h.fake.update { fake in
            fake.folders[sent] = (fake.folders[sent] ?? []).map { message in
                var message = message
                message.summary.date = message.summary.date?.addingTimeInterval(0.5)
                return message
            }
        }
        return h
    }

    static func labels(_ rows: [MailListRow]) -> [String] {
        rows.map { "\($0.folder == "INBOX" ? "收" : "寄")\($0.uid)" }
    }

    @Test func theAllMailChipAppearsOnlyWhenAllMailCoversMoreThanOneFolder() async {
        let h = Self.harness()
        #expect(h.model.showsAllMailChip == false)
        await h.model.load()
        #expect(h.model.showsAllMailChip)

        let inboxOnly = Self.harness(includeSent: false)
        await inboxOnly.fake.update { $0.folders[Self.moodle] = nil }
        await inboxOnly.model.load()
        #expect(inboxOnly.model.showsAllMailChip == false)
    }

    nonisolated static let drafts = MailFolderRole.drafts.imapName
    nonisolated static let junk = MailFolderRole.junk.imapName
    nonisolated static let moodle = "Moodle &irJ6C4oOitZTQA-"

    @Test func allMailCoversEveryFolderButJunkAndTrashWhichTheWarmFetches() async {
        let h = Self.harness(inboxCount: 2, sentUIDs: [1], warmDelay: {})
        await h.fake.update { fake in
            fake.folders[Self.drafts] = [FakeMailClient.message(uid: 1, subject: "草稿")]
            fake.folders[Self.junk] = [FakeMailClient.message(uid: 1, subject: "廣告")]
            fake.folders[Self.moodle] = [FakeMailClient.message(uid: 1, subject: "課程")]
        }
        await h.model.refresh()
        await h.model.waitForWarm()

        #expect(h.model.selection == .allMail)
        #expect(h.model.targets == ["INBOX", Self.sent, Self.drafts, Self.moodle])
        #expect(Set(h.model.rows.compactMap(\.summary.subject)) == ["公告 1", "公告 2", "寄件 1", "草稿", "課程"])
        let requests = await h.fake.pageRequests
        #expect(requests.contains("\(Self.junk) \(MailConstants.warmPageSize)"))
        #expect(requests.contains("\(Self.trash) \(MailConstants.warmPageSize)"))
    }

    @Test func searchingAllMailFindsAMatchOnlyACustomFolderHolds() async {
        let h = Self.harness(inboxCount: 3, warmDelay: {})
        await h.fake.update { $0.folders[Self.moodle] = [FakeMailClient.message(uid: 4, subject: "通知", text: "作業三 繳交提醒")] }
        await h.model.load()
        await h.model.waitForIndex()

        h.model.searchText = "作業三"
        await h.model.submitSearch()

        #expect(h.model.selection == .allMail)
        #expect(h.model.displayedRows.map { "\($0.folder) \($0.uid)" } == ["\(Self.moodle) 4"])
    }

    @Test func aRejectedPasswordInOneFolderOfAllMailIsReported() async {
        let h = Self.harness(inboxCount: 3)
        await h.fake.update { $0.pageErrors[Self.moodle] = .authenticationFailed }
        await h.model.load()

        #expect(h.seen.authFailures == 1)
        #expect(h.model.serverStatus == .failed)
        #expect(Self.labels(h.model.rows) == ["收3", "收2", "收1"])
    }

    @Test func aFolderThatFailsToLoadLeavesTheOthersInAllMail() async {
        let h = Self.harness(inboxCount: 3, sentUIDs: [1])
        await h.fake.update { fake in
            fake.folders[Self.moodle] = [FakeMailClient.message(uid: 5, subject: "課程")]
            fake.pageErrors[Self.sent] = .protocolError("NO")
        }
        await h.model.load()

        #expect(h.model.selection == .allMail)
        #expect(h.model.rows.map { "\($0.folder) \($0.uid)" } == ["\(Self.moodle) 5", "INBOX 3", "INBOX 2", "INBOX 1"])
        #expect(h.model.serverStatus == .failed)
        #expect(h.model.loadState == .loaded)
    }


    @Test func theMergedFolderInterleavesTheInboxAndSentMailByDate() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        #expect(h.model.selection == .allMail)
        #expect(Self.labels(h.model.rows) == ["收5", "收4", "寄3", "收3", "寄2", "收2", "寄1", "收1"])
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
        #expect(await h.fake.calls.filter { $0 == "page \(Self.sent)" }.count == 1)
    }

    @Test func aMergedRowIsIdentifiedByItsFolderAndUIDTogether() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        let colliding = h.model.rows.filter { $0.uid == 3 }
        #expect(colliding.count == 2)
        #expect(Set(colliding.map(\.folder)) == ["INBOX", Self.sent])
        #expect(Set(colliding.map(\.id)).count == 2)
        #expect(Set(h.model.rows.map(\.id)).count == h.model.rows.count)
    }

    @Test func markingAMergedRowReadActsOnItsOwnFolderWithThatFoldersPin() async throws {
        let h = await Self.mergedHarness()
        await h.fake.update { $0.uidValidity = ["INBOX": 11, Self.sent: 22] }
        await h.model.load()
        await h.model.select(.allMail)

        let inboxRow = try #require(h.model.rows.first { $0.folder == "INBOX" && $0.uid == 3 })
        #expect(inboxRow.summary.isSeen == false)
        await h.model.toggleRead(inboxRow)
        #expect(h.model.rows.first { $0.id == inboxRow.id }?.summary.isSeen == true)
        #expect(h.model.rows.first { $0.folder == Self.sent && $0.uid == 3 }?.summary.isSeen == false)
        #expect(await h.fake.folders["INBOX"]?.first { $0.summary.uid == 3 }?.summary.isSeen == true)
        #expect(await h.fake.folders[Self.sent]?.first { $0.summary.uid == 3 }?.summary.isSeen == false)

        let sentRow = try #require(h.model.rows.first { $0.folder == Self.sent && $0.uid == 1 })
        await h.model.toggleRead(sentRow)
        #expect(h.model.rows.first { $0.id == sentRow.id }?.summary.isSeen == true)
        #expect(await h.fake.folders[Self.sent]?.first { $0.summary.uid == 1 }?.summary.isSeen == true)
        #expect(await h.fake.folders["INBOX"]?.first { $0.summary.uid == 1 }?.summary.isSeen == false)
    }

    @Test func theMergedViewLeavesEachFolderItsOwnCachedPage() async {
        let h = await Self.mergedHarness()
        await h.fake.update { $0.uidValidity = ["INBOX": 11, Self.sent: 22] }
        await h.model.load()
        await h.model.select(.allMail)
        #expect(h.cache.loadPage(folder: "INBOX")?.uidValidity == 11)
        #expect(h.cache.loadPage(folder: Self.sent)?.uidValidity == 22)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.allSatisfy { $0.subject?.hasPrefix("公告") == true } == true)
        #expect(h.cache.loadPage(folder: Self.sent)?.summaries.allSatisfy { $0.subject?.hasPrefix("寄件") == true } == true)
    }

    @Test func theMergedListEndsOnlyWhenBothFoldersAreExhausted() async throws {
        let h = await Self.mergedHarness(inboxCount: 60, sentUIDs: [1, 2, 3])
        await h.model.load()
        await h.model.select(.allMail)
        #expect(h.model.rows.count == 53)
        var last = try #require(h.model.rows.last)
        #expect(last.folder == Self.sent)

        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 63)
        #expect(Self.labels(h.model.rows).last == "收1")

        last = try #require(h.model.rows.last)
        let before = await h.fake.calls.count
        await h.model.loadMoreIfNeeded(after: last)
        #expect(await h.fake.calls.count == before)
    }

    @Test func refreshingTheMergedViewCostsOnePagePerFolderHoweverFarItIsScrolled() async throws {
        let h = await Self.mergedHarness(inboxCount: 60, sentUIDs: [1, 2, 3])
        await h.model.load()
        await h.model.select(.allMail)
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 63)

        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        await h.model.load()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count - before == h.model.targets.count)
        #expect(h.model.rows.count == 63)
    }

    @Test func theMergedViewNeverNamesASyntheticFolderToTheServer() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        h.model.searchText = "件 3"
        await h.model.submitSearch()
        let named = await h.fake.calls.filter {
            $0.hasPrefix("page ") || $0.hasPrefix("status ") || $0.hasPrefix("summaries ")
        }
        let targets = h.model.targets
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { call in targets.contains { call.contains($0) } })
    }

    @Test func searchingTheMergedViewAsksBothFoldersAndKeepsTheirFolders() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        h.model.searchText = "件 3"
        await h.model.submitSearch()
        #expect(await h.fake.calls.contains("summaries \(Self.sent) [3]"))
        #expect(h.model.searchUsedLocalFallback == false)
        #expect(Self.labels(h.model.displayedRows) == ["寄3"])
    }

    @Test func switchingMailboxRunsTheSearchInTheFieldThere() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.real("INBOX"))
        h.model.searchText = " 3 "
        await h.model.submitSearch()
        #expect(Self.labels(h.model.displayedRows) == ["收3"])

        await h.model.select(.real(Self.sent))

        #expect(Self.labels(h.model.displayedRows) == ["寄3"])
        #expect(await h.fake.calls.contains("summaries \(Self.sent) [3]"))
    }

    @Test func anUnreachableServerFallsBackToTheLoadedMailOfBothMergedFolders() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        await h.fake.update { $0.summariesError = .unreachable }
        h.model.searchText = "3"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback)
        #expect(Self.labels(h.model.displayedRows) == ["寄3", "收3"])
    }

    @Test func changesReportedForAMergedFolderActOnThatFolderAlone() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)

        h.model.markSeenLocally(folder: Self.sent, uid: 3, seen: true)
        #expect(h.model.rows.first { $0.folder == Self.sent && $0.uid == 3 }?.summary.isSeen == true)
        #expect(h.model.rows.first { $0.folder == "INBOX" && $0.uid == 3 }?.summary.isSeen == false)

        h.model.removeLocally(folder: Self.sent, uid: 3)
        #expect(!h.model.rows.contains { $0.folder == Self.sent && $0.uid == 3 })
        #expect(h.model.rows.contains { $0.folder == "INBOX" && $0.uid == 3 })

        let trash = MailFolderRole.trash.imapName
        let before = Self.labels(h.model.rows)
        h.model.markSeenLocally(folder: trash, uid: 1, seen: true)
        h.model.removeLocally(folder: trash, uid: 1)
        #expect(Self.labels(h.model.rows) == before)
    }

    @Test func thePollReloadsTheMergedViewBecauseTheInboxIsInIt() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        #expect(h.model.selection == .allMail)
        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 1_000)) }
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count == before + h.model.targets.count)
    }

    @Test func thePollLeavesAFolderWithoutTheInboxAlone() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.real(MailFolderRole.trash.imapName))
        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 1_000)) }
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count == before)
        #expect(await !h.fake.calls.contains("status INBOX"))
    }

    @Test func theListOpensOnTheMergedView() async {
        let h = await Self.mergedHarness()
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.targets == ["INBOX"])

        await h.model.load()
        #expect(h.model.selection == .allMail)
        #expect(h.model.targets == ["INBOX", Self.sent, Self.moodle])
        #expect(Self.labels(h.model.rows) == ["收5", "收4", "寄3", "收3", "寄2", "收2", "寄1", "收1"])
    }

    @Test func theListOpensOnTheInboxWhenThereIsNothingToMerge() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.fake.update { $0.folders[Self.moodle] = nil }
        await h.model.load()
        #expect(h.model.showsAllMailChip == false)
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.rows.map(\.uid) == [4, 3, 2, 1])
    }

    @Test func theListStaysOnTheInboxWhenTheFoldersAreNeverKnown() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil))
        await h.model.load()
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.rows.map(\.uid) == [9])
    }

    @Test func aDeepLinkedFolderSurvivesTheDefault() async {
        let h = await Self.mergedHarness()
        await h.model.select(.real("INBOX"))
        await h.model.load()
        #expect(h.model.selection == .real("INBOX"))
        #expect(Self.labels(h.model.rows) == ["收5", "收4", "收3", "收2", "收1"])

        let other = await Self.mergedHarness()
        await other.model.select(.real(MailFolderRole.trash.imapName))
        await other.model.load()
        #expect(other.model.selection == .real(MailFolderRole.trash.imapName))
    }

    @Test func theMergedChipComesFirst() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        let entries = MailFolderChipBar.entries(roles: h.model.folderRoles, others: h.model.otherFolders,
                                                showsAllMail: h.model.showsAllMailChip)
        #expect(entries.first == .allMail)
        #expect(entries == [
            .allMail,
            .role(.inbox, folder: "INBOX"),
            .role(.sent, folder: Self.sent),
            .role(.trash, folder: MailFolderRole.trash.imapName),
            .more(["Moodle &irJ6C4oOitZTQA-"]),
        ])
    }

    @Test func theChipsAreJustTheFoldersWhenThereIsNothingToMerge() {
        let entries = MailFolderChipBar.entries(roles: [.inbox: "INBOX"], others: [], showsAllMail: false)
        #expect(entries == [.role(.inbox, folder: "INBOX")])
    }

    #if DEBUG
    @Test func aServerChangeDropsTheResolvedRolesPagesAndRows() async {
        let h = Self.harness()
        await h.model.load()
        #expect(!h.model.rows.isEmpty)
        #expect(!h.model.folderRoles.isEmpty)
        h.model.markSeenLocally(folder: "INBOX", uid: 59)
        await h.model.select(.real("INBOX"))

        h.model.resetForServerChange()

        #expect(h.model.rows.isEmpty)
        #expect(h.model.folderRoles.isEmpty)
        #expect(h.model.otherFolders.isEmpty)
        #expect(h.model.searchResults == nil)
        #expect(h.model.searchText.isEmpty)
        #expect(!h.model.unreadOnly)
        #expect(h.model.loadState == .idle)
        #expect(h.model.serverStatus == .unknown)
        #expect(h.model.selection == .real("INBOX"))
        #expect(!h.model.showsAllMailChip)
    }

    @Test func thePageLoadsAgainAfterAServerChange() async {
        let h = Self.harness()
        await h.model.load()
        h.model.resetForServerChange()
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(!h.model.folderRoles.isEmpty)
        #expect(h.model.rows.count == 50)
    }
    #endif

    @Test func aSignOutClearsTheList() async {
        let center = NotificationCenter()
        let h = Self.harness(inboxCount: 4, signOutEvents: center)
        await h.model.load()
        #expect(!h.model.rows.isEmpty)
        center.post(name: MailAccountManager.didSignOut, object: nil)
        #expect(h.model.rows.isEmpty)
        #expect(h.model.folderRoles.isEmpty)
        #expect(h.model.loadState == .idle)
        #expect(h.model.serverStatus == .unknown)
    }

    @Test func aLoadASignOutOvertookWritesNothing() async {
        let center = NotificationCenter()
        let h = Self.harness(inboxCount: 4, includeSent: false, signOutEvents: center)
        await h.model.load()
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 5)) }
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 0, summaries: [], oldestLoadedSequence: nil))

        await h.fake.hold("page")
        let load = Task { await h.model.load() }
        await h.fake.waitForArrival("page")
        center.post(name: MailAccountManager.didSignOut, object: nil)
        await h.fake.release("page")
        await load.value

        #expect(h.model.rows.isEmpty)
        #expect(h.model.loadState == .idle)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.isEmpty == true)
    }

    @Test func savesQueuedBeforeASignOutLandNothingAfterItsWipe() async {
        let center = NotificationCenter()
        let h = Self.harness(includeSent: false, signOutEvents: center)
        await h.model.load()
        for seen in Array(repeating: [true, false], count: 20).joined() {
            h.model.markSeenLocally(folder: "INBOX", uid: 1, seen: seen)
        }

        center.post(name: MailAccountManager.didSignOut, object: nil)
        h.cache.clearAll()
        await h.model.waitForCacheWrites()

        #expect(h.cache.loadPage(folder: "INBOX") == nil)
    }

    actor DelayGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    nonisolated static let trash = MailFolderRole.trash.imapName

    @Test func openingTheListWarmsTheFoldersItIsNotShowing() async {
        let h = Self.harness(warmDelay: {})
        await h.model.refresh()
        await h.model.waitForWarm()
        #expect(h.model.selection == .allMail)
        let requests = await h.fake.pageRequests
        #expect(requests.contains("\(Self.trash) \(MailConstants.warmPageSize)"))
        #expect(requests.filter { $0.hasPrefix(Self.trash) }.count == 1)
        #expect(requests.contains("INBOX \(MailConstants.pageSize)"))
        #expect(h.cache.loadPage(folder: Self.trash)?.summaries.count == 1)
        #expect(h.model.rows.allSatisfy { $0.folder != Self.trash })
    }

    @Test func aWarmFailureNeverReachesTheScreen() async {
        let h = Self.harness(warmDelay: {})
        await h.fake.update { $0.pageErrors = [Self.trash: .protocolError("no")] }
        await h.model.refresh()
        await h.model.waitForWarm()
        #expect(await h.fake.pageRequests.contains { $0.hasPrefix(Self.trash) })
        #expect(h.model.loadState == .loaded)
        #expect(h.model.serverStatus == .ok)
    }

    @Test func aWarmNeverShortensADeeperCache() async {
        let h = Self.harness(warmDelay: {})
        let deep = (1...30).map { SchoolMailTestDoubles.summary(uid: UInt32($0)) }
        h.cache.savePage(MailFolderPage(folder: Self.trash, uidValidity: 1, messageCount: 30, summaries: deep, oldestLoadedSequence: nil))
        await h.model.refresh()
        await h.model.waitForWarm()
        #expect(h.cache.loadPage(folder: Self.trash)?.summaries.count == 30)
    }

    @Test func warmWriteRule() {
        func page(_ count: Int, validity: UInt32 = 1) -> MailFolderPage {
            MailFolderPage(folder: "F", uidValidity: validity, messageCount: count,
                           summaries: (0..<count).map { SchoolMailTestDoubles.summary(uid: UInt32($0 + 1)) },
                           oldestLoadedSequence: nil)
        }
        #expect(MailListViewModel.warmShouldWrite(page(20), over: nil))
        #expect(MailListViewModel.warmShouldWrite(page(20), over: page(10)))
        #expect(MailListViewModel.warmShouldWrite(page(20), over: page(20)))
        #expect(!MailListViewModel.warmShouldWrite(page(20), over: page(50)))
        #expect(MailListViewModel.warmShouldWrite(page(20), over: page(50, validity: 2)))
    }

    @Test func aFolderSwitchWarmsWhatTheUserLeft() async {
        let h = Self.harness(warmDelay: {})
        await h.model.refresh()
        await h.model.waitForWarm()
        await h.model.select(.real(Self.trash))
        await h.model.waitForWarm()
        let requests = await h.fake.pageRequests
        #expect(requests.contains("INBOX \(MailConstants.warmPageSize)"))
        #expect(requests.contains("\(Self.sent) \(MailConstants.warmPageSize)"))
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == 50)
    }

    @Test func comingBackResumesAWarmThatNeverRan() async {
        let gate = DelayGate()
        let h = Self.harness(warmDelay: { await gate.wait() })
        await h.model.refresh()
        h.model.stopPolling()
        await gate.open()
        h.model.startPolling()
        await h.model.waitForWarm()
        #expect(await h.fake.pageRequests.filter { $0.hasPrefix(Self.trash) }.count == 1)
        h.model.stopPolling()
        let before = await h.fake.pageRequests.count
        h.model.startPolling()
        await h.model.waitForWarm()
        #expect(await h.fake.pageRequests.count == before)
        h.model.stopPolling()
    }

    @Test func aRefreshStopsTheWarmBeforeItStarts() async {
        let gate = DelayGate()
        let h = Self.harness(warmDelay: { await gate.wait() })
        await h.model.refresh()
        let before = await h.fake.pageRequests.count
        await h.model.refresh()
        let afterRefresh = await h.fake.pageRequests
        #expect(afterRefresh.count > before)
        #expect(!afterRefresh.contains { $0.hasPrefix(Self.trash) })
        await gate.open()
        await h.model.waitForWarm()
        #expect(await h.fake.pageRequests.filter { $0.hasPrefix(Self.trash) }.count == 1)
    }

    @Test func aPolledArrivalsBodyIsCached() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.model.load()
        await h.fake.update { $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 5, text: "new")) }
        await h.model.pollOnce()
        #expect(h.model.rows.first?.uid == 5)
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 5"])
        #expect(await h.fake.detailsWithoutImages == [5])
        await h.model.waitForCacheWrites()
        #expect(h.cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5)?.textBody == "new")
    }

    @Test func aBurstPrefetchesOnlyTheNewestFive() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.model.load()
        await h.fake.update { fake in
            for uid in UInt32(5)...12 { fake.folders["INBOX"]?.append(FakeMailClient.message(uid: uid)) }
        }
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == (8...12).reversed().map { "detail INBOX \($0)" })
    }

    @Test func aFailedPrefetchLeavesThePollAlone() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.model.load()
        await h.fake.update {
            $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 5))
            $0.detailError = .protocolError("no")
        }
        await h.model.pollOnce()
        #expect(await h.fake.calls.contains("detail INBOX 5"))
        #expect(h.model.loadState == .loaded)
        #expect(h.model.serverStatus == .ok)
        #expect(h.model.rows.first?.uid == 5)
    }

    @Test func onlyNewMailIsPrefetched() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.model.load()
        await h.model.pollOnce()
        await h.fake.update {
            $0.uidValidity["INBOX"] = 2
            $0.folders["INBOX"]?.append(FakeMailClient.message(uid: 5))
        }
        await h.model.pollOnce()
        #expect(await !h.fake.calls.contains { $0.hasPrefix("detail") })
    }
}
#endif
