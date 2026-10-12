import Foundation
import Observation

/// The Moodle calls behind a course's Moodle screens. Each runs under the stored token, renewed
/// as for any Moodle call. Tests pass stand-ins.
nonisolated struct MoodleCourseAPI: Sendable {
    var functions: @Sendable () async throws -> Set<String>
    var forums: @Sendable (_ courseIds: [Int]) async throws -> [MoodleForum]
    var discussions: @Sendable (_ forumId: Int, _ page: Int) async throws -> [MoodleDiscussion]
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
    private(set) var value: Value?
    private(set) var fetchedAt: Date?
    private(set) var isRefreshing = false
    /// `.unknown` until a fetch ends.
    private(set) var status: ServerStatus = .unknown
    /// The last fetch's error, cleared by the next success.
    private(set) var failure: (any Error)?

    @ObservationIgnored private let cacheName: String
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private var running: Task<Void, Never>?

    init(cacheName: String, context: MoodleCacheContext) {
        self.cacheName = cacheName
        self.context = context
        if let cached = context.cache.loadMoodleData(Value.self, name: cacheName, account: context.account) {
            value = cached.value
            fetchedAt = cached.fetchedAt
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

    /// Returns once no refresh is running.
    func waitUntilIdle() async {
        await running?.value
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
    var sorted: [MoodleDiscussion] {
        discussions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.created != rhs.created { return lhs.created > rhs.created }
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

/// A screen the course detail opens from its Moodle section.
enum MoodleCourseRoute: Hashable {
    case announcements
    case announcement(MoodleDiscussion)

    /// Whether the screen fetches its own data, which ⌘R refreshes on the Mac.
    var refreshesOnItsOwn: Bool {
        switch self {
        case .announcements: true
        case .announcement: false
        }
    }
}

/// A row of the course detail's Moodle section. More kinds join as their screens do.
struct MoodleSectionRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case announcements
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
    nonisolated static let announcementFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
    ]

    let courseId: Int
    let forums: MoodleFeed<MoodleTermForums>
    let announcements: MoodleFeed<MoodleDiscussionList>
    private(set) var isLoadingMoreAnnouncements = false

    /// Every course of the term, which one forums call covers.
    @ObservationIgnored private let termCourseIds: [Int]
    @ObservationIgnored private let api: MoodleCourseAPI

    init(courseId: Int, termCourseIds: [Int], context: MoodleCacheContext, api: MoodleCourseAPI = .live) {
        self.courseId = courseId
        self.termCourseIds = Array(Set(termCourseIds).union([courseId])).sorted()
        self.api = api
        forums = MoodleFeed(cacheName: "forums", context: context)
        announcements = MoodleFeed(cacheName: "courses/\(courseId)/announcements", context: context)
    }

    // MARK: Section

    var sectionRows: [MoodleSectionRow] {
        guard let news = newsForum, news.discussionCount > 0 else { return [] }
        return [MoodleSectionRow(kind: .announcements, count: news.discussionCount, hasUnread: news.unreadPostCount > 0)]
    }

    var isSectionRefreshing: Bool { forums.isRefreshing }
    var sectionStatus: ServerStatus { forums.status }

    // MARK: Forums

    /// When this course's forums were fetched; nil while the cache does not cover the course.
    var forumsFetchedAt: Date? {
        forums.value?.courseIds.contains(courseId) == true ? forums.fetchedAt : nil
    }

    var newsForum: MoodleForum? {
        guard let term = forums.value, term.courseIds.contains(courseId) else { return nil }
        return term.forums.first { $0.courseId == courseId && $0.isNews }
    }

    /// One call for every course of the term. A site that does not allow the forum calls answers
    /// as if no course had a forum, which hides the announcements.
    func refreshForums() async {
        await forums.refresh { [api, termCourseIds] in
            guard try await api.functions().isSuperset(of: Self.announcementFunctions) else {
                return MoodleTermForums(courseIds: termCourseIds, forums: [])
            }
            return MoodleTermForums(courseIds: termCourseIds, forums: try await api.forums(termCourseIds))
        }
    }

    // MARK: Announcements

    /// The announcements as cached for the news forum the course has now, else nil.
    var announcementList: MoodleDiscussionList? {
        guard let list = announcements.value, list.forumId == newsForum?.id else { return nil }
        return list
    }

    var announcementsFetchedAt: Date? {
        announcementList == nil ? nil : announcements.fetchedAt
    }

    /// Fetches again every page shown so far. A complete answer also corrects the section row,
    /// so a list that emptied takes its row with it.
    func refreshAnnouncements() async {
        guard let forum = newsForum else { return }
        let pages = max(1, announcementList?.pageCount ?? 1)
        await announcements.refresh { [api] in
            var list = MoodleDiscussionList(forumId: forum.id, discussions: [], pageCount: 0, hasMore: false)
            repeat {
                list.append(page: try await api.discussions(forum.id, list.pageCount))
            } while list.hasMore && list.pageCount < pages
            return list
        }
        guard announcements.status == .ok, let list = announcementList, !list.hasMore else { return }
        forums.update { term in
            guard let index = term.forums.firstIndex(where: { $0.id == forum.id }) else { return }
            term.forums[index].discussionCount = list.discussions.count
            term.forums[index].unreadPostCount = list.discussions.reduce(0) { $0 + $1.unreadCount }
        }
    }

    /// The next page, once the list reaches its end.
    func loadMoreAnnouncements() async {
        await announcements.waitUntilIdle()
        guard !isLoadingMoreAnnouncements, let list = announcementList, list.hasMore else { return }
        isLoadingMoreAnnouncements = true
        defer { isLoadingMoreAnnouncements = false }
        let page: [MoodleDiscussion]
        do {
            page = try await api.discussions(list.forumId, list.pageCount)
        } catch {
            AppLogger.breadcrumb("moodle announcements page \(list.pageCount) failed: \(error)", category: "moodle")
            return
        }
        announcements.update { current in
            guard current.forumId == list.forumId, current.pageCount == list.pageCount else { return }
            current.append(page: page)
        }
    }

    /// An announcement opened on screen: read here at once, and on Moodle through
    /// `mod_forum_view_forum_discussion` when the site allows it. The list never calls this; a
    /// failed call is not retried and shows nothing.
    @discardableResult
    func open(_ discussion: MoodleDiscussion) -> Task<Void, Never> {
        markReadHere(discussion)
        return Task { [api] in
            guard (try? await api.functions())?.contains(MoodleForumService.viewDiscussionFunction) == true else { return }
            do {
                try await api.markViewed(discussion.id)
            } catch {
                AppLogger.breadcrumb("moodle discussion view not logged: \(error)", category: "moodle")
            }
        }
    }

    private func markReadHere(_ discussion: MoodleDiscussion) {
        let unread = announcementList?.discussions.first { $0.id == discussion.id }?.unreadCount ?? 0
        guard unread > 0 else { return }
        announcements.update { list in
            guard let index = list.discussions.firstIndex(where: { $0.id == discussion.id }) else { return }
            list.discussions[index].unreadCount = 0
        }
        forums.update { term in
            guard let index = term.forums.firstIndex(where: { $0.courseId == courseId && $0.isNews }) else { return }
            term.forums[index].unreadPostCount = max(0, term.forums[index].unreadPostCount - unread)
        }
    }
}
