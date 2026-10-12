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
        MoodleForumService.viewDiscussionFunction,
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

        func set(functions: Set<String>? = nil, forums: [MoodleForum]? = nil, pages: [[MoodleDiscussion]]? = nil) {
            lock.withLock {
                if let functions { _functions = functions }
                if let forums { _forums = forums }
                if let pages { _pages = pages }
            }
        }

        var forumCalls: [[Int]] { lock.withLock { _forumCalls } }
        var discussionPages: [Int] { lock.withLock { _discussionCalls.map(\.page) } }
        var viewed: [Int] { lock.withLock { _viewed } }

        func api(beforeForums: @escaping @Sendable () async -> Void = {}) -> MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { courseIds in
                    self.lock.withLock { self._forumCalls.append(courseIds) }
                    await beforeForums()
                    return self.lock.withLock { self._forums }
                },
                discussions: { forumId, page in
                    self.lock.withLock {
                        self._discussionCalls.append((forumId, page))
                        return page < self._pages.count ? self._pages[page] : []
                    }
                },
                markViewed: { id in self.lock.withLock { self._viewed.append(id) } }
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
        beforeForums: @escaping @Sendable () async -> Void = {}
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [20103, courseId],
            context: MoodleCacheContext(account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }),
            api: site.api(beforeForums: beforeForums)
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
        #expect(again.forums.status == .unknown)
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

        await store.loadMoreAnnouncements()
        #expect(site.discussionPages == [0, 1])
        #expect(store.announcementList?.discussions.count == MoodleForumService.discussionsPerPage + 1)
        #expect(store.announcementList?.hasMore == false)

        // A refresh fetches as many pages as the list shows, so it keeps its length.
        await store.refreshAnnouncements()
        #expect(site.discussionPages == [0, 1, 0, 1])
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
        await store.loadMoreAnnouncements()
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
}
