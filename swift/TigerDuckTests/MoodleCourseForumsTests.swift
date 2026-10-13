import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct MoodleCourseForumsTests {
    private nonisolated static let courseId = 20119
    private nonisolated static let news = forum(501, type: "news", discussions: 2, unread: 1)
    private nonisolated static let qanda = forum(502, discussions: 3, unread: 2)
    private nonisolated static let project = forum(503, discussions: 4)
    private nonisolated static let allFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
        MoodleForumService.discussionPostsFunction, MoodleForumService.viewDiscussionFunction,
    ]

    private nonisolated static func forum(
        _ id: Int, type: String = "general", course: Int = courseId, discussions: Int, unread: Int = 0
    ) -> MoodleForum {
        MoodleForum(
            id: id, courseId: course, type: type, name: "Forum \(id)", cmid: id + 8000,
            discussionCount: discussions, unreadPostCount: unread, intro: "About forum \(id)"
        )
    }

    /// `created` and `modified` count from the same instant, so a list sorted by one and a list
    /// sorted by the other can tell apart.
    private nonisolated static func discussion(
        _ id: Int, unread: Int = 0, pinned: Bool = false, created: TimeInterval = 0, modified: TimeInterval = 0,
        replies: Int = 0
    ) -> MoodleDiscussion {
        MoodleDiscussion(
            id: id, postId: id + 1000, title: "Discussion \(id)", message: "<p>Question \(id)</p>",
            preview: "Question \(id)", created: Date(timeIntervalSince1970: 1_790_000_000 + created),
            modified: Date(timeIntervalSince1970: 1_790_000_000 + modified), isPinned: pinned,
            unreadCount: unread, replyCount: replies, authorName: "B11399001 @ Tiger Duck", attachments: []
        )
    }

    private nonisolated static func post(_ id: Int, parent: Int? = nil, unread: Bool = false, author: String? = nil) -> MoodlePost {
        MoodlePost(
            id: id, parentId: parent, subject: parent == nil ? "Discussion" : "Re: Discussion",
            message: "<p>Post \(id)</p>", created: Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(id)),
            authorName: author ?? "B1139900\(id % 10) @ Duck \(id)", attachments: [], isUnread: unread, isDeleted: false
        )
    }

    /// The calls the store made, and what the stand-in site answers.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var _functions: Set<String> = MoodleCourseForumsTests.allFunctions
        private var _forums: [MoodleForum] = [
            MoodleCourseForumsTests.news, MoodleCourseForumsTests.qanda, MoodleCourseForumsTests.project,
        ]
        private var _pages: [Int: [[MoodleDiscussion]]] = [:]
        private var _posts: [Int: [MoodlePost]] = [:]
        private var _failing: Set<String> = []
        private var _calls: [String] = []

        func set(
            functions: Set<String>? = nil,
            forums: [MoodleForum]? = nil,
            pages: [[MoodleDiscussion]]? = nil,
            of forumId: Int = MoodleCourseForumsTests.qanda.id,
            posts: [MoodlePost]? = nil,
            in discussionId: Int = 801
        ) {
            lock.withLock {
                if let functions { _functions = functions }
                if let forums { _forums = forums }
                if let pages { _pages[forumId] = pages }
                if let posts { _posts[discussionId] = posts }
            }
        }

        /// Fails every later call of `kind` ("discussions" or "posts") until called with false.
        func fail(_ kind: String, _ failing: Bool = true) {
            lock.withLock {
                if failing { _failing.insert(kind) } else { _failing.remove(kind) }
            }
        }

        /// Each call as "forums", "discussions <forum> <page>", "posts <discussion>" or "viewed <discussion>".
        var calls: [String] { lock.withLock { _calls } }

        private func record(_ call: String, kind: String) throws {
            let failing = lock.withLock {
                _calls.append(call)
                return _failing.contains(kind)
            }
            if failing { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }
        }

        var api: MoodleCourseAPI {
            MoodleCourseAPI(
                functions: { self.lock.withLock { self._functions } },
                forums: { _ in
                    try self.record("forums", kind: "forums")
                    return self.lock.withLock { self._forums }
                },
                discussions: { forumId, page in
                    try self.record("discussions \(forumId) \(page)", kind: "discussions")
                    return self.lock.withLock {
                        let pages = self._pages[forumId] ?? []
                        return page < pages.count ? pages[page] : []
                    }
                },
                posts: { discussionId in
                    try self.record("posts \(discussionId)", kind: "posts")
                    return self.lock.withLock { self._posts[discussionId] ?? [] }
                },
                markViewed: { discussionId in try self.record("viewed \(discussionId)", kind: "viewed") }
            )
        }
    }

    /// A cache in a folder of its own, removed when the test ends.
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseForumsTests-\(UUID().uuidString)", isDirectory: true)
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
        now: @escaping () -> Date = { Date() }
    ) -> MoodleCourseStore {
        MoodleCourseStore(
            courseId: courseId,
            termCourseIds: [20103, courseId],
            context: MoodleCacheContext(
                account: account, cache: folder.cache, isCurrent: { signedIn.withLock { $0 } }, now: now
            ),
            api: site.api
        )
    }

    private static func row(_ store: MoodleCourseStore) -> MoodleSectionRow? {
        store.sectionRows.first { $0.kind == .forums }
    }

    // MARK: - Section row

    @Test("the forums row counts every discussion of the forums besides the announcements, after them")
    func rowCountsTheGeneralForums() async {
        let folder = Folder()
        let site = Site()
        site.set(forums: [Self.news, Self.qanda, Self.project, Self.forum(504, course: 20103, discussions: 9)])
        let store = Self.store(folder, site: site)
        await store.refreshForums()

        #expect(store.sectionRows.map(\.kind) == [.announcements, .forums])
        #expect(Self.row(store) == MoodleSectionRow(kind: .forums, count: 7, hasUnread: true))
        #expect(store.generalForums.map(\.id) == [502, 503])
    }

    @Test("the forums row shows its dot only while a forum besides the announcements has an unread post")
    func rowUnreadDot() async {
        let folder = Folder()
        let site = Site()
        site.set(forums: [Self.forum(501, type: "news", discussions: 2, unread: 5), Self.project])
        let store = Self.store(folder, site: site)
        await store.refreshForums()

        #expect(Self.row(store)?.hasUnread == false)
    }

    @Test("the forums row hides with no forum besides the announcements, or none with a discussion")
    func rowNeedsADiscussion() async {
        let folder = Folder()
        let site = Site()
        let empty = Self.forum(502, discussions: 0)
        let otherCourse = Self.forum(504, course: 20103, discussions: 9)
        for forums in [[Self.news], [Self.news, empty], [otherCourse], []] {
            site.set(forums: forums)
            let store = Self.store(folder, site: site)
            await store.refreshForums()
            #expect(Self.row(store) == nil, "forums \(forums.map(\.id))")
            #expect(store.generalForums.isEmpty)
        }
    }

    @Test("a site that does not allow the posts call keeps the announcements row and hides the forums")
    func rowNeedsThePostsCall() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: Self.allFunctions.subtracting([MoodleForumService.discussionPostsFunction]))
        let store = Self.store(folder, site: site)

        await store.refreshForums()

        #expect(store.sectionRows.map(\.kind) == [.announcements])
        #expect(store.generalForums.isEmpty)
    }

    @Test("a site that does not allow the discussions call hides the forums without asking for them")
    func rowGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: [MoodleForumService.forumsFunction, MoodleForumService.discussionPostsFunction])
        let store = Self.store(folder, site: site)

        await store.refreshForums()

        #expect(site.calls.isEmpty)
        #expect(store.sectionRows.isEmpty)
    }

    @Test("with one forum besides the announcements the row opens its discussions, with more the forum list")
    func rowRoute() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        #expect(MoodleCourseSection.route(for: .forums, in: store) == .forums)

        site.set(forums: [Self.news, Self.qanda, Self.forum(503, discussions: 0)])
        await store.refreshForums()
        #expect(MoodleCourseSection.route(for: .forums, in: store) == .forum(Self.qanda))
        #expect(MoodleCourseSection.route(for: .announcements, in: store) == .announcements)
    }

    @Test("every forum screen fetches its own data, so ⌘R refreshes it on the Mac")
    func routesRefreshOnTheirOwn() {
        let discussion = Self.discussion(801)
        #expect(MoodleCourseRoute.forums.refreshesOnItsOwn)
        #expect(MoodleCourseRoute.forum(Self.qanda).refreshesOnItsOwn)
        #expect(MoodleCourseRoute.discussion(discussion, in: Self.qanda).refreshesOnItsOwn)
    }

    // MARK: - Discussions

    @Test("a forum's discussions come an explicit page at a time, the latest post first after the pinned")
    func discussionsPaging() async throws {
        let folder = Folder()
        let site = Site()
        // Created order and latest-post order disagree, so only the latest-post order passes.
        let full = (1...MoodleForumService.discussionsPerPage).map {
            Self.discussion(800 + $0, created: TimeInterval($0), modified: TimeInterval(100 - $0))
        }
        site.set(pages: [full, [Self.discussion(900, created: 500, modified: 0)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)

        await pages.refresh()
        #expect(site.calls.suffix(1) == ["discussions 502 0"])
        let list = try #require(pages.list)
        #expect(list.hasMore)
        #expect(list.sorted(by: pages.date).first?.id == 801)
        #expect(list.sorted(by: pages.date).last?.id == 820)

        await pages.loadMore(after: list.sorted(by: pages.date).last?.id)
        #expect(site.calls.suffix(1) == ["discussions 502 1"])
        #expect(pages.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
        #expect(pages.list?.hasMore == false)

        await pages.refresh()
        #expect(site.calls.suffix(2) == ["discussions 502 0", "discussions 502 1"])
        #expect(pages.list?.discussions.count == MoodleForumService.discussionsPerPage + 1)
    }

    @Test("pinned discussions come first, then the one with the latest post")
    func discussionsOrder() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[
            Self.discussion(1, created: 30, modified: 40),
            Self.discussion(2, pinned: true, created: 0, modified: 0),
            Self.discussion(3, created: 10, modified: 90),
        ]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)
        await pages.refresh()

        #expect(pages.list?.sorted(by: pages.date).map(\.id) == [2, 3, 1])
        #expect(pages.date == \MoodleDiscussion.modified)
        #expect(store.announcementPages?.date == \MoodleDiscussion.created)
    }

    @Test("a complete list corrects the forum's counts, and one that emptied takes the row with it")
    func discussionsCorrectTheCounts() async {
        let folder = Folder()
        let site = Site()
        site.set(forums: [Self.news, Self.qanda])
        site.set(pages: [[Self.discussion(801, unread: 1), Self.discussion(802)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)

        await pages.refresh()
        #expect(Self.row(store) == MoodleSectionRow(kind: .forums, count: 2, hasUnread: true))

        site.set(pages: [[]])
        await pages.refresh()
        #expect(pages.list?.discussions == [])
        #expect(Self.row(store) == nil)
    }

    @Test("a site that does not allow the discussions call is not asked, and the forum's list comes back empty")
    func discussionsGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        site.set(functions: [MoodleForumService.forumsFunction])

        await store.discussions(of: Self.qanda).refresh()

        #expect(!site.calls.contains { $0.hasPrefix("discussions") })
        #expect(store.discussions(of: Self.qanda).list?.discussions == [])
    }

    @Test("a cached partial list stops paging without an error when the site removes the discussions call")
    func nextPageGatedByFunctions() async throws {
        let folder = Folder()
        let site = Site()
        let full = (1...MoodleForumService.discussionsPerPage).map { Self.discussion(800 + $0) }
        site.set(pages: [full, [Self.discussion(900)]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)
        await pages.refresh()
        let last = try #require(pages.list?.sorted(by: pages.date).last?.id)
        site.fail("discussions")
        await pages.loadMore(after: last)
        #expect(pages.pageFailure != nil)
        let calls = site.calls
        site.set(functions: Self.allFunctions.subtracting([MoodleForumService.discussionsFunction]))

        await pages.loadMore(after: last)

        #expect(site.calls == calls)
        #expect(pages.pageFailure == nil)
        #expect(!pages.isLoadingMore)
        #expect(pages.list?.discussions == full)
        #expect(pages.list?.pageCount == 1)
        #expect(pages.list?.hasMore == false)
    }

    @Test("a forum's first list that fails leaves no list and the error for the screen's retry")
    func discussionsFirstLoadFails() async {
        let folder = Folder()
        let site = Site()
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        site.fail("discussions")
        let pages = store.discussions(of: Self.qanda)

        await pages.refresh()

        #expect(pages.list == nil)
        #expect(pages.feed.failure != nil)
        #expect(pages.feed.status == .failed)
        #expect(Self.row(store)?.count == 7)
    }

    // MARK: - Cache

    @Test("each forum's discussions and each discussion's posts are cached apart, per account, under the course")
    func cachePerForumAndDiscussion() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        site.set(pages: [[Self.discussion(811)]], of: Self.project.id)
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801)])
        let first = Self.store(folder, site: site)
        await first.refreshForums()
        await first.discussions(of: Self.qanda).refresh()
        await first.discussions(of: Self.project).refresh()
        await first.refreshThread(of: Self.discussion(801))

        let again = Self.store(folder, site: Site())
        #expect(again.discussions(of: Self.qanda).list?.discussions.map(\.id) == [801])
        #expect(again.discussions(of: Self.project).list?.discussions.map(\.id) == [811])
        #expect(again.thread(of: Self.discussion(801)).value?.posts.map(\.id) == [1801, 1802])
        #expect(folder.cache.loadMoodleData(
            MoodleDiscussionList.self, name: "courses/\(Self.courseId)/forums/502", account: "B11399001"
        ) != nil)
        #expect(folder.cache.loadMoodleData(
            MoodleDiscussionThread.self, name: "courses/\(Self.courseId)/discussions/801", account: "B11399001"
        ) != nil)

        let otherAccount = Self.store(folder, site: Site(), account: "B11399002")
        #expect(otherAccount.discussions(of: Self.qanda).list == nil)
        #expect(otherAccount.thread(of: Self.discussion(801)).value == nil)
    }

    @Test("signing out deletes the forums' discussions and posts, and an answer after it is not kept")
    func signOut() async throws {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        site.set(posts: [Self.post(1801)])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        await store.discussions(of: Self.qanda).refresh()
        await store.refreshThread(of: Self.discussion(801))

        folder.cache.clearUserScopedData()
        let afterSignOut = Self.store(folder, site: Site())
        #expect(afterSignOut.discussions(of: Self.qanda).list == nil)
        #expect(afterSignOut.thread(of: Self.discussion(801)).value == nil)

        let signedIn = OSAllocatedUnfairLock(initialState: true)
        let late = Self.store(folder, site: site, signedIn: signedIn)
        signedIn.withLock { $0 = false }
        await late.refreshThread(of: Self.discussion(801))
        #expect(late.thread(of: Self.discussion(801)).value == nil)
        #expect(folder.cache.loadMoodleData(
            MoodleDiscussionThread.self, name: "courses/\(Self.courseId)/discussions/801", account: "B11399001"
        ) == nil)
    }

    @Test("forum lists and posts keep the forums' freshness, and a copy still fresh reads OK")
    func freshness() async {
        let folder = Folder()
        let site = Site()
        site.set(pages: [[Self.discussion(801)]])
        site.set(posts: [Self.post(1801)])
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Self.store(folder, site: site, now: { fetched })
        await first.refreshForums()
        await first.discussions(of: Self.qanda).refresh()
        await first.refreshThread(of: Self.discussion(801))

        for (age, fresh) in [(60.0, true), (299, true), (300, false)] {
            let reopened = Self.store(folder, site: Site(), now: { fetched + age })
            let pages = reopened.discussions(of: Self.qanda)
            let thread = reopened.thread(of: Self.discussion(801))
            #expect(pages.feed.ttl == MoodleRefreshInterval.forums)
            #expect(thread.ttl == MoodleRefreshInterval.forums)
            #expect(pages.feed.status == (fresh ? .ok : .unknown), "age \(age)")
            #expect(thread.status == (fresh ? .ok : .unknown), "age \(age)")
        }
    }

    // MARK: - Posts

    @Test("a site that does not allow the posts call is not asked, and the discussion shows its first post")
    func postsGatedByFunctions() async {
        let folder = Folder()
        let site = Site()
        site.set(functions: Self.allFunctions.subtracting([MoodleForumService.discussionPostsFunction]))
        site.set(posts: [Self.post(1801)])
        let store = Self.store(folder, site: site)
        let discussion = Self.discussion(801, replies: 3)

        await store.refreshThread(of: discussion)

        #expect(!site.calls.contains { $0.hasPrefix("posts") })
        let thread = store.thread(of: discussion).value
        #expect(thread?.posts == [])
        #expect(MoodleDiscussionThread.entries(of: discussion, in: thread).map(\.post.id) == [discussion.postId])
    }

    @Test("posts that fail to load the first time leave the first post, and the error for a retry")
    func postsFirstLoadFails() async {
        let folder = Folder()
        let site = Site()
        site.fail("posts")
        let store = Self.store(folder, site: site)
        let discussion = Self.discussion(801, replies: 3)

        await store.refreshThread(of: discussion)

        let thread = store.thread(of: discussion)
        #expect(thread.value == nil)
        #expect(thread.failure != nil)
        #expect(MoodleDiscussionThread.entries(of: discussion, in: thread.value).map(\.post) == [
            MoodlePost(firstPostOf: discussion),
        ])
    }

    // MARK: - Opening

    @Test("opening a discussion fetches its posts first, then reads it here and tells Moodle once")
    func openThread() async throws {
        let folder = Folder()
        let site = Site()
        let unread = Self.discussion(801, unread: 2, replies: 2)
        site.set(pages: [[unread, Self.discussion(802)]])
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801, unread: true), Self.post(1803, parent: 1801, unread: true)])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)
        await pages.refresh()
        #expect(!site.calls.contains { $0.hasPrefix("viewed") })

        let unreadAtOpening = await store.openThread(of: unread, in: Self.qanda)

        #expect(unreadAtOpening == [1802, 1803])
        try await waitUntil { site.calls.contains("viewed 801") }
        #expect(site.calls.filter { $0.hasPrefix("posts") || $0.hasPrefix("viewed") } == ["posts 801", "viewed 801"])
        #expect(pages.list?.discussions.first { $0.id == 801 }?.unreadCount == 0)
        #expect(store.generalForums.first { $0.id == Self.qanda.id }?.unreadPostCount == 0)
        #expect(store.thread(of: unread).value?.posts.contains(where: \.isUnread) == false)

        // Read here too for the next opening, which a copy still fresh serves without a fetch.
        let again = Self.store(folder, site: site)
        #expect(await again.openThread(of: unread, in: Self.qanda) == [])
        #expect(site.calls.filter { $0.hasPrefix("posts") }.count == 1)
    }

    @Test("a discussion opened on a copy past its freshness fetches the posts again before reading them")
    func openThreadRefetchesAStaleCopy() async {
        let folder = Folder()
        let site = Site()
        site.set(posts: [Self.post(1801)])
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        await Self.store(folder, site: site, now: { fetched }).refreshThread(of: Self.discussion(801))
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801, unread: true)])

        let later = Self.store(folder, site: site, now: { fetched + MoodleRefreshInterval.forums })
        let unreadAtOpening = await later.openThread(of: Self.discussion(801), in: Self.qanda)

        #expect(unreadAtOpening == [1802])
        #expect(site.calls.filter { $0.hasPrefix("posts") }.count == 2)
    }

    @Test("posts that fail to load at opening give no unread set, so the ones a retry brings keep their mark")
    func openThreadWithoutPosts() async throws {
        let folder = Folder()
        let site = Site()
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801, unread: true)])
        site.fail("posts")
        let store = Self.store(folder, site: site)

        let unreadAtOpening = await store.openThread(of: Self.discussion(801, replies: 1), in: Self.qanda)

        #expect(unreadAtOpening == nil)
        try await waitUntil { site.calls.contains("viewed 801") }
        site.fail("posts", false)
        await store.refreshThread(of: Self.discussion(801))
        #expect(store.thread(of: Self.discussion(801)).value?.posts.filter(\.isUnread).map(\.id) == [1802])
    }

    @Test("an expired cached thread whose opening refresh fails gives no unread snapshot for a later retry")
    func openThreadWithFailedStaleRefresh() async throws {
        let folder = Folder()
        let site = Site()
        let discussion = Self.discussion(801, replies: 2)
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801, unread: true)])
        await Self.store(folder, site: site, now: { fetched }).refreshThread(of: discussion)
        site.set(posts: [Self.post(1801), Self.post(1802, parent: 1801), Self.post(1803, parent: 1801, unread: true)])
        site.fail("posts")
        let later = Self.store(folder, site: site, now: { fetched + MoodleRefreshInterval.forums })

        let unreadAtOpening = await later.openThread(of: discussion, in: Self.qanda)

        #expect(unreadAtOpening == nil)
        #expect(later.thread(of: discussion).status == .failed)
        try await waitUntil { site.calls.contains("viewed 801") }
        site.fail("posts", false)
        await later.refreshThread(of: discussion)
        #expect(later.thread(of: discussion).value?.posts.filter(\.isUnread).map(\.id) == [1803])
        #expect(site.calls.filter { $0 == "viewed 801" }.count == 1)
    }

    @Test("a site that does not allow the view call is not told, and the discussion still reads as read here")
    func openGatedByFunctions() async throws {
        let folder = Folder()
        let site = Site()
        let unread = Self.discussion(801, unread: 1)
        site.set(pages: [[unread]])
        let store = Self.store(folder, site: site)
        await store.refreshForums()
        let pages = store.discussions(of: Self.qanda)
        await pages.refresh()
        site.set(functions: Self.allFunctions.subtracting([MoodleForumService.viewDiscussionFunction]))

        await store.open(unread, in: Self.qanda).value

        #expect(!site.calls.contains { $0.hasPrefix("viewed") })
        #expect(pages.list?.discussions.first?.unreadCount == 0)
    }

    // MARK: - Thread layout

    @Test("posts read in order, each followed by its replies oldest first, nested three levels at most")
    func threadNesting() {
        let discussion = Self.discussion(801)
        let thread = MoodleDiscussionThread(discussionId: 801, posts: [
            Self.post(1),
            Self.post(2, parent: 1),
            Self.post(3, parent: 2),
            Self.post(4, parent: 1),
            Self.post(5, parent: 3, author: "B11399005 @ Deep Five"),
            Self.post(6, parent: 5),
            Self.post(7, parent: 99),
        ])

        let entries = MoodleDiscussionThread.entries(of: discussion, in: thread)

        #expect(entries.map(\.post.id) == [1, 2, 3, 5, 6, 4, 7])
        #expect(entries.map(\.depth) == [0, 1, 2, 3, 3, 1, 1])
        #expect(entries.map(\.replyingTo) == [nil, nil, nil, nil, "Deep Five", nil, nil])
    }

    @Test("posts that answer each other in a loop still show once each")
    func threadLoop() {
        let thread = MoodleDiscussionThread(discussionId: 801, posts: [
            Self.post(1), Self.post(2, parent: 3), Self.post(3, parent: 2),
        ])

        #expect(MoodleDiscussionThread.entries(of: Self.discussion(801), in: thread).map(\.post.id) == [1, 2, 3])
    }

    // MARK: - Cards

    @Test("a forum's card reads its author and replies after the rest; an announcement's leaves them out")
    func cardAccessibility() {
        let replied = Self.discussion(801, unread: 1, pinned: true, replies: 5)
        let quiet = Self.discussion(802)
        let date = replied.modified
        let reply = String(localized: "school_mail_reply")

        let forumCard = MoodleDiscussionCard.accessibilityText(discussion: replied, date: date, showsFooter: true)
        #expect(forumCard.hasSuffix(", Tiger Duck, \(reply) 5"))
        #expect(forumCard.hasPrefix("\(String(localized: "bulletin_unread_dot_label")), \(String(localized: "course_forum_pinned")), "))
        #expect(MoodleDiscussionCard.accessibilityText(discussion: quiet, date: date, showsFooter: true).hasSuffix(", Tiger Duck"))
        #expect(!MoodleDiscussionCard.accessibilityText(discussion: replied, date: date, showsFooter: false).contains("Tiger Duck"))
    }
}
