import Foundation
import os
import Testing
@testable import TigerDuck

/// `MoodleCourseStore` over a stand-in `MoodleCourseAPI` and a `DataCache` in a folder of its
/// own: the cache comes first, writes stop at a sign-out, the site's functions gate each call,
/// and only opening an announcement tells Moodle it was read.
@MainActor
struct MoodleCourseStoreTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let newsForum = MoodleForum(
        id: 501, courseId: courseId, type: "news", name: "Announcements", cmid: 9001,
        discussionCount: 2, unreadPostCount: 1
    )
    private nonisolated static let allFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
        MoodleForumService.viewDiscussionFunction, MoodleCourseSummaryService.coursesFunction,
    ]

    private static func discussion(_ id: Int, unread: Int = 0, pinned: Bool = false, created: TimeInterval = 0) -> MoodleDiscussion {
        MoodleDiscussion(
            id: id, postId: id + 1000, title: "Announcement \(id)", message: "<p>Body \(id)</p>",
            preview: "Body \(id)", created: Date(timeIntervalSince1970: 1_790_000_000 + created),
            modified: Date(timeIntervalSince1970: 1_790_000_000 + created), isPinned: pinned,
            unreadCount: unread, replyCount: 0, authorName: "B11399001 @ Tiger Duck", attachments: []
        )
    }

    /// The calls the store made, and what the stand-in site answers.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String> = MoodleCourseStoreTests.allFunctions
        private var _forums: [MoodleForum] = [MoodleCourseStoreTests.newsForum]
        private var _pages: [[MoodleDiscussion]] = []
        private var _forumCalls: [[Int]] = []
        private var _discussionCalls: [(forumId: Int, page: Int)] = []
        private var _viewed: [Int] = []
        private var _summary = MoodleCourseStoreTests.summary
        private var _summaryCalls: [Int] = []

        func set(
            functions: Set<String>? = nil,
            forums: [MoodleForum]? = nil,
            pages: [[MoodleDiscussion]]? = nil,
            summary: MoodleCourseSummary? = nil
        ) {
            lock.withLock {
                if let functions { _functions = functions }
                if let forums { _forums = forums }
                if let pages { _pages = pages }
                if let summary { _summary = summary }
            }
        }

        var forumCalls: [[Int]] { lock.withLock { _forumCalls } }
        var discussionPages: [Int] { lock.withLock { _discussionCalls.map(\.page) } }
        var viewed: [Int] { lock.withLock { _viewed } }
        var summaryCalls: [Int] { lock.withLock { _summaryCalls } }

        /// `beforePage` runs before each page answers, with the page and how many times it was
        /// asked for before; it, `beforeForums` and `beforeSummary` throw to fail their request.
        func api(
            beforeForums: @escaping @Sendable () async throws -> Void = {},
            beforePage: @escaping @Sendable (_ page: Int, _ earlier: Int) async throws -> Void = { _, _ in },
            beforeSummary: @escaping @Sendable () async throws -> Void = {}
        ) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { courseIds in
                    self.lock.withLock { self._forumCalls.append(courseIds) }
                    try await beforeForums()
                    return self.lock.withLock { self._forums }
                },
                discussions: { forumId, page in
                    let earlier = self.lock.withLock {
                        let earlier = self._discussionCalls.filter { $0.page == page }.count
                        self._discussionCalls.append((forumId, page))
                        return earlier
                    }
                    try await beforePage(page, earlier)
                    return self.lock.withLock { page < self._pages.count ? self._pages[page] : [] }
                },
                markViewed: { id in self.lock.withLock { self._viewed.append(id) } },
                summary: { courseId in
                    self.lock.withLock { self._summaryCalls.append(courseId) }
                    try await beforeSummary()
                    return self.lock.withLock { self._summary }
                }
            )
        }
    }

    /// A cache in a folder of its own, removed when the test ends.
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseStoreTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func store(
        _ folder: Folder,
        site: Site,
        account: String = "B11399001",
        signedIn: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: true),
        beforeForums: @escaping @Sendable () async throws -> Void = {},
        beforePage: @escaping @Sendable (_ page: Int, _ earlier: Int) async throws -> Void = { _, _ in },
        beforeSummary: @escaping @Sendable () async throws -> Void = {},
        courseCodes: [String] = [],
        now: @escaping () -> Date = { Date() }
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [20103, courseId],
            courseCodes: courseCodes,
            context: MoodleCacheContext(
                account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }, now: now
            ),
            api: site.api(beforeForums: beforeForums, beforePage: beforePage, beforeSummary: beforeSummary)
        )
    }

    // MARK: - Cache

    @Test("what was fetched is shown from the cache the next time, before anything is asked")
    func cacheFirst() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801, unread: 1), Self.discussion(802)]])
        let first = Self.store(folder, site: site)
        await first.refreshForums()
        await first.refreshAnnouncements()

        let again = Self.store(folder, site: Site())
        #expect(again.sectionRows == [MoodleSectionRow(kind: .announcements, count: 2, hasUnread: true)])
        #expect(again.announcementList?.discussions.map(\.id) == [801, 802])
        #expect(again.forumsFetchedAt != nil)
        #expect(again.announcementsFetchedAt != nil)
        #expect(again.forums.status == .ok)
    }

    @Test("one forums call covers the term, and each account keeps its own copy")
    func cachePerAccount() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshForums()

        #expect(site.forumCalls == [[20103, 20119]])
        #expect(store.forums.status == .ok)
        #expect(Self.store(folder, site: Site(), account: "B11399002").forums.value == nil)
        #expect(Self.store(folder, site: Site()).newsForum == Self.newsForum)
    }

    @Test("an answer that lands after a sign-out is neither shown nor kept")
    func signOutWhileFetching() async throws {
        let folder = Folder()
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let store = Self.store(folder, site: Site(), signedIn: signedIn) {
            await answer.sleep(for: .zero)
        }

        let refresh = Task { await store.refreshForums() }
        try await answer.waitUntilArmed()
        signedIn.withLock { $0 = false }
        await answer.fire()
        await refresh.value

        #expect(store.forums.value == nil)
        #expect(store.forums.status == .unknown)
        #expect(folder.cache.loadMoodleData(MoodleTermForums.self, name: "forums", account: "B11399001") == nil)
    }

    @Test("signing out deletes every account's Moodle data")
    func signOutClearsTheCache() async {
        let folder = Folder()
        let store = Self.store(folder, site: Site())
        await store.refreshForums()
        #expect(folder.cache.loadMoodleData(MoodleTermForums.self, name: "forums", account: "B11399001") != nil)

        folder.cache.clearUserScopedData()

        #expect(folder.cache.loadMoodleData(MoodleTermForums.self, name: "forums", account: "B11399001") == nil)
        #expect(Self.store(folder, site: Site()).sectionRows.isEmpty)
    }

    // MARK: - Status

    @Test("a course detail opened again reads OK on a copy still fresh, and unknown only where a fetch is due at once")
    func cachedCopyStatus() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Self.store(folder, site: site, now: { fetched })
        await first.refreshForums()
        await first.refreshAnnouncements()

        // Within the freshness, at its end, past it, and stamped ahead of a clock set back.
        for (age, fresh) in [(0.0, true), (60, true), (299, true), (300, false), (3_600, false), (-60, false)] {
            let now = fetched + age
            let reopened = Self.store(folder, site: Site(), now: { now })
            #expect(!reopened.sectionRows.isEmpty)
            #expect(reopened.announcementList != nil)

            let forumsWait = MoodleRefreshTimer.wait(
                fetchedAt: reopened.forumsFetchedAt, lastTry: nil, ttl: reopened.forums.ttl, now: now
            )
            let announcementsWait = MoodleRefreshTimer.wait(
                fetchedAt: reopened.announcementsFetchedAt, lastTry: nil, ttl: reopened.announcements.ttl, now: now
            )
            #expect((forumsWait > 0) == fresh, "age \(age)")
            #expect((announcementsWait > 0) == fresh, "age \(age)")
            #expect(reopened.sectionStatus == (fresh ? .ok : .unknown), "age \(age)")
            #expect(reopened.announcements.status == (fresh ? .ok : .unknown), "age \(age)")
        }
    }

    @Test("from a fresh copy's OK a refresh shows its progress, then its failure, then the next success")
    func refreshFromAFreshCopy() async throws {
        let folder = Folder()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await Self.store(folder, site: Site(), now: { fetched }).refreshForums()
        let answer = ManualSleeper()
        let offline = OSAllocatedUnfairLock(initialState: true)
        let store = Self.store(folder, site: Site(), beforeForums: {
            await answer.sleep(for: .zero)
            if offline.withLock({ $0 }) { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        }, now: { fetched + 60 })
        #expect(store.sectionStatus == .ok)

        let failing = Task { await store.refreshForums() }
        try await answer.waitUntilArmed()
        #expect(store.isSectionRefreshing)
        await answer.fire()
        await failing.value
        #expect(!store.isSectionRefreshing)
        #expect(store.sectionStatus == .failed)
        #expect(!store.sectionRows.isEmpty)

        offline.withLock { $0 = false }
        let retry = Task { await store.refreshForums() }
        try await answer.waitUntilArmed(atLeast: 2)
        await answer.fire()
        await retry.value
        #expect(store.sectionStatus == .ok)
    }

    // MARK: - Functions

    @Test("a site that does not allow the forum calls hides the announcements without asking for forums")
    func gatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [MoodleForumService.forumsFunction])
        let store = Self.store(folder, site: site)

        await store.refreshForums()

        #expect(site.forumCalls.isEmpty)
        #expect(store.sectionRows.isEmpty)
        #expect(store.forums.status == .ok)
    }

    @Test("the row hides with no news forum or no announcements")
    func rowNeedsAnnouncements() async {
        let folder = Folder()
        let site = Site()
        var empty = Self.newsForum
        empty.discussionCount = 0
        let general = MoodleForum(
            id: 502, courseId: Self.courseId, type: "general", name: "Q&A", cmid: 9002,
            discussionCount: 4, unreadPostCount: 0
        )
        for forums in [[empty], [general]] {
            site.set(forums: forums)
            let store = Self.store(folder, site: site)
            await store.refreshForums()
            #expect(store.sectionRows.isEmpty)
        }
    }

    // MARK: - Announcements

    @Test("announcements come an explicit page at a time, the next one only at the end of the list")
    func paging() async {
        let folder = Folder()
        let site = Site()
        let full = (1...MoodleForumService.discussionsPerPage).map { Self.discussion(800 + $0, created: TimeInterval($0)) }
        site.set(pages: [full, [Self.discussion(900)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()

        await store.refreshAnnouncements()
        #expect(site.discussionPages == [0])
        #expect(store.announcementList?.hasMore == true)

        await store.loadMoreAnnouncements(after: store.announcementList?.sorted.last?.id)
        #expect(site.discussionPages == [0, 1])
        #expect(store.announcementList?.discussions.count == MoodleForumService.discussionsPerPage + 1)
        #expect(store.announcementList?.hasMore == false)

        // A refresh fetches as many pages as the list shows, so it keeps its length.
        await store.refreshAnnouncements()
        #expect(site.discussionPages == [0, 1, 0, 1])
        #expect(store.announcementList?.discussions.count == MoodleForumService.discussionsPerPage + 1)
    }

    @Test("a refresh during a page load waits for it, so the page that loaded stays")
    func refreshWaitsForAPageLoad() async throws {
        let folder = Folder()
        let site = Site()
        let full = (1...MoodleForumService.discussionsPerPage).map { Self.discussion(800 + $0, created: TimeInterval($0)) }
        site.set(pages: [full, [Self.discussion(900)]])
        let nextPage = ManualSleeper()
        let refreshFirstPage = ManualSleeper()
        let store = Self.store(folder, site: site, beforePage: { page, earlier in
            if page == 1, earlier == 0 { await nextPage.sleep(for: .zero) }
            if page == 0, earlier == 1 { await refreshFirstPage.sleep(for: .zero) }
        })
        await store.refreshForums()
        await store.refreshAnnouncements()

        let paging = Task { await store.loadMoreAnnouncements(after: store.announcementList?.sorted.last?.id) }
        try await nextPage.waitUntilArmed()
        let refresh = Task { await store.refreshAnnouncements() }
        // A refresh not held back would start here, sized to the list before the next page.
        for _ in 0..<5 { await Task.yield() }
        await nextPage.fire()
        await paging.value
        try await refreshFirstPage.waitUntilArmed()
        await refreshFirstPage.fire()
        await refresh.value

        #expect(store.announcementList?.discussions.count == MoodleForumService.discussionsPerPage + 1)
        #expect(site.discussionPages == [0, 1, 0, 1])
    }

    @Test("a refresh asked for during another joins it rather than fetching the list again")
    func overlappingRefreshesFetchOnce() async throws {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        let firstPage = ManualSleeper()
        let store = Self.store(folder, site: site, beforePage: { page, earlier in
            if page == 0, earlier == 1 { await firstPage.sleep(for: .zero) }
        })
        await store.refreshForums()
        await store.refreshAnnouncements()

        let timed = Task { await store.refreshAnnouncements() }
        try await firstPage.waitUntilArmed()
        let pull = Task { await store.refreshAnnouncements() }
        for _ in 0..<5 { await Task.yield() }
        await firstPage.fire()
        await timed.value
        await pull.value

        #expect(site.discussionPages == [0, 0])
    }

    @Test("a page that fails to load stays offered for a retry, and loads on it")
    func failedPageOffersARetry() async {
        let folder = Folder()
        let site = Site()
        let full = (1...MoodleForumService.discussionsPerPage).map { Self.discussion(800 + $0, created: TimeInterval($0)) }
        site.set(pages: [full, [Self.discussion(900)]])
        let store = Self.store(folder, site: site, beforePage: { page, earlier in
            if page == 1, earlier == 0 { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        })
        await store.refreshForums()
        await store.refreshAnnouncements()
        let last = store.announcementList?.sorted.last?.id

        await store.loadMoreAnnouncements(after: last)
        #expect(store.announcementsPageFailure != nil)
        #expect(store.announcementList?.hasMore == true)

        // A page asked for by a row that is no longer the last one is not loaded.
        await store.loadMoreAnnouncements(after: 999)
        #expect(site.discussionPages == [0, 1])

        await store.loadMoreAnnouncements(after: last)
        #expect(store.announcementsPageFailure == nil)
        #expect(store.announcementList?.discussions.count == MoodleForumService.discussionsPerPage + 1)
    }

    @Test("pinned announcements come first, then the newest")
    func order() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(1, created: 10), Self.discussion(2, pinned: true, created: 0), Self.discussion(3, created: 20)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.refreshAnnouncements()

        #expect(store.announcementList?.sorted.map(\.id) == [2, 3, 1])
    }

    @Test("a refresh that empties the list takes the section row with it")
    func emptiedListHidesTheRow() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        #expect(!store.sectionRows.isEmpty)

        await store.refreshAnnouncements()

        #expect(store.announcementList?.discussions == [])
        #expect(store.sectionRows.isEmpty)
    }

    // MARK: - Opening

    @Test("opening an announcement tells Moodle once and reads it here; the list never tells Moodle")
    func openSendsTheViewOnce() async {
        let folder = Folder()
        let site = Site()
        let unread = Self.discussion(801, unread: 1)
        site.set(pages: [[unread, Self.discussion(802)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.refreshAnnouncements()
        await store.loadMoreAnnouncements(after: store.announcementList?.sorted.last?.id)
        #expect(site.viewed.isEmpty)
        #expect(store.sectionRows.first?.hasUnread == true)

        await store.open(unread).value

        #expect(site.viewed == [801])
        #expect(store.announcementList?.discussions.first { $0.id == 801 }?.unreadCount == 0)
        #expect(store.sectionRows.first?.hasUnread == false)
        #expect(Self.store(folder, site: Site()).sectionRows.first?.hasUnread == false)
    }

    @Test("a site that does not allow the view call is not told, and the announcement still reads as read here")
    func viewGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        let unread = Self.discussion(801, unread: 1)
        site.set(pages: [[unread]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.refreshAnnouncements()
        site.set(functions: MoodleCourseStore.announcementFunctions)

        await store.open(unread).value

        #expect(site.viewed.isEmpty)
        #expect(store.announcementList?.discussions.first?.unreadCount == 0)
    }

    // MARK: - Summary

    private nonisolated static let summary = MoodleCourseSummary(
        html: "<p>Layers and protocols, from <strong>HTTP</strong> to TCP.</p>",
        text: "Layers and protocols, from HTTP to TCP.",
        names: ["Computer Networks", "1141CS3105301 Networks"]
    )

    private static func summaryOnDisk(_ folder: Folder) -> MoodleCourseSummary? {
        folder.cache.loadMoodleData(MoodleCourseSummary.self, name: "courses/\(courseId)/summary", account: "B11399001")?.value
    }

    @Test("the summary takes one call for the course, and comes from that account's cache the next time")
    func summaryCacheFirst() async {
        let folder = Folder()
        let site = Site()
        let first = Self.store(folder, site: site)
        await first.refreshSummary()

        #expect(site.summaryCalls == [Self.courseId])
        #expect(first.shownSummary == Self.summary)
        let again = Self.store(folder, site: Site())
        #expect(again.shownSummary == Self.summary)
        #expect(again.summary.status == .ok)
        #expect(Self.store(folder, site: Site(), account: "B11399002").summary.value == nil)
    }

    @Test("a summary alone brings the section, which has no row for it")
    func summaryWithoutRows() async {
        let folder = Folder()
        let site = Site()
        site.set(forums: [])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.refreshSummary()

        #expect(store.sectionRows.isEmpty)
        #expect(store.shownSummary == Self.summary)
    }

    @Test("a site that does not allow the call shows no summary, without asking for one")
    func summaryGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: Self.allFunctions.subtracting([MoodleCourseSummaryService.coursesFunction]))
        let store = Self.store(folder, site: site)

        await store.refreshSummary()

        #expect(site.summaryCalls.isEmpty)
        #expect(store.shownSummary == nil)
        #expect(store.summary.status == .ok)
    }

    @Test("a summary that only repeats one of the course's codes shows nothing, nor does an empty one")
    func summaryRepeatingACode() async {
        let folder = Folder()
        let site = Site()
        site.set(summary: MoodleCourseSummary(html: "<p>1141CS3105301</p>", text: "1141CS3105301", names: []))
        await Self.store(folder, site: site).refreshSummary()

        #expect(Self.store(folder, site: Site()).shownSummary != nil)
        #expect(Self.store(folder, site: Site(), courseCodes: ["1141cs3105301", "CS3105301"]).shownSummary == nil)

        site.set(summary: .empty)
        let emptied = Self.store(folder, site: site)
        await emptied.refreshSummary()
        #expect(emptied.shownSummary == nil)
    }

    @Test("the course detail hides a summary that repeats any department's idnumber of a co-listed course, or its course number")
    func summaryOfACoListedCourse() async {
        let folder = Folder()
        let idMap = ["1141CS3105301": Self.courseId, "1141EE3105301": Self.courseId, "1141CS1000301": 20103]
        let codes = CourseDetailSheet.moodleCourseCodes(
            idnumber: "1141EE3105301", courseNo: "EE3105301", courseId: Self.courseId, idMap: idMap
        )
        #expect(!codes.contains("1141CS1000301"))

        for repeated in ["1141CS3105301", "CS3105301", "1141EE3105301", "EE3105301"] {
            let site = Site()
            site.set(summary: MoodleCourseSummary(html: "<p>\(repeated)</p>", text: repeated, names: []))
            let store = Self.store(folder, site: site, courseCodes: codes)
            await store.refreshSummary()
            #expect(store.shownSummary == nil, "\(repeated)")
        }
    }

    @Test("signing out deletes the cached summary, and one that lands after a sign-out is not kept")
    func summarySignOut() async throws {
        let folder = Folder()
        await Self.store(folder, site: Site()).refreshSummary()
        #expect(Self.summaryOnDisk(folder) == Self.summary)

        folder.cache.clearUserScopedData()
        #expect(Self.summaryOnDisk(folder) == nil)
        #expect(Self.store(folder, site: Site()).shownSummary == nil)

        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let store = Self.store(folder, site: Site(), signedIn: signedIn, beforeSummary: {
            await answer.sleep(for: .zero)
        })
        let refresh = Task { await store.refreshSummary() }
        try await answer.waitUntilArmed()
        signedIn.withLock { $0 = false }
        await answer.fire()
        await refresh.value

        #expect(store.summary.value == nil)
        #expect(Self.summaryOnDisk(folder) == nil)
    }

    @Test("a failed fetch keeps the summary shown and turns the section's dot red, after its progress")
    func summaryFailure() async throws {
        let folder = Folder()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await Self.store(folder, site: Site(), now: { fetched }).refreshSummary()
        let answer = ManualSleeper()
        let store = Self.store(folder, site: Site(), beforeSummary: {
            await answer.sleep(for: .zero)
            throw MoodleWebserviceError.transientNetwork(underlying: "offline")
        }, now: { fetched + 60 })
        #expect(store.sectionStatus == .ok)

        let refresh = Task { await store.refreshSummary() }
        try await answer.waitUntilArmed()
        #expect(store.isSectionRefreshing)
        await answer.fire()
        await refresh.value

        #expect(!store.isSectionRefreshing)
        #expect(store.sectionStatus == .failed)
        #expect(store.shownSummary == Self.summary)
    }

    @Test("a cached summary reads OK for five minutes, and is due once older")
    func summaryFreshness() async {
        let folder = Folder()
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await Self.store(folder, site: Site(), now: { fetched }).refreshSummary()

        for (age, fresh) in [(0.0, true), (299, true), (300, false), (3_600, false)] {
            let now = fetched + age
            let reopened = Self.store(folder, site: Site(), now: { now })
            let wait = MoodleRefreshTimer.wait(
                fetchedAt: reopened.summary.fetchedAt, lastTry: nil, ttl: reopened.summary.ttl, now: now
            )
            #expect((wait > 0) == fresh, "age \(age)")
            #expect(reopened.summary.status == (fresh ? .ok : .unknown), "age \(age)")
        }
    }
}
