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
}
#endif
