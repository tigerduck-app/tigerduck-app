import Foundation
import Observation

/// The Moodle calls behind a course's Moodle screens. Each runs under the stored token, renewed
/// as for any Moodle call. Tests pass stand-ins.
nonisolated struct MoodleCourseAPI: Sendable {
    var functions: @Sendable () async throws -> Set<String>
    var forums: @Sendable (_ courseIds: [Int]) async throws -> [MoodleForum]
    var discussions: @Sendable (_ forumId: Int, _ page: Int) async throws -> [MoodleDiscussion]
    var markViewed: @Sendable (_ discussionId: Int) async throws -> Void
    /// Defaults keep a stand-in for another screen's tests to the calls it is about.
    var materials: @Sendable (_ courseId: Int) async throws -> MoodleCourseMaterials = { _ in
        MoodleCourseMaterials(sections: [])
    }
    var markMaterialViewed: @Sendable (_ material: MoodleMaterial) async throws -> Void = { _ in }
    /// Downloads a file to a temporary location the caller moves; `progress` gets the share
    /// received so far.
    var download: @Sendable (_ file: MoodleFile, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL = { _, _ in
        throw CancellationError()
    }

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
        },
        materials: { courseId in
            try await MoodleWebserviceClient.withToken {
                try await MoodleCourseContentsService.materials(courseId: courseId, token: $0)
            }
        },
        markMaterialViewed: { material in
            try await MoodleWebserviceClient.withToken {
                try await MoodleCourseContentsService.markViewed(material, token: $0)
            }
        },
        download: { file, progress in
            try await MoodleWebserviceClient.withToken { token in
                let key = try await MoodleSiteInfoService.shared.privateAccessKey(token: token)
                guard let source = URL(string: file.url),
                      let url = MoodleFileTransfer.downloadURL(for: source, accessKey: key, token: token) else {
                    throw MoodleWebserviceError.malformedResponse(detail: "file URL")
                }
                return try await MoodleFileTransfer.fetch(url, mimeType: file.mimeType, expectedSize: file.size, progress: progress)
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
    case materials

    /// Whether the screen fetches its own data, which ⌘R refreshes on the Mac.
    var refreshesOnItsOwn: Bool {
        switch self {
        case .announcements, .materials: true
        case .announcement: false
        }
    }
}

/// A row of the course detail's Moodle section. More kinds join as their screens do.
struct MoodleSectionRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case announcements
        case materials
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
    let materials: MoodleFeed<MoodleCourseMaterials>
    private(set) var isLoadingMoreAnnouncements = false
    private(set) var announcementsPageFailure: (any Error)?

    /// Every course of the term, which one forums call covers.
    @ObservationIgnored private let termCourseIds: [Int]
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private let downloads: MoodleFileDownloads
    @ObservationIgnored private var listWork: Task<Void, Never>?
    @ObservationIgnored private var announcementsRefresh: Task<Void, Never>?

    init(
        courseId: Int,
        termCourseIds: [Int],
        context: MoodleCacheContext,
        api: MoodleCourseAPI = .live,
        downloads: MoodleFileDownloads? = nil
    ) {
        self.courseId = courseId
        self.termCourseIds = Array(Set(termCourseIds).union([courseId])).sorted()
        self.api = api
        self.context = context
        self.downloads = downloads ?? .shared
        forums = MoodleFeed(cacheName: "forums", ttl: MoodleRefreshInterval.forums, context: context)
        announcements = MoodleFeed(
            cacheName: "courses/\(courseId)/announcements", ttl: MoodleRefreshInterval.announcements, context: context
        )
        materials = MoodleFeed(
            cacheName: "courses/\(courseId)/materials", ttl: MoodleRefreshInterval.materials, context: context
        )
    }

    // MARK: Section

    var sectionRows: [MoodleSectionRow] {
        var rows: [MoodleSectionRow] = []
        if let news = newsForum, news.discussionCount > 0 {
            rows.append(MoodleSectionRow(kind: .announcements, count: news.discussionCount, hasUnread: news.unreadPostCount > 0))
        }
        if let count = materials.value?.count, count > 0 {
            rows.append(MoodleSectionRow(kind: .materials, count: count, hasUnread: false))
        }
        return rows
    }

    var isSectionRefreshing: Bool { forums.isRefreshing || materials.isRefreshing }

    /// Failed when one of the section's feeds failed, else OK once one reads OK: a feed still
    /// unknown has its first fetch on the way, as the section fetches every feed it shows.
    var sectionStatus: ServerStatus {
        let statuses = [forums.status, materials.status]
        if statuses.contains(.failed) { return .failed }
        return statuses.contains(.ok) ? .ok : .unknown
    }

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

    // MARK: Materials

    var materialsFetchedAt: Date? { materials.fetchedAt }

    /// A site that does not allow the call answers as if the course had no materials, which hides
    /// their row. Copies of files Moodle has a newer version of go once the answer is in.
    func refreshMaterials() async {
        await materials.refresh { [api, courseId] in
            guard try await api.functions().contains(MoodleCourseContentsService.contentsFunction) else {
                return MoodleCourseMaterials(sections: [])
            }
            return try await api.materials(courseId)
        }
        guard materials.status == .ok, let fresh = materials.value else { return }
        downloads.removeOutdated(fresh.fileRefs.map { ($0.file, location(of: $0.file, in: $0.owner)) })
    }

    /// A file or link opened on screen, which Moodle logs as a view of its module when the site
    /// allows the call. A failed call is not retried and shows nothing.
    @discardableResult
    func open(_ material: MoodleMaterial) -> Task<Void, Never> {
        Task { [api] in
            guard let call = MoodleCourseContentsService.viewCalls[material.module],
                  (try? await api.functions())?.contains(call.function) == true else { return }
            do {
                try await api.markMaterialViewed(material)
            } catch {
                AppLogger.breadcrumb("moodle material view not logged: \(error)", category: "moodle")
            }
        }
    }

    // MARK: Files

    /// Where `file` is kept on the device for the signed-in account.
    func location(of file: MoodleFile, in owner: MoodleFileOwner) -> URL {
        downloads.location(of: file, owner: owner, courseId: courseId, account: context.account)
    }

    func downloadState(of file: MoodleFile, in owner: MoodleFileOwner) -> MoodleDownloadState {
        downloads.state(of: file, at: location(of: file, in: owner))
    }

    /// The copy of `file` on the device, downloaded first when there is none; nil when that fails.
    @discardableResult
    func download(_ file: MoodleFile, in owner: MoodleFileOwner) async -> URL? {
        await downloads.download(file, to: location(of: file, in: owner), fetch: api.download, isCurrent: context.isCurrent)
    }

    func cancelDownload(of file: MoodleFile, in owner: MoodleFileOwner) {
        downloads.cancel(location(of: file, in: owner))
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
    /// so a list that emptied takes its row with it. A refresh asked for while one is queued or
    /// running joins it, so a pull during a timed refresh fetches once.
    func refreshAnnouncements() async {
        if let announcementsRefresh {
            await announcementsRefresh.value
            return
        }
        let task = Task { await refreshAnnouncementsInTurn() }
        announcementsRefresh = task
        await task.value
        if announcementsRefresh == task { announcementsRefresh = nil }
    }

    private func refreshAnnouncementsInTurn() async {
        await serially { [self] in
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
            announcementsPageFailure = nil
            forums.update { term in
                guard let index = term.forums.firstIndex(where: { $0.id == forum.id }) else { return }
                term.forums[index].discussionCount = list.discussions.count
                term.forums[index].unreadPostCount = list.discussions.reduce(0) { $0 + $1.unreadCount }
            }
        }
    }

    /// The next page, when the list's last announcement, `lastId`, comes on screen. A failure stays
    /// in ``announcementsPageFailure`` until a page loads, so the list can offer a retry.
    func loadMoreAnnouncements(after lastId: Int?) async {
        await serially { [self] in
            guard let list = announcementList, list.hasMore, lastId == list.sorted.last?.id else { return }
            isLoadingMoreAnnouncements = true
            defer { isLoadingMoreAnnouncements = false }
            do {
                let page = try await api.discussions(list.forumId, list.pageCount)
                announcementsPageFailure = nil
                announcements.update { current in
                    guard current.forumId == list.forumId, current.pageCount == list.pageCount else { return }
                    current.append(page: page)
                }
            } catch {
                announcementsPageFailure = error
            }
        }
    }

    /// Runs `work` after the list changes already queued: a refresh that started during a page
    /// load would otherwise end with fewer pages than the list just gained.
    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = listWork
        let task = Task {
            await previous?.value
            await work()
        }
        listWork = task
        await task.value
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
