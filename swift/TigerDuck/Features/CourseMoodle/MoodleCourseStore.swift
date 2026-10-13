import Foundation
import Observation

/// The Moodle calls behind a course's Moodle screens. Each runs under the stored token, renewed
/// as for any Moodle call. Tests pass stand-ins.
nonisolated struct MoodleCourseAPI: Sendable {
    var functions: @Sendable () async throws -> Set<String>
    var forums: @Sendable (_ courseIds: [Int]) async throws -> [MoodleForum]
    var discussions: @Sendable (_ forumId: Int, _ page: Int) async throws -> [MoodleDiscussion]
    var posts: @Sendable (_ discussionId: Int) async throws -> [MoodlePost]
    var markViewed: @Sendable (_ discussionId: Int) async throws -> Void

    static let live = MoodleCourseAPI(
        functions: {
            try await MoodleWebserviceClient.withToken { try await MoodleSiteInfoService.shared.functions(token: $0) }
        },
        forums: { courseIds in
            try await MoodleWebserviceClient.withToken { try await MoodleForumService.forums(courseIds: courseIds, token: $0) }
        },
        discussions: { forumId, page in
            try await MoodleWebserviceClient.withToken {
                try await MoodleForumService.discussions(forumId: forumId, page: page, token: $0)
            }
        },
        posts: { discussionId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleForumService.posts(discussionId: discussionId, token: $0)
            }
        },
        markViewed: { discussionId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleForumService.markViewed(discussionId: discussionId, token: $0)
            }
        }
    )
}

/// Where a course's Moodle data is cached, and whether the sign-in it is fetched under still holds.
struct MoodleCacheContext {
    let account: String
    let cache: DataCache
    /// False once the account signs out, after which nothing is written.
    let isCurrent: () -> Bool
    var now: () -> Date = { Date() }
}

/// One kind of a course's Moodle data as its screen shows it: the cached copy at once, then each
/// fetch in place, with the fetch's progress and outcome for the screen's status dot.
@Observable
@MainActor
final class MoodleFeed<Value: Codable & Sendable> {
    /// How long a copy counts as fresh; the screen's refresh timer fetches it again once older.
    let ttl: TimeInterval
    private(set) var value: Value?
    private(set) var fetchedAt: Date?
    private(set) var isRefreshing = false
    /// `.ok` for a cached copy still fresh, as no fetch comes until it ages, else `.unknown` until
    /// a fetch ends.
    private(set) var status: ServerStatus = .unknown
    /// The last fetch's error, cleared by the next success.
    private(set) var failure: (any Error)?

    @ObservationIgnored private let cacheName: String
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private var running: Task<Void, Never>?

    init(cacheName: String, ttl: TimeInterval, context: MoodleCacheContext) {
        self.cacheName = cacheName
        self.ttl = ttl
        self.context = context
        if let cached = context.cache.loadMoodleData(Value.self, name: cacheName, account: context.account) {
            value = cached.value
            fetchedAt = cached.fetchedAt
            if MoodleRefreshTimer.wait(fetchedAt: cached.fetchedAt, lastTry: nil, ttl: ttl, now: context.now()) > 0 {
                status = .ok
            }
        }
    }

    /// Fetches through `fetch` and keeps the answer. A refresh already running is joined, not
    /// repeated, so a pull during a timed refresh waits for that one.
    func refresh(_ fetch: @escaping @Sendable () async throws -> Value) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await run(fetch) }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// Applies a change made here, such as a discussion read, keeping the time of the fetch the
    /// value came from.
    func update(_ change: (inout Value) -> Void) {
        guard var changed = value, let fetchedAt, context.isCurrent() else { return }
        change(&changed)
        value = changed
        context.cache.saveMoodleData(changed, fetchedAt: fetchedAt, name: cacheName, account: context.account)
    }

    private func run(_ fetch: @Sendable () async throws -> Value) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await fetch()
            guard context.isCurrent() else { return }
            let now = context.now()
            value = fresh
            fetchedAt = now
            status = .ok
            failure = nil
            context.cache.saveMoodleData(fresh, fetchedAt: now, name: cacheName, account: context.account)
        } catch {
            guard context.isCurrent() else { return }
            status = .failed
            failure = error
        }
    }
}

/// The forums of a term's courses, from one call for all of them.
nonisolated struct MoodleTermForums: Codable, Sendable, Equatable {
    /// The courses asked about, so a course with no forums tells apart from one not asked about.
    let courseIds: [Int]
    var forums: [MoodleForum]
}

/// The discussions of one forum, a page at a time.
nonisolated struct MoodleDiscussionList: Codable, Sendable, Equatable {
    let forumId: Int
    var discussions: [MoodleDiscussion]
    /// Pages fetched; a refresh fetches as many again, so the list keeps its length.
    var pageCount: Int
    var hasMore: Bool

    /// Pinned first, then newest first.
    var sorted: [MoodleDiscussion] { sorted(by: \.created) }

    /// Pinned first, then newest first by `date`, such as the latest post's time.
    func sorted(by date: KeyPath<MoodleDiscussion, Date>) -> [MoodleDiscussion] {
        discussions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs[keyPath: date] != rhs[keyPath: date] { return lhs[keyPath: date] > rhs[keyPath: date] }
            return lhs.id > rhs.id
        }
    }

    mutating func append(page: [MoodleDiscussion]) {
        let known = Set(discussions.map(\.id))
        discussions += page.filter { !known.contains($0.id) }
        pageCount += 1
        hasMore = page.count == MoodleForumService.discussionsPerPage
    }
}

/// A discussion's posts, oldest first.
nonisolated struct MoodleDiscussionThread: Codable, Sendable, Equatable {
    let discussionId: Int
    var posts: [MoodlePost]
}

/// A screen the course detail opens from its Moodle section.
enum MoodleCourseRoute: Hashable {
    case announcements
    case announcement(MoodleDiscussion)
    case forums
    case forum(MoodleForum)
    case discussion(MoodleDiscussion, in: MoodleForum)

    /// Whether the screen fetches its own data, which ⌘R refreshes on the Mac.
    var refreshesOnItsOwn: Bool {
        switch self {
        case .announcements, .forums, .forum, .discussion: true
        case .announcement: false
        }
    }
}

/// A row of the course detail's Moodle section. More kinds join as their screens do.
struct MoodleSectionRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case announcements
        case forums
    }

    let kind: Kind
    let count: Int
    let hasUnread: Bool

    var id: Kind { kind }
}

/// A course's data on Moodle, for the course detail's Moodle section and the screens it opens.
/// Each kind is a ``MoodleFeed``, cached on the device for the signed-in account.
@Observable
@MainActor
final class MoodleCourseStore {
    nonisolated static let forumFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
    ]

    let courseId: Int
    let forums: MoodleFeed<MoodleTermForums>

    /// Every course of the term, which one forums call covers.
    @ObservationIgnored private let termCourseIds: [Int]
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private let context: MoodleCacheContext
    /// Made on first use, by forum and by discussion, and kept while the store lives.
    @ObservationIgnored private var discussionPages: [Int: MoodleDiscussionPages] = [:]
    @ObservationIgnored private var threads: [Int: MoodleFeed<MoodleDiscussionThread>] = [:]

    init(courseId: Int, termCourseIds: [Int], context: MoodleCacheContext, api: MoodleCourseAPI = .live) {
        self.courseId = courseId
        self.termCourseIds = Array(Set(termCourseIds).union([courseId])).sorted()
        self.api = api
        self.context = context
        forums = MoodleFeed(cacheName: "forums", ttl: MoodleRefreshInterval.forums, context: context)
    }

    // MARK: Section

    var sectionRows: [MoodleSectionRow] {
        var rows: [MoodleSectionRow] = []
        if let news = newsForum, news.discussionCount > 0 {
            rows.append(MoodleSectionRow(kind: .announcements, count: news.discussionCount, hasUnread: news.unreadPostCount > 0))
        }
        let general = generalForums
        if !general.isEmpty {
            rows.append(MoodleSectionRow(
                kind: .forums,
                count: general.reduce(0) { $0 + $1.discussionCount },
                hasUnread: general.contains { $0.unreadPostCount > 0 }
            ))
        }
        return rows
    }

    var isSectionRefreshing: Bool { forums.isRefreshing }
    var sectionStatus: ServerStatus { forums.status }

    // MARK: Forums

    /// When this course's forums were fetched; nil while the cache does not cover the course.
    var forumsFetchedAt: Date? {
        forums.value?.courseIds.contains(courseId) == true ? forums.fetchedAt : nil
    }

    /// The course's forums in Moodle's order; none while the cache does not cover the course.
    private var courseForums: [MoodleForum] {
        guard let term = forums.value, term.courseIds.contains(courseId) else { return [] }
        return term.forums.filter { $0.courseId == courseId }
    }

    var newsForum: MoodleForum? {
        courseForums.first(where: \.isNews)
    }

    /// The forums other than the announcements that hold a discussion, in Moodle's order.
    var generalForums: [MoodleForum] {
        courseForums.filter { !$0.isNews && $0.discussionCount > 0 }
    }

    /// One call for every course of the term. A site that does not allow the forum calls answers
    /// as if no course had a forum, which hides the announcements and the forums; one that does
    /// not allow the posts call keeps only the announcements, as a discussion would show no reply.
    func refreshForums() async {
        await forums.refresh { [api, termCourseIds] in
            let functions = try await api.functions()
            guard functions.isSuperset(of: Self.forumFunctions) else {
                return MoodleTermForums(courseIds: termCourseIds, forums: [])
            }
            let all = try await api.forums(termCourseIds)
            let shown = functions.contains(MoodleForumService.discussionPostsFunction) ? all : all.filter(\.isNews)
            return MoodleTermForums(courseIds: termCourseIds, forums: shown)
        }
    }

    // MARK: Discussions

    /// A forum's discussions. The news forum's are the announcements, newest posting first; any
    /// other forum's list the latest post first.
    func discussions(of forum: MoodleForum) -> MoodleDiscussionPages {
        if let pages = discussionPages[forum.id] { return pages }
        let feed = forum.isNews
            ? MoodleFeed<MoodleDiscussionList>(
                cacheName: "courses/\(courseId)/announcements", ttl: MoodleRefreshInterval.announcements, context: context
            )
            : MoodleFeed<MoodleDiscussionList>(
                cacheName: "courses/\(courseId)/forums/\(forum.id)", ttl: MoodleRefreshInterval.forums, context: context
            )
        let pages = MoodleDiscussionPages(
            forumId: forum.id, feed: feed, date: forum.isNews ? \.created : \.modified, forums: forums, api: api
        )
        discussionPages[forum.id] = pages
        return pages
    }

    /// The announcements, once the forums say which forum holds them.
    var announcementPages: MoodleDiscussionPages? {
        newsForum.map(discussions(of:))
    }

    /// A discussion's posts, cached apart for each discussion.
    func thread(of discussion: MoodleDiscussion) -> MoodleFeed<MoodleDiscussionThread> {
        if let feed = threads[discussion.id] { return feed }
        let feed = MoodleFeed<MoodleDiscussionThread>(
            cacheName: "courses/\(courseId)/discussions/\(discussion.id)", ttl: MoodleRefreshInterval.forums, context: context
        )
        threads[discussion.id] = feed
        return feed
    }

    /// A site that does not allow the posts call answers with none, which leaves the first post
    /// as the discussion's list brought it.
    func refreshThread(of discussion: MoodleDiscussion) async {
        await thread(of: discussion).refresh { [api] in
            guard try await api.functions().contains(MoodleForumService.discussionPostsFunction) else {
                return MoodleDiscussionThread(discussionId: discussion.id, posts: [])
            }
            return MoodleDiscussionThread(discussionId: discussion.id, posts: try await api.posts(discussion.id))
        }
    }

    // MARK: Opening

    /// A discussion opened on screen: read here at once, in its forum and its posts, and on
    /// Moodle through `mod_forum_view_forum_discussion` when the site allows it. The lists never
    /// call this; a failed call is not retried and shows nothing.
    @discardableResult
    func open(_ discussion: MoodleDiscussion, in forum: MoodleForum?) -> Task<Void, Never> {
        if let forum { discussions(of: forum).markRead(discussion.id) }
        if let thread = threads[discussion.id], thread.value?.posts.contains(where: \.isUnread) == true {
            thread.update { value in
                for index in value.posts.indices { value.posts[index].isUnread = false }
            }
        }
        return Task { [api] in
            guard (try? await api.functions())?.contains(MoodleForumService.viewDiscussionFunction) == true else { return }
            do {
                try await api.markViewed(discussion.id)
            } catch {
                AppLogger.breadcrumb("moodle discussion view not logged: \(error)", category: "moodle")
            }
        }
    }

    /// An announcement opened on screen, read as ``open(_:in:)`` reads a discussion.
    @discardableResult
    func open(_ discussion: MoodleDiscussion) -> Task<Void, Never> {
        open(discussion, in: newsForum)
    }

    /// A discussion's posts opened on screen. They are fetched first when the copy is due, so the
    /// ones unread at this opening are known before ``open(_:in:)`` reads them. Their ids come
    /// back, or nil while no posts could be had, so posts a retry brings keep their own mark.
    func openThread(of discussion: MoodleDiscussion, in forum: MoodleForum) async -> Set<Int>? {
        let feed = thread(of: discussion)
        if MoodleRefreshTimer.wait(fetchedAt: feed.fetchedAt, lastTry: nil, ttl: feed.ttl, now: context.now()) == 0 {
            await refreshThread(of: discussion)
        }
        let unread = feed.value.map { Set($0.posts.filter(\.isUnread).map(\.id)) }
        open(discussion, in: forum)
        return unread
    }
}
