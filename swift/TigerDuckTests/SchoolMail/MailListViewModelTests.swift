#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MailListViewModelTests {
    final class CheckScript {
        var outcome: MailCheckOutcome = .noNewMail
        var calls = 0
    }

    struct Harness {
        let model: MailListViewModel
        let fake: FakeMailClient
        let cache: MailCache
        let script: CheckScript
    }

    static func harness(inboxCount: UInt32 = 60, open: (() async throws -> any MailClient)? = nil) -> Harness {
        let inbox = (UInt32(1)...inboxCount).map { FakeMailClient.message(uid: $0, subject: "公告 \($0)", seen: $0 % 2 == 0) }
        let fake = FakeMailClient(folders: [
            "INBOX": inbox,
            MailFolderRole.trash.imapName: [FakeMailClient.message(uid: 1, subject: "舊信")],
            "Moodle &irJ6C4oOitZTQA-": [],
        ])
        let cache = SchoolMailTestDoubles.temporaryCache()
        let script = CheckScript()
        let session = MailPageSession(idleClose: .milliseconds(10), open: open ?? { fake })
        let model = MailListViewModel(session: session, cache: cache, runPageCheck: { _ in
            script.calls += 1
            return script.outcome
        })
        return Harness(model: model, fake: fake, cache: cache, script: script)
    }

    @Test func loadsFoldersAndTheNewestPage() async {
        let h = Self.harness()
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.summaries.count == 50)
        #expect(h.model.summaries.first?.uid == 60)
        #expect(h.model.folderRoles[.trash] == MailFolderRole.trash.imapName)
        #expect(h.model.otherFolders == ["Moodle &irJ6C4oOitZTQA-"])
        #expect(h.model.serverStatus == .ok)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == 50)
    }

    @Test func loadsOlderMailAtTheEnd() async throws {
        let h = Self.harness()
        await h.model.load()
        let last = try #require(h.model.summaries.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.summaries.count == 60)
        #expect(h.model.summaries.last?.uid == 1)
    }

    @Test func unreadOnlyFiltersTheList() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        h.model.unreadOnly = true
        #expect(h.model.displayedSummaries.map(\.uid) == [3, 1])
    }

    @Test func theCachedListStaysUpWhenOffline() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil))
        await h.model.load()
        #expect(h.model.loadState == .loaded)
        #expect(h.model.summaries.map(\.uid) == [9])
        #expect(h.model.serverStatus == .failed)
    }

    @Test func failingWithNothingCachedShowsTheError() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        await h.model.load()
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError.network.message))
    }

    @Test func searchAsksTheServer() async {
        let h = Self.harness()
        await h.model.load()
        h.model.searchText = "公告 7"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback == false)
        #expect(h.model.displayedSummaries.map(\.uid).contains(7))
        #expect(await h.fake.calls.contains("search INBOX 公告 7"))
    }

    @Test func searchFallsBackToLoadedMailWhenTheServerRefuses() async {
        let h = Self.harness()
        await h.model.load()
        await h.fake.update { $0.searchError = .searchUnsupported }
        h.model.searchText = "公告 60"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback)
        #expect(h.model.displayedSummaries.map(\.uid) == [60])
        h.model.clearSearch()
        #expect(h.model.displayedSummaries.count == 50)
    }

    @Test func togglingReadUpdatesLocallyAndOnTheServer() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let unread = try #require(h.model.summaries.first { !$0.isSeen })
        await h.model.toggleRead(unread)
        #expect(h.model.summaries.first { $0.uid == unread.uid }?.isSeen == true)
        #expect(await h.fake.calls.contains("setFlag seen true [\(unread.uid)]"))
    }

    @Test func pollingReloadsWhenNewMailArrives() async {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.script.calls == 1)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 2)
    }

    @Test func switchingFoldersLoadsThatFolder() async {
        let h = Self.harness()
        await h.model.load()
        await h.model.select(folder: MailFolderRole.trash.imapName)
        #expect(h.model.summaries.map(\.subject) == ["舊信"])
        #expect(h.model.title == MailFolderRole.trash.title)
    }

    @Test func listDatesShowTheTimeTodayAndTheDateOtherwise() {
        let now = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00+08:00")!
        #expect(MailDateFormatter.listString(for: now.addingTimeInterval(-3300), now: now) == "11:05")
        #expect(MailDateFormatter.listString(for: now.addingTimeInterval(-13 * 3600), now: now) == "9/15")
    }

    // MARK: Controller additions (2026-09-16 dispatch)

    /// `MailClientError.folderChanged` from a list operation (here `toggleRead` → `setFlag`)
    /// drops the folder's cached page and reloads the first page fresh from the server,
    /// instead of leaving the optimistic local change stuck against a server that rejected it.
    @Test func settingFlagsAfterAFolderChangeDropsTheCacheAndReloads() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        let unread = try #require(h.model.summaries.first { !$0.isSeen })
        await h.fake.update { $0.setFlagError = .folderChanged }
        await h.model.toggleRead(unread)
        #expect(h.model.summaries.first { $0.uid == unread.uid }?.isSeen == unread.isSeen)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 2)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == h.model.summaries.count)
    }

    /// Isolates the drop itself from the reload that follows it: a reload that *succeeds*
    /// would re-save correct data over a stale cache regardless of whether the drop actually
    /// ran, so this seeds a page the reload can never reproduce (wrong uidValidity, an extra
    /// summary the fake server doesn't have) and then makes the recovery reload itself fail —
    /// the only way that seeded page can be gone afterwards is that `recoverFromFolderChange`
    /// really did delete the cache file.
    @Test func aFolderChangeDropsTheCacheEvenWhenTheRecoveryReloadFails() async throws {
        let h = Self.harness(inboxCount: 3)
        await h.model.load()
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 999, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 777)], oldestLoadedSequence: nil))
        let unread = try #require(h.model.summaries.first { !$0.isSeen })
        await h.fake.update {
            $0.setFlagError = .folderChanged
            $0.pageError = .unreachable
        }
        await h.model.toggleRead(unread)
        #expect(h.cache.loadPage(folder: "INBOX") == nil)
    }

    /// While the account is auth-failed, `openSession()` throws `.authenticationFailed`
    /// without a LOGIN: the list shows the auth-failure state, and polling never even runs
    /// the page check (let alone loops retrying it).
    @Test func authFailureShowsTheErrorAndNeverLoops() async {
        let h = Self.harness(open: { throw MailClientError.authenticationFailed })
        await h.model.load()
        #expect(h.model.loadState == .failed(MailAccountManager.LoginError.credentials.message))
        await h.model.pollOnce()
        #expect(h.script.calls == 0)
    }

    // MARK: Fix round 1 (2026-09-18 review)

    /// Switching folders while a server search is still in flight must never let that stale
    /// search land on top of the folder the user actually switched to. `search` is gated so the
    /// folder switch deterministically lands while the search is still awaiting the server,
    /// rather than racing wall-clock timing.
    @Test func switchingFoldersWhileASearchIsInFlightDiscardsTheStaleResults() async throws {
        let h = Self.harness()
        await h.model.load()
        h.model.searchText = "公告 7"
        await h.fake.update { $0.holdSearch = true }
        let searchTask = Task { await h.model.submitSearch() }
        // Give `submitSearch` a chance to actually start and reach the gate before switching.
        try await Task.sleep(for: .milliseconds(50))
        await h.model.select(folder: MailFolderRole.trash.imapName)
        await h.fake.releaseSearch()
        await searchTask.value
        #expect(h.model.searchResults == nil)
        #expect(h.model.summaries.map(\.subject) == ["舊信"])
        #expect(h.model.selectedFolder == MailFolderRole.trash.imapName)
    }

    /// A poll-triggered (or pull-to-refresh-triggered) reload must merge the refreshed first
    /// page into what's loaded rather than replacing it — otherwise every automatic refresh
    /// would silently throw away everything the user had paginated into. This also covers fix
    /// round 2's "an entry older than the fresh page's window survives a refresh": every one
    /// of the 10 paginated-in messages below is below `fresh.summaries.last?.uid` on the
    /// second, poll-triggered fetch, and all 10 are still there afterwards.
    @Test func pollingReloadDoesNotDiscardPaginatedOlderMail() async throws {
        let h = Self.harness()
        await h.model.load()
        let last = try #require(h.model.summaries.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.summaries.count == 60)
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.model.summaries.count == 60)
        #expect(h.model.summaries.first?.uid == 60)
        #expect(h.model.summaries.last?.uid == 1)
    }

    /// A second `load()` for the same folder while one is already running (a pull-to-refresh
    /// landing during the 60 s poll's own reload, say) must not issue a redundant
    /// `listFolders`/`page` pair on the one serialized connection.
    @Test func aSecondLoadForTheSameFolderWhileOneIsInFlightIsANoOp() async throws {
        let h = Self.harness()
        async let first: Void = h.model.load()
        async let second: Void = h.model.load()
        _ = await (first, second)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
    }

    // MARK: Fix round 2 (2026-09-18 scoped re-review)

    /// A message expunged, moved or `\Deleted` elsewhere (webmail, another device) is inside
    /// the fresh page's window (its UID is at or above `fresh.summaries.last?.uid`) but is no
    /// longer in `fresh.summaries` — the merge must drop it, not keep it forever because it
    /// was once loaded, and the drop must make it into the cache too.
    @Test func aRefreshRemovesAMessageDeletedElsewhereWithinItsWindow() async throws {
        let h = Self.harness(inboxCount: 5)
        await h.model.load()
        #expect(h.model.summaries.map(\.uid) == [5, 4, 3, 2, 1])
        await h.fake.update { $0.folders["INBOX"]?.removeAll { $0.summary.uid == 3 } }
        await h.model.load()
        #expect(h.model.summaries.map(\.uid) == [5, 4, 2, 1])
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.map(\.uid) == [5, 4, 2, 1])
    }

    /// An empty fresh page (everything in the folder was deleted, or a transient empty read)
    /// must empty the list rather than leaving stale entries behind indefinitely.
    @Test func anEmptyFreshPageEmptiesTheList() async throws {
        let h = Self.harness(inboxCount: 5)
        await h.model.load()
        #expect(h.model.summaries.count == 5)
        await h.fake.update { $0.folders["INBOX"] = [] }
        await h.model.load()
        #expect(h.model.summaries.isEmpty)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.isEmpty == true)
    }

    /// A first page whose whole window is `\Deleted` — the state a partly failed delete
    /// manufactures, and the one TigerDuck reaches on its own after 50 deletes while an expunge
    /// is blocked — must not blank a list that is holding real mail, nor overwrite its cache with
    /// an empty page. The folder still has hundreds of messages; the newest 50 just aren't
    /// visible.
    @Test func anAllDeletedWindowKeepsTheLoadedListInsteadOfBlankingIt() async throws {
        let h = Self.harness(inboxCount: 60)
        await h.model.load()
        #expect(h.model.summaries.count == 50)
        await h.fake.update { fake in
            fake.folders["INBOX"] = (fake.folders["INBOX"] ?? []).map { message in
                var message = message
                if message.summary.uid >= 11 { message.summary.isDeleted = true }
                return message
            }
        }
        await h.model.load()
        #expect(!h.model.summaries.isEmpty)
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.isEmpty == false)
        // And pagination still reaches the mail the server does still serve.
        let last = try #require(h.model.summaries.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.summaries.contains { $0.uid == 10 })
    }

    /// The same window with nothing already loaded (a first open, or a reload after the folder's
    /// cache was dropped): there is no last row for pagination to hang off, so the list has to
    /// walk further back itself rather than settle on an empty mailbox the user cannot scroll
    /// out of.
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
        #expect(h.model.summaries.map(\.uid) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.count == 10)
    }
    /// A UID is only unique within its folder. `removeLocally`/`markSeenLocally` are called by
    /// the *message* screen, which can still be reporting on INBOX after a deep link switched
    /// the list to another folder — matching on UID alone stripped a same-UID row of a different
    /// message and wrote that to the other folder's cache.
    @Test func changesReportedForAFolderTheListNoLongerShowsAreIgnored() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        let trash = MailFolderRole.trash.imapName
        #expect(h.model.selectedFolder == "INBOX")

        h.model.removeLocally(folder: trash, uid: 4)
        #expect(h.model.summaries.map(\.uid) == [4, 3, 2, 1])
        h.model.markSeenLocally(folder: trash, uid: 3, seen: true)
        #expect(h.model.summaries.first { $0.uid == 3 }?.isSeen == false)

        // The same calls for the folder actually on screen still act.
        h.model.markSeenLocally(folder: "INBOX", uid: 3, seen: true)
        #expect(h.model.summaries.first { $0.uid == 3 }?.isSeen == true)
        h.model.removeLocally(folder: "INBOX", uid: 4)
        #expect(h.model.summaries.map(\.uid) == [3, 2, 1])
    }

    /// The 60 s poll used to act on `.newMail` only, so after a UIDVALIDITY change the list kept
    /// painting a generation the server had thrown away until something else forced a reload.
    @Test func aBaselineResetFromThePollReloadsTheList() async {
        let h = Self.harness(inboxCount: 4)
        await h.model.load()
        let before = await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count

        h.script.outcome = .noNewMail
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count == before)

        h.script.outcome = .baselineReset
        await h.model.pollOnce()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page INBOX") }.count > before)
    }
}
#endif
