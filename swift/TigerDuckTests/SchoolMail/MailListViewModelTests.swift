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

    /// `nonisolated` because the fake-server `update` closures below are nonisolated, and the
    /// suite is `@MainActor` — without it this constant is main-actor isolated and reading it
    /// from one of those closures is an error in the Swift 6 language mode. `MailFolderRole` is
    /// `nonisolated` already, so the value has nothing main-actor about it.
    nonisolated static let sent = MailFolderRole.sent.imapName

    /// `sentUIDs` seeds Sent, which All mail merges with the inbox. The folder itself always
    /// exists (the server has it whether or not the student has sent anything), so the All mail
    /// chip is offered in every harness; only the merged tests put mail in it.
    static func harness(
        inboxCount: UInt32 = 60,
        sentUIDs: [UInt32] = [],
        includeSent: Bool = true,
        open: (() async throws -> any MailClient)? = nil
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
        #expect(h.model.displayedRows.map(\.uid).contains(7))
        #expect(await h.fake.calls.contains("search INBOX 公告 7"))
    }

    @Test func searchFallsBackToLoadedMailWhenTheServerRefuses() async {
        let h = Self.harness()
        await h.model.load()
        await h.fake.update { $0.searchError = .searchUnsupported }
        h.model.searchText = "公告 60"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback)
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
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.script.calls == 1)
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 2)
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

    // MARK: Controller additions (2026-09-16 dispatch)

    /// `MailClientError.folderChanged` from a list operation (here `toggleRead` → `setFlag`)
    /// drops the folder's cached page and reloads the first page fresh from the server,
    /// instead of leaving the optimistic local change stuck against a server that rejected it.
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
        let unread = try #require(h.model.rows.first { !$0.summary.isSeen })
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
        await h.model.select(.real(MailFolderRole.trash.imapName))
        await h.fake.releaseSearch()
        await searchTask.value
        #expect(h.model.searchResults == nil)
        #expect(h.model.rows.map(\.summary.subject) == ["舊信"])
        #expect(h.model.selection == .real(MailFolderRole.trash.imapName))
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
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 60)
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.model.rows.count == 60)
        #expect(h.model.rows.first?.uid == 60)
        #expect(h.model.rows.last?.uid == 1)
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
        #expect(h.model.rows.map(\.uid) == [5, 4, 3, 2, 1])
        await h.fake.update { $0.folders["INBOX"]?.removeAll { $0.summary.uid == 3 } }
        await h.model.load()
        #expect(h.model.rows.map(\.uid) == [5, 4, 2, 1])
        #expect(h.cache.loadPage(folder: "INBOX")?.summaries.map(\.uid) == [5, 4, 2, 1])
    }

    /// An empty fresh page (everything in the folder was deleted, or a transient empty read)
    /// must empty the list rather than leaving stale entries behind indefinitely.
    @Test func anEmptyFreshPageEmptiesTheList() async throws {
        let h = Self.harness(inboxCount: 5)
        await h.model.load()
        #expect(h.model.rows.count == 5)
        await h.fake.update { $0.folders["INBOX"] = [] }
        await h.model.load()
        #expect(h.model.rows.isEmpty)
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
        // And pagination still reaches the mail the server does still serve.
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.contains { $0.uid == 10 })
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
        #expect(h.model.rows.map(\.uid) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
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
        // A single-folder selection, stated rather than inherited: the list opens on All mail,
        // and the merged case has its own test below.
        await h.model.select(.real("INBOX"))
        #expect(h.model.selection == .real("INBOX"))

        h.model.removeLocally(folder: trash, uid: 4)
        #expect(h.model.rows.map(\.uid) == [4, 3, 2, 1])
        h.model.markSeenLocally(folder: trash, uid: 3, seen: true)
        #expect(h.model.rows.first { $0.uid == 3 }?.summary.isSeen == false)

        // The same calls for the folder actually on screen still act.
        h.model.markSeenLocally(folder: "INBOX", uid: 3, seen: true)
        #expect(h.model.rows.first { $0.uid == 3 }?.summary.isSeen == true)
        h.model.removeLocally(folder: "INBOX", uid: 4)
        #expect(h.model.rows.map(\.uid) == [3, 2, 1])
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

    // MARK: All mail — the client-side merge of Inbox and Sent

    /// Sent's UIDs deliberately collide with the inbox's: that is the normal case, not an
    /// edge one — a UID means something only inside its own folder. Its dates are nudged half a
    /// second later than the inbox mail of the same number, so the merged order has something to
    /// interleave by and the assertions below read as a genuine interleave rather than one
    /// folder after the other.
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

    /// `收3` / `寄3` — the folder and the UID, which is the only honest name for a merged row.
    static func labels(_ rows: [MailListRow]) -> [String] {
        rows.map { "\($0.folder == "INBOX" ? "收" : "寄")\($0.uid)" }
    }

    @Test func theAllMailChipAppearsOnlyWhenBothFoldersResolve() async {
        let h = Self.harness()
        #expect(h.model.showsAllMailChip == false)
        await h.model.load()
        #expect(h.model.showsAllMailChip)

        let withoutSent = Self.harness(includeSent: false)
        await withoutSent.model.load()
        #expect(withoutSent.model.showsAllMailChip == false)
    }

    @Test func theMergedFolderInterleavesTheInboxAndSentMailByDate() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        #expect(h.model.selection == .allMail)
        #expect(Self.labels(h.model.rows) == ["收5", "收4", "寄3", "收3", "寄2", "收2", "寄1", "收1"])
        // One page per folder and no more: the list already opened here, so the `select` above
        // only states this test's subject and costs nothing. A second `page INBOX` would mean
        // the opening load had read Inbox alone and then thrown that away to read both.
        #expect(await h.fake.calls.filter { $0 == "page INBOX" }.count == 1)
        #expect(await h.fake.calls.filter { $0 == "page \(Self.sent)" }.count == 1)
    }

    /// A UID alone names two different mails here. The row identity the list keys on — and that
    /// the swipe gesture and the in-place update after an action find a row again by — has to be
    /// the folder and the UID together.
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

    /// The governing rule, and the one the UIDVALIDITY pin makes testable: each folder is given
    /// its own generation here, so an action that pinned the *selected* view's idea of a folder
    /// rather than the row's own would be refused by the server as `folderChanged` and revert.
    @Test func markingAMergedRowReadActsOnItsOwnFolderWithThatFoldersPin() async throws {
        let h = await Self.mergedHarness()
        await h.fake.update { $0.uidValidity = ["INBOX": 11, Self.sent: 22] }
        await h.model.load()
        await h.model.select(.allMail)

        let inboxRow = try #require(h.model.rows.first { $0.folder == "INBOX" && $0.uid == 3 })
        #expect(inboxRow.summary.isSeen == false)
        await h.model.toggleRead(inboxRow)
        #expect(h.model.rows.first { $0.id == inboxRow.id }?.summary.isSeen == true)
        // The Sent mail that shares the number is untouched — in the list and on the server.
        #expect(h.model.rows.first { $0.folder == Self.sent && $0.uid == 3 }?.summary.isSeen == false)
        #expect(await h.fake.folders["INBOX"]?.first { $0.summary.uid == 3 }?.summary.isSeen == true)
        #expect(await h.fake.folders[Self.sent]?.first { $0.summary.uid == 3 }?.summary.isSeen == false)

        let sentRow = try #require(h.model.rows.first { $0.folder == Self.sent && $0.uid == 1 })
        await h.model.toggleRead(sentRow)
        #expect(h.model.rows.first { $0.id == sentRow.id }?.summary.isSeen == true)
        #expect(await h.fake.folders[Self.sent]?.first { $0.summary.uid == 1 }?.summary.isSeen == true)
        #expect(await h.fake.folders["INBOX"]?.first { $0.summary.uid == 1 }?.summary.isSeen == false)
    }

    /// No new persisted model and no migration: the merge is composed at read time from the two
    /// folders' existing cache entries, each still keyed by its own folder and carrying its own
    /// UIDVALIDITY — which is exactly what the message screen reads to pin a move or a delete.
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

    /// One cursor per folder: the merged list ends only once *both* folders genuinely have,
    /// never merely because the sparser of the two did. Note the sentinel row load-more hangs
    /// off here belongs to Sent, which ran out first — the inbox still advances.
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

        // Both are exhausted now, so a further load-more asks the server nothing at all.
        last = try #require(h.model.rows.last)
        let before = await h.fake.calls.count
        await h.model.loadMoreIfNeeded(after: last)
        #expect(await h.fake.calls.count == before)
    }

    /// Two round trips per refresh however far the merged list has been scrolled — Mail2000 caps
    /// connections and starts answering "The mail server is busy" under load — and the refresh
    /// keeps what was paginated in rather than replacing it.
    @Test func refreshingTheMergedViewCostsOnePagePerFolderHoweverFarItIsScrolled() async throws {
        let h = await Self.mergedHarness(inboxCount: 60, sentUIDs: [1, 2, 3])
        await h.model.load()
        await h.model.select(.allMail)
        let last = try #require(h.model.rows.last)
        await h.model.loadMoreIfNeeded(after: last)
        #expect(h.model.rows.count == 63)

        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        await h.model.load()
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count - before == 2)
        #expect(h.model.rows.count == 63)
    }

    /// All mail is not a folder name and must never become one: everything the merged view asks
    /// the server names a folder the server actually has.
    @Test func theMergedViewNeverNamesASyntheticFolderToTheServer() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        h.model.searchText = "件 3"
        await h.model.submitSearch()
        let named = await h.fake.calls.filter {
            $0.hasPrefix("page ") || $0.hasPrefix("search ") || $0.hasPrefix("status ") || $0.hasPrefix("summaries ")
        }
        #expect(!named.isEmpty)
        #expect(named.allSatisfy { $0.contains("INBOX") || $0.contains(Self.sent) })
    }

    /// One SEARCH per folder, merged the same way the list is, and each result keeps the folder
    /// it was found in so opening it still goes to the right place.
    @Test func searchingTheMergedViewAsksBothFoldersAndKeepsTheirFolders() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        h.model.searchText = "件 3"
        await h.model.submitSearch()
        #expect(await h.fake.calls.contains("search INBOX 件 3"))
        #expect(await h.fake.calls.contains("search \(Self.sent) 件 3"))
        #expect(h.model.searchUsedLocalFallback == false)
        #expect(Self.labels(h.model.displayedRows) == ["寄3"])
    }

    /// A folder whose server refused the search still contributes its locally matched mail, and
    /// the note appears as soon as any one of them fell back.
    @Test func aRefusedSearchInOneMergedFolderFallsBackForThatFolderOnly() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.allMail)
        await h.fake.update { $0.searchError = .searchUnsupported }
        h.model.searchText = "3"
        await h.model.submitSearch()
        #expect(h.model.searchUsedLocalFallback)
        #expect(Self.labels(h.model.displayedRows) == ["寄3", "收3"])
    }

    /// A change reported for one of the merged folders finds its row inside that folder's own
    /// page, never by UID across the merged list; a folder All mail does not merge is ignored
    /// outright, exactly as it is for a single-folder selection.
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

    /// The 60 s poll reloads whenever the inbox is on screen, and All mail has it on screen.
    /// Written as `selection == .real(inbox)` the guard would silently stop firing on the very
    /// screen the list opens on, and new mail would only ever appear on a pull-to-refresh.
    @Test func thePollReloadsTheMergedViewBecauseTheInboxIsInIt() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        #expect(h.model.selection == .allMail)
        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.script.calls == 1)
        // Both merged folders, because that is what the screen is showing.
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count == before + 2)
    }

    /// ...and a folder the inbox is not in still never reloads off the poll.
    @Test func thePollLeavesAFolderWithoutTheInboxAlone() async {
        let h = await Self.mergedHarness()
        await h.model.load()
        await h.model.select(.real(MailFolderRole.trash.imapName))
        let before = await h.fake.calls.filter { $0.hasPrefix("page ") }.count
        h.script.outcome = .newMail(1)
        await h.model.pollOnce()
        #expect(h.script.calls == 1)
        #expect(await h.fake.calls.filter { $0.hasPrefix("page ") }.count == before)
    }

    // MARK: The selection the list opens on

    /// All mail, as soon as `LIST` says there are two folders to merge — never before, because
    /// until then it resolves to no folders at all.
    @Test func theListOpensOnTheMergedView() async {
        let h = await Self.mergedHarness()
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.targets == ["INBOX"])

        await h.model.load()
        #expect(h.model.selection == .allMail)
        #expect(h.model.targets == ["INBOX", Self.sent])
        #expect(Self.labels(h.model.rows) == ["收5", "收4", "寄3", "收3", "寄2", "收2", "寄1", "收1"])
    }

    /// No Sent means no All mail chip, and a default that resolved to it anyway would leave
    /// the list reading nothing with no chip on screen to leave it by. It stays on Inbox.
    @Test func theListOpensOnTheInboxWhenThereIsNothingToMerge() async {
        let h = Self.harness(inboxCount: 4, includeSent: false)
        await h.model.load()
        #expect(h.model.showsAllMailChip == false)
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.rows.map(\.uid) == [4, 3, 2, 1])
    }

    /// The server never answered, so nothing is known about its folders — the list stays on the
    /// one selection that can read anything at all without a `LIST`, and paints its cache.
    @Test func theListStaysOnTheInboxWhenTheFoldersAreNeverKnown() async {
        let h = Self.harness(open: { throw MailClientError.unreachable })
        h.cache.savePage(MailFolderPage(folder: "INBOX", uidValidity: 1, messageCount: 1,
                                        summaries: [SchoolMailTestDoubles.summary(uid: 9)], oldestLoadedSequence: nil))
        await h.model.load()
        #expect(h.model.selection == .real("INBOX"))
        #expect(h.model.rows.map(\.uid) == [9])
    }

    /// A tapped notification names the folder the mail is actually in and selects it directly
    /// (`SchoolMailView.drainDeepLink`). It can land before `LIST` comes back — and when the
    /// folder it names is Inbox, it does not even change the selection — so the default must
    /// recognise it as a choice, not as the placeholder it happens to match, and leave it alone.
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

    /// The chip standing for what is on screen is the first one read.
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

    /// Without the chip there is nothing to put first, and the roles still lead.
    @Test func theChipsAreJustTheFoldersWhenThereIsNothingToMerge() {
        let entries = MailFolderChipBar.entries(roles: [.inbox: "INBOX"], others: [], showsAllMail: false)
        #expect(entries == [.role(.inbox, folder: "INBOX")])
    }
}
#endif
