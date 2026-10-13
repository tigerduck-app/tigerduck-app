import Foundation
import os
import SwiftUI
import Testing
@testable import TigerDuck
#if os(iOS)
import UIKit
#endif

/// `MoodleCourseStore` over a stand-in `MoodleCourseAPI` and a `DataCache` in a folder of its
/// own: the cache comes first, writes stop at a sign-out, the site's functions gate each call,
/// only opening an announcement tells Moodle it was read, and only graded items make a grades row.
@MainActor
struct MoodleCourseStoreTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let newsForum = MoodleForum(
        id: 501, courseId: courseId, type: "news", name: "Announcements", cmid: 9001,
        discussionCount: 2, unreadPostCount: 1
    )
    private nonisolated static let allFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
        MoodleForumService.viewDiscussionFunction, MoodleGradeService.gradeItemsFunction, MoodleCourseSummaryService.coursesFunction,
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
        private var _gradeItems: [MoodleGradeItem] = []
        private var _gradeCalls: [Int] = []
        private var _summary = MoodleCourseStoreTests.summary
        private var _summaryCalls: [Int] = []

        func set(
            functions: Set<String>? = nil,
            forums: [MoodleForum]? = nil,
            pages: [[MoodleDiscussion]]? = nil,
            gradeItems: [MoodleGradeItem]? = nil,
            summary: MoodleCourseSummary? = nil
        ) {
            lock.withLock {
                if let functions { _functions = functions }
                if let forums { _forums = forums }
                if let pages { _pages = pages }
                if let gradeItems { _gradeItems = gradeItems }
                if let summary { _summary = summary }
            }
        }

        var forumCalls: [[Int]] { lock.withLock { _forumCalls } }
        var discussionPages: [Int] { lock.withLock { _discussionCalls.map(\.page) } }
        var viewed: [Int] { lock.withLock { _viewed } }
        var gradeCalls: [Int] { lock.withLock { _gradeCalls } }
        var summaryCalls: [Int] { lock.withLock { _summaryCalls } }

        /// `beforePage` runs before each page answers, with the page and how many times it was
        /// asked for before; the other hooks can suspend or fail their requests.
        func api(
            beforeForums: @escaping @Sendable () async throws -> Void = {},
            beforePage: @escaping @Sendable (_ page: Int, _ earlier: Int) async throws -> Void = { _, _ in },
            beforeGrades: @escaping @Sendable () async throws -> Void = {},
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
                markViewed: { id, _ in self.lock.withLock { self._viewed.append(id) } },
                gradeItems: { courseId in
                    self.lock.withLock { self._gradeCalls.append(courseId) }
                    try await beforeGrades()
                    return self.lock.withLock { self._gradeItems }
                },
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
        now: @escaping () -> Date = { Date() },
        beforeGrades: @escaping @Sendable () async throws -> Void = {}
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [20103, courseId],
            courseCodes: courseCodes,
            context: MoodleCacheContext(
                account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }, now: now
            ),
            api: site.api(
                beforeForums: beforeForums, beforePage: beforePage, beforeGrades: beforeGrades, beforeSummary: beforeSummary
            )
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
        await first.announcementPages?.refresh()

        let again = Self.store(folder, site: Site())
        #expect(again.sectionRows == [MoodleSectionRow(kind: .announcements, count: 2, hasUnread: true)])
        #expect(again.announcementPages?.list?.discussions.map(\.id) == [801, 802])
        #expect(again.forumsFetchedAt != nil)
        #expect(again.announcementPages?.fetchedAt != nil)
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
        let store = Self.store(folder, site: Site(), signedIn: signedIn, beforeForums: {
            await answer.sleep(for: .zero)
        })

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
    func cachedCopyStatus() async throws {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Self.store(folder, site: site, now: { fetched })
        await first.refreshForums()
        await first.announcementPages?.refresh()

        // Within the freshness, at its end, past it, and stamped ahead of a clock set back.
        for (age, fresh) in [(0.0, true), (60, true), (299, true), (300, false), (3_600, false), (-60, false)] {
            let now = fetched + age
            let reopened = Self.store(folder, site: Site(), now: { now })
            let announcements = try #require(reopened.announcementPages)
            #expect(!reopened.sectionRows.isEmpty)
            #expect(announcements.list != nil)

            let forumsWait = MoodleRefreshTimer.wait(
                fetchedAt: reopened.forumsFetchedAt, lastTry: nil, ttl: reopened.forums.ttl, now: now
            )
            let announcementsWait = MoodleRefreshTimer.wait(
                fetchedAt: announcements.fetchedAt, lastTry: nil, ttl: announcements.feed.ttl, now: now
            )
            #expect((forumsWait > 0) == fresh, "age \(age)")
            #expect((announcementsWait > 0) == fresh, "age \(age)")
            #expect(reopened.sectionStatus == (fresh ? .ok : .unknown), "age \(age)")
            #expect(announcements.feed.status == (fresh ? .ok : .unknown), "age \(age)")
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

    @Test("the announcements row hides with no news forum or no announcements")
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
            #expect(!store.sectionRows.contains { $0.kind == .announcements })
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

        await store.announcementPages?.refresh()
        #expect(site.discussionPages == [0])
        #expect(store.announcementPages?.list?.hasMore == true)

        await store.announcementPages?.loadMore(after: store.announcementPages?.list?.sorted.last?.id)
        #expect(site.discussionPages == [0, 1])
        #expect(store.announcementPages?.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
        #expect(store.announcementPages?.list?.hasMore == false)

        // A refresh fetches as many pages as the list shows, so it keeps its length.
        await store.announcementPages?.refresh()
        #expect(site.discussionPages == [0, 1, 0, 1])
        #expect(store.announcementPages?.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
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
        await store.announcementPages?.refresh()

        let paging = Task { await store.announcementPages?.loadMore(after: store.announcementPages?.list?.sorted.last?.id) }
        try await nextPage.waitUntilArmed()
        let refresh = Task { await store.announcementPages?.refresh() }
        // A refresh not held back would start here, sized to the list before the next page.
        for _ in 0..<5 { await Task.yield() }
        await nextPage.fire()
        await paging.value
        try await refreshFirstPage.waitUntilArmed()
        await refreshFirstPage.fire()
        await refresh.value

        #expect(store.announcementPages?.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
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
        await store.announcementPages?.refresh()

        let timed = Task { await store.announcementPages?.refresh() }
        try await firstPage.waitUntilArmed()
        let pull = Task { await store.announcementPages?.refresh() }
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
        await store.announcementPages?.refresh()
        let last = store.announcementPages?.list?.sorted.last?.id

        await store.announcementPages?.loadMore(after: last)
        #expect(store.announcementPages?.pageFailure != nil)
        #expect(store.announcementPages?.list?.hasMore == true)

        // A page asked for by a row that is no longer the last one is not loaded.
        await store.announcementPages?.loadMore(after: 999)
        #expect(site.discussionPages == [0, 1])

        await store.announcementPages?.loadMore(after: last)
        #expect(store.announcementPages?.pageFailure == nil)
        #expect(store.announcementPages?.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
    }

    @Test("pinned announcements come first, then the newest")
    func order() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(1, created: 10), Self.discussion(2, pinned: true, created: 0), Self.discussion(3, created: 20)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.announcementPages?.refresh()

        #expect(store.announcementPages?.list?.sorted.map(\.id) == [2, 3, 1])
    }

    @Test("a refresh that empties the list takes the section row with it")
    func emptiedListHidesTheRow() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        #expect(!store.sectionRows.isEmpty)

        await store.announcementPages?.refresh()

        #expect(store.announcementPages?.list?.discussions == [])
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
        await store.announcementPages?.refresh()
        await store.announcementPages?.loadMore(after: store.announcementPages?.list?.sorted.last?.id)
        #expect(site.viewed.isEmpty)
        #expect(store.sectionRows.first?.hasUnread == true)

        await store.open(unread).value

        #expect(site.viewed == [801])
        #expect(store.announcementPages?.list?.discussions.first { $0.id == 801 }?.unreadCount == 0)
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
        await store.announcementPages?.refresh()
        site.set(functions: MoodleCourseStore.forumFunctions)

        await store.open(unread).value

        #expect(site.viewed.isEmpty)
        #expect(store.announcementPages?.list?.discussions.first?.unreadCount == 0)
    }

    // MARK: - Grades

    private nonisolated static func gradeItem(
        _ id: Int, type: String = "mod", module: String? = "assign", grade: String? = "90.00", hidden: Bool = false
    ) -> MoodleGradeItem {
        MoodleGradeItem(
            id: id, name: "Item \(id)", type: type, module: module, cmid: type == "mod" ? id + 5000 : nil,
            grade: grade, maxGrade: 100, isHidden: hidden, feedback: ""
        )
    }

    /// One line of each kind: two graded items, which the row counts, then an ungraded item, a
    /// hidden grade, a category's subtotal and the course total, which it does not.
    private nonisolated static let gradebook = [
        gradeItem(3001),
        gradeItem(3002, module: "quiz", grade: nil),
        gradeItem(3003, type: "manual", module: nil, grade: "7.50"),
        gradeItem(3004, grade: "88.00", hidden: true),
        gradeItem(3005, type: "category", module: nil, grade: "89.00"),
        gradeItem(3000, type: "course", module: nil, grade: "87.50"),
    ]

    @Test("the grades row counts the graded items shown, after the announcements, never the total or a subtotal")
    func gradesRowCount() async {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.refreshGrades()

        #expect(site.gradeCalls == [Self.courseId])
        #expect(store.sectionRows == [
            MoodleSectionRow(kind: .announcements, count: 2, hasUnread: true),
            MoodleSectionRow(kind: .grades, count: 2, hasUnread: false),
        ])
        #expect(store.grades.value?.graded.map(\.id) == [3001, 3003])
        #expect(store.grades.value?.total?.id == 3000)
    }

    @Test("the grades row hides while no item but the total or a subtotal has a grade to show")
    func gradesRowNeedsAGradedItem() async {
        let folder = Folder()
        let site = Site()
        let ungraded = [
            Self.gradeItem(3001, grade: nil),
            Self.gradeItem(3004, hidden: true),
            Self.gradeItem(3005, type: "category", module: nil),
            Self.gradeItem(3000, type: "course", module: nil),
        ]
        for items in [ungraded, []] {
            site.set(gradeItems: items)
            let store = Self.store(folder, site: site)
            await store.refreshGrades()
            #expect(store.grades.value?.graded.isEmpty == true)
            #expect(!store.sectionRows.contains { $0.kind == .grades })
        }
    }

    @Test("the total shows only with a grade the student may see")
    func totalNeedsAShownGrade() {
        func total(_ item: MoodleGradeItem) -> MoodleGradeItem? {
            MoodleCourseGrades(items: [Self.gradeItem(3001), item]).total
        }
        #expect(total(Self.gradeItem(3000, type: "course", module: nil))?.id == 3000)
        #expect(total(Self.gradeItem(3000, type: "course", module: nil, hidden: true)) == nil)
        #expect(total(Self.gradeItem(3000, type: "course", module: nil, grade: nil)) == nil)
    }

    @Test("a site that does not allow the grade call hides the row without asking for grades")
    func gradesGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: MoodleCourseStore.forumFunctions, gradeItems: Self.gradebook)
        let store = Self.store(folder, site: site)

        await store.refreshGrades()

        #expect(site.gradeCalls.isEmpty)
        #expect(store.sectionRows.isEmpty)
        #expect(store.grades.status == .ok)
    }

    @Test("grades come from the cache first, each account keeps its own, and signing out deletes them")
    func gradesCache() async {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        await Self.store(folder, site: site).refreshGrades()

        let again = Self.store(folder, site: Site())
        #expect(again.sectionRows == [MoodleSectionRow(kind: .grades, count: 2, hasUnread: false)])
        #expect(again.grades.fetchedAt != nil)
        #expect(again.grades.status == .ok)
        #expect(Self.store(folder, site: Site(), account: "B11399002").grades.value == nil)

        folder.cache.clearUserScopedData()

        #expect(Self.store(folder, site: Site()).grades.value == nil)
    }

    @Test("grades that land after a sign-out are neither shown nor kept")
    func gradesAfterSignOut() async throws {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let store = Self.store(folder, site: site, signedIn: signedIn, beforeGrades: {
            await answer.sleep(for: .zero)
        })

        let refresh = Task { await store.refreshGrades() }
        try await answer.waitUntilArmed()
        signedIn.withLock { $0 = false }
        await answer.fire()
        await refresh.value

        #expect(store.grades.value == nil)
        #expect(folder.cache.loadMoodleData(
            MoodleCourseGrades.self, name: "courses/\(Self.courseId)/grades", account: "B11399001"
        ) == nil)
    }

    @Test("with nothing cached the screen waits, a failed first fetch offers a retry, and a failed refresh keeps the copy")
    func gradesScreenStates() async {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let offline = OSAllocatedUnfairLock(initialState: true)
        let store = Self.store(folder, site: site, beforeGrades: {
            if offline.withLock({ $0 }) { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        })
        #expect(store.grades.value == nil)
        #expect(store.grades.failure == nil)

        await store.refreshGrades()
        #expect(store.grades.value == nil)
        #expect(store.grades.status == .failed)
        #expect(store.grades.failure.map(MoodleFirstLoadView.isNetworkError) == true)

        offline.withLock { $0 = false }
        await store.refreshGrades()
        #expect(store.grades.value?.graded.count == 2)
        #expect(store.grades.failure == nil)

        offline.withLock { $0 = true }
        await store.refreshGrades()
        #expect(store.grades.value?.graded.count == 2)
        #expect(store.grades.status == .failed)
    }

    @Test("a refresh that leaves no graded item empties the screen and takes the row with it")
    func gradesEmptied() async {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let store = Self.store(folder, site: site)
        await store.refreshGrades()
        #expect(store.sectionRows.contains { $0.kind == .grades })

        site.set(gradeItems: [])
        await store.refreshGrades()

        #expect(store.grades.value?.graded == [])
        #expect(store.grades.value?.total == nil)
        #expect(store.sectionRows.isEmpty)
    }

    @Test("the section's dot spins while the grades load and shows the worst of its feeds")
    func sectionStatusCoversGrades() async throws {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let answer = ManualSleeper()
        let store = Self.store(folder, site: site, beforeGrades: {
            await answer.sleep(for: .zero)
            if failing.withLock({ $0 }) { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        })
        await store.refreshForums()
        // Grades not fetched yet count for nothing beside the forums' answer.
        #expect(store.sectionStatus == .ok)

        let refresh = Task { await store.refreshGrades() }
        try await answer.waitUntilArmed()
        #expect(store.isSectionRefreshing)
        await answer.fire()
        await refresh.value
        #expect(!store.isSectionRefreshing)
        #expect(store.sectionStatus == .failed)

        failing.withLock { $0 = false }
        let retry = Task { await store.refreshGrades() }
        try await answer.waitUntilArmed(atLeast: 2)
        await answer.fire()
        await retry.value
        #expect(store.sectionStatus == .ok)
    }

    @Test("a grades refresh asked for during another joins it, as the section's and the screen's timers can")
    func gradesRefreshJoins() async throws {
        let folder = Folder()
        let site = Site()
        let answer = ManualSleeper()
        let store = Self.store(folder, site: site, beforeGrades: { await answer.sleep(for: .zero) })

        let section = Task { await store.refreshGrades() }
        try await answer.waitUntilArmed()
        let screen = Task { await store.refreshGrades() }
        for _ in 0..<5 { await Task.yield() }
        await answer.fire()
        await section.value
        await screen.value

        #expect(site.gradeCalls == [Self.courseId])
    }

    @Test("grades a minute old wait out the rest of their freshness, then refresh on the grades interval")
    func gradesRefreshTiming() async throws {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        await Self.store(folder, site: site, now: now).refreshGrades()
        clock.withLock { $0 += 60 }

        let store = Self.store(folder, site: site, now: now)
        #expect(store.grades.ttl == MoodleRefreshInterval.grades)
        let sleeper = ManualSleeper()
        let timer = MoodleRefreshTimer(ttl: store.grades.ttl, now: now, sleep: { await sleeper.sleep(for: $0) })
        timer.start(fetchedAt: { store.grades.fetchedAt }) { await store.refreshGrades() }

        try await sleeper.waitUntilArmed()
        #expect(await sleeper.requestedDurations == [.seconds(240)])
        #expect(site.gradeCalls.count == 1)

        clock.withLock { $0 += 240 }
        await sleeper.fire()
        try await sleeper.waitUntilArmed(atLeast: 2)
        #expect(site.gradeCalls.count == 2)
        #expect(await sleeper.requestedDurations == [.seconds(240), .seconds(300)])
        timer.stop()
    }

    #if os(iOS)
    @Test("the course detail's section fetches the grades as it shows, so a course with grades gets its row unopened")
    func sectionFetchesGrades() async throws {
        let folder = Folder()
        let site = Site()
        site.set(gradeItems: Self.gradebook)
        let store = Self.store(folder, site: site)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = UIHostingController(
            rootView: Color.clear.moodleSectionRefresh(store).environment(\.scenePhase, .active)
        )
        window.isHidden = false
        defer { window.isHidden = true }

        try await waitUntil { site.gradeCalls == [Self.courseId] }
        try await waitUntil { store.sectionRows.contains { $0.kind == .grades } }
    }
    #endif

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
