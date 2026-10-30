import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct MoodleCacheContext {
    let account: String
    let cache: DataCache
    let isCurrent: () -> Bool
    var now: () -> Date = { Date() }

    static func signedIn(_ authService: AuthService, cache: DataCache = .shared) -> MoodleCacheContext? {
        guard let account = authService.storedStudentId else { return nil }
        let generation = authService.loginGeneration
        return MoodleCacheContext(
            account: account,
            cache: cache,
            isCurrent: { [weak authService] in authService?.loginGeneration == generation }
        )
    }
}

@Observable
@MainActor
final class MoodleFeed<Value: Codable & Sendable> {
    let ttl: TimeInterval
    private(set) var value: Value?
    private(set) var fetchedAt: Date?
    private(set) var isRefreshing = false
    private(set) var status: ServerStatus = .unknown
    private(set) var failure: (any Error)?
    private(set) var failureCount = 0

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

    /// Waits out a running fetch before starting one, since that fetch may predate a change the
    /// caller just made on the site.
    func refetch(_ fetch: @escaping @Sendable () async throws -> Value) async {
        if let earlier = running {
            await earlier.value
            if running == earlier { running = nil }
        }
        await refresh(fetch)
    }

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
            failureCount += 1
        }
    }
}

nonisolated struct MoodleTermForums: Codable, Sendable, Equatable {
    let courseIds: [Int]
    var forums: [MoodleForum]
}

nonisolated struct MoodleDiscussionList: Codable, Sendable, Equatable {
    let forumId: Int
    var discussions: [MoodleDiscussion]
    var pageCount: Int
    var hasMore: Bool

    var sorted: [MoodleDiscussion] { sorted(by: \.created) }

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

nonisolated struct MoodleMemberList: Codable, Sendable, Equatable {
    let ownId: Int?
    var members: [MoodleMember]

    /// Whether anyone but the account is there to show, which a course split into groups the
    /// account sees alone of may not have.
    var showsOthers: Bool {
        members.contains { $0.id != ownId }
    }
}

nonisolated struct MoodleDiscussionThread: Codable, Sendable, Equatable {
    let discussionId: Int
    var posts: [MoodlePost]
}

nonisolated struct MoodleCourseGrades: Codable, Sendable, Equatable {
    var items: [MoodleGradeItem]

    var total: MoodleGradeItem? {
        items.first { $0.isCourseTotal && $0.isShown }
    }

    var graded: [MoodleGradeItem] {
        items.filter { !$0.isCourseTotal && !$0.isCategoryTotal && $0.isShown }
    }
}

enum MoodleCourseRoute: Hashable {
    case announcements
    case announcement(MoodleDiscussion)
    case materials
    case grades
    case members
    case member(MoodleMember)
    case forums
    case forum(MoodleForum)
    case discussion(MoodleDiscussion, in: MoodleForum)
    case assignments
    case assignment(MoodleCourseAssignments.Entry)
    case syllabus(CourseSyllabus)

    var refreshesOnItsOwn: Bool {
        switch self {
        case .announcements, .materials, .grades, .members, .forums, .forum, .discussion, .assignments: true
        // Its chrome takes the Mac's refresh shortcut and has nothing to fetch again.
        case .syllabus: true
        case .announcement, .member, .assignment: false
        }
    }
}

struct MoodleSectionRow: Identifiable, Equatable {
    enum Kind: Hashable {
        case announcements
        case materials
        case assignments
        case grades
        case members
        case forums
    }

    let kind: Kind
    let count: Int
    let hasUnread: Bool

    var id: Kind { kind }
}

@Observable
@MainActor
final class MoodleCourseStore {
    nonisolated static let forumFunctions: Set<String> = [
        MoodleForumService.forumsFunction, MoodleForumService.discussionsFunction,
    ]

    let courseId: Int
    let forums: MoodleFeed<MoodleTermForums>
    let materials: MoodleFeed<MoodleCourseMaterials>
    let grades: MoodleFeed<MoodleCourseGrades>
    let members: MoodleFeed<MoodleMemberList>
    let summary: MoodleFeed<MoodleCourseSummary>
    let assignments: MoodleCourseAssignments

    @ObservationIgnored private let termCourseIds: [Int]
    @ObservationIgnored private let courseCodes: [String]
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private let context: MoodleCacheContext
    @ObservationIgnored private let downloads: MoodleFileDownloads
    @ObservationIgnored private var discussionPages: [Int: MoodleDiscussionPages] = [:]
    @ObservationIgnored private var threads: [Int: MoodleFeed<MoodleDiscussionThread>] = [:]

    init(
        courseId: Int,
        termCourseIds: [Int],
        courseCodes: [String] = [],
        context: MoodleCacheContext,
        api: MoodleCourseAPI = .live,
        downloads: MoodleFileDownloads? = nil
    ) {
        self.courseId = courseId
        self.termCourseIds = Array(Set(termCourseIds).union([courseId])).sorted()
        self.courseCodes = courseCodes
        self.api = api
        self.context = context
        self.downloads = downloads ?? .shared
        forums = MoodleFeed(cacheName: "forums", ttl: MoodleRefreshInterval.forums, context: context)
        materials = MoodleFeed(
            cacheName: "courses/\(courseId)/materials", ttl: MoodleRefreshInterval.materials, context: context
        )
        grades = MoodleFeed(cacheName: "courses/\(courseId)/grades", ttl: MoodleRefreshInterval.grades, context: context)
        members = MoodleFeed(cacheName: "courses/\(courseId)/members", ttl: MoodleRefreshInterval.members, context: context)
        summary = MoodleFeed(cacheName: "courses/\(courseId)/summary", ttl: MoodleRefreshInterval.summary, context: context)
        assignments = MoodleCourseAssignments(courseId: courseId, context: context, api: api)
    }

    var sectionRows: [MoodleSectionRow] {
        var rows: [MoodleSectionRow] = []
        if let news = newsForum, news.discussionCount > 0 {
            rows.append(MoodleSectionRow(kind: .announcements, count: news.discussionCount, hasUnread: news.unreadPostCount > 0))
        }
        if let count = materials.value?.count, count > 0 {
            rows.append(MoodleSectionRow(kind: .materials, count: count, hasUnread: false))
        }
        if !assignments.list.isEmpty {
            rows.append(MoodleSectionRow(kind: .assignments, count: assignments.list.count, hasUnread: false))
        }
        if let graded = grades.value?.graded.count, graded > 0 {
            rows.append(MoodleSectionRow(kind: .grades, count: graded, hasUnread: false))
        }
        if let list = members.value, list.showsOthers {
            rows.append(MoodleSectionRow(kind: .members, count: list.members.count, hasUnread: false))
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

    var forumsFetchedAt: Date? {
        forums.value?.courseIds.contains(courseId) == true ? forums.fetchedAt : nil
    }

    private var courseForums: [MoodleForum] {
        guard let term = forums.value, term.courseIds.contains(courseId) else { return [] }
        return term.forums.filter { $0.courseId == courseId }
    }

    var newsForum: MoodleForum? {
        courseForums.first(where: \.isNews)
    }

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
        Task { [api, context] in
            guard let call = MoodleCourseContentsService.viewCalls[material.module],
                  (try? await api.functions())?.contains(call.function) == true else { return }
            do {
                try await api.markMaterialViewed(material) { @MainActor in context.isCurrent() }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.breadcrumb("moodle material view not logged: \(error)", category: "moodle")
            }
        }
    }

    func location(of file: MoodleFile, in owner: MoodleFileOwner) -> URL {
        downloads.location(of: file, owner: owner, courseId: courseId, account: context.account)
    }

    func downloadState(of file: MoodleFile, in owner: MoodleFileOwner) -> MoodleDownloadState {
        downloads.state(of: file, at: location(of: file, in: owner))
    }

    @discardableResult
    func download(_ file: MoodleFile, in owner: MoodleFileOwner) async -> URL? {
        await downloads.download(file, to: location(of: file, in: owner), fetch: api.download, isCurrent: context.isCurrent)
    }

    func cancelDownload(of file: MoodleFile, in owner: MoodleFileOwner) {
        downloads.cancel(location(of: file, in: owner))
    }

    /// The course's grade items for the signed-in student. A site that does not allow the call
    /// answers as if the course had none, which hides the row.
    func refreshGrades() async {
        await grades.refresh { [api, courseId] in
            guard try await api.functions().contains(MoodleGradeService.gradeItemsFunction) else {
                return MoodleCourseGrades(items: [])
            }
            return MoodleCourseGrades(items: try await api.gradeItems(courseId))
        }
    }

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

    var announcementPages: MoodleDiscussionPages? {
        newsForum.map(discussions(of:))
    }

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

    @discardableResult
    func open(_ discussion: MoodleDiscussion, in forum: MoodleForum?) -> Task<Void, Never> {
        guard context.isCurrent(), !Task.isCancelled else { return Task {} }
        if let forum { discussions(of: forum).markRead(discussion.id) }
        if let thread = threads[discussion.id], thread.value?.posts.contains(where: \.isUnread) == true {
            thread.update { value in
                for index in value.posts.indices { value.posts[index].isUnread = false }
            }
        }
        return Task { [api, context] in
            guard context.isCurrent(), !Task.isCancelled else { return }
            guard (try? await api.functions())?.contains(MoodleForumService.viewDiscussionFunction) == true else { return }
            guard context.isCurrent(), !Task.isCancelled else { return }
            do {
                try await api.markViewed(discussion.id) { @MainActor in context.isCurrent() }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.breadcrumb("moodle discussion view not logged: \(error)", category: "moodle")
            }
        }
    }

    @discardableResult
    func open(_ discussion: MoodleDiscussion) -> Task<Void, Never> {
        open(discussion, in: newsForum)
    }

    /// Every opening fetches the posts, as the list may not know of a reply yet, and keeps which
    /// were unread for the dots. Moodle marks the whole discussion read on the view event, so it
    /// goes only once the posts load on a page still on screen (`isShown`): an opening whose fetch
    /// fails, or whose page has left by then, sends nothing and returns nil, leaving the replies
    /// unread for the next opening.
    func openThread(
        of discussion: MoodleDiscussion, in forum: MoodleForum, isShown: () -> Bool = { true }
    ) async -> Set<Int>? {
        guard context.isCurrent(), !Task.isCancelled else { return nil }
        let feed = thread(of: discussion)
        await refreshThread(of: discussion)
        guard context.isCurrent(), !Task.isCancelled, isShown(),
              feed.status == .ok, let posts = feed.value?.posts else {
            return nil
        }
        let unread = Set(posts.filter(\.isUnread).map(\.id))
        open(discussion, in: forum)
        return unread
    }

    var membersFetchedAt: Date? { members.fetchedAt }

    func member(_ id: Int?) -> MoodleMember? {
        guard let id else { return nil }
        return members.value?.members.first { $0.id == id }
    }

    /// The whole list in one call, which the section counts and the screen groups and searches.
    /// A site that does not allow the call, or a course that keeps its participants from the
    /// account, answers as if the course had no members, which hides their row for good rather
    /// than failing on every refresh.
    func refreshMembers() async {
        await members.refresh(membersFetch)
    }

    private var membersFetch: @Sendable () async throws -> MoodleMemberList {
        { [api, courseId] in
            guard try await api.functions().contains(MoodleCourseMembersService.membersFunction) else {
                return MoodleMemberList(ownId: nil, members: [])
            }
            do {
                return try await api.members(courseId)
            } catch MoodleWebserviceError.malformedResponse(let code) where code == MoodleCourseMembersService.hiddenCode {
                return MoodleMemberList(ownId: nil, members: [])
            }
        }
    }

    func allowsPictureChange() async -> Bool {
        (try? await api.functions())?.contains(MoodleProfilePictureService.updateFunction) == true
    }

    /// Sets the account's picture, then fetches the members again for its new address.
    func updatePicture(_ jpeg: Data) async throws {
        try await api.updatePicture(jpeg) { @MainActor [context] in context.isCurrent() }
        await refetchMembers()
    }

    /// Fetches the members after a change made on Moodle, which a fetch begun before it cannot answer.
    func refetchMembers() async {
        guard context.isCurrent() else { return }
        await members.refetch(membersFetch)
    }

    private(set) var pictures: [URL: CGImage] = [:]
    @ObservationIgnored private var askedPictures: Set<URL> = []
    @ObservationIgnored private var picturesInFlight: Set<URL> = []
    /// Shared because every course's store keeps an account's pictures in one folder.
    private static var placedRevisions: [URL: Int] = [:]
    @ObservationIgnored private var lastPictureDownload: Task<Data?, Never>?
    @ObservationIgnored private var lastPictureRead: Task<CGImage?, Never>?
    @ObservationIgnored var readPictureFile: @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    @ObservationIgnored var decodePicture: @Sendable (Data) -> CGImage? = { MoodleCourseStore.image(from: $0) }

    /// The picture kept on the device shows first; Moodle's, asked for once a visit, replaces it
    /// when it differs. A picture is kept by the member's student ID, so the address of a new upload
    /// still finds the old picture to show until the new one lands.
    func loadPicture(of member: MoodleMember) async {
        guard let url = member.pictureURL else { return }
        // A request still out may yet be cancelled with its row, which leaves this caller to ask.
        if picturesInFlight.contains(url) { _ = await lastPictureDownload?.value }
        guard !askedPictures.contains(url) else { return }
        let file = pictureFile(of: member, url: url)
        let revision = Int(Self.revision(of: url)) ?? 0
        if pictures[url] == nil, let kept = await readInTurn(file) {
            guard context.isCurrent() else { return }
            pictures[url] = kept
        }
        guard let data = await downloadInTurn(url) else { return }
        let read = readPictureFile
        let decode = decodePicture
        // Another course's store may have kept these bytes since this one read the file.
        let isShown = pictures[url] != nil
        let changed = await Task.detached(priority: .userInitiated) { () -> (CGImage, URL?)? in
            let isNew = read(file) != data
            guard isNew || !isShown, let image = decode(data) else { return nil }
            guard isNew else { return (image, nil) }
            return Self.stage(data, for: file, revision: revision).map { (image, $0) }
        }.value
        guard case let (image, staged)? = changed else { return }
        // An older revision's disk work can end after a newer one's, which it must not replace.
        guard context.isCurrent(), staged == nil || revision >= Self.placedRevisions[file, default: 0] else {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            return
        }
        if let staged {
            Self.placedRevisions[file] = revision
            Self.place(staged, at: file)
        }
        pictures[url] = image
    }

    /// The member's own picture as a file named for them, which Quick Look opens and its share
    /// menu saves: Moodle's 512 px size of this revision, downloaded on the first open and kept,
    /// else the 100 px one the list shows; nil while neither is on the device. Quick Look tells an
    /// image by its extension, which the kept files have none of. Each open writes the copy again,
    /// next to the kept files, so a sign-out deletes it too.
    func picturePreview(of member: MoodleMember) async -> URL? {
        guard let url = member.pictureURL, context.isCurrent() else { return nil }
        let kept = pictureFile(of: member, url: url)
        let large = kept.deletingLastPathComponent()
            .appendingPathComponent("\(kept.lastPathComponent)-\(Self.revision(of: url))-f3")
        guard let data = await largePicture(of: url, keptAt: large) ?? (try? Data(contentsOf: kept)),
              context.isCurrent(), let fileExtension = Self.fileExtension(of: data) else { return nil }
        let preview = kept.deletingLastPathComponent()
            .appendingPathComponent(kept.lastPathComponent + "-preview", isDirectory: true)
            .appendingPathComponent(MoodleFileDownloads.safeName(member.name))
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: preview, options: [.atomic, .completeFileProtectionUnlessOpen])
            return preview
        } catch {
            AppLogger.breadcrumb("moodle member picture preview not written: \(error)", category: "moodle")
            return nil
        }
    }

    private func largePicture(of url: URL, keptAt file: URL) async -> Data? {
        if let kept = try? Data(contentsOf: file) { return kept }
        guard let large = MoodleCourseMembersService.largePicture(url) else { return nil }
        do {
            let data = try await api.picture(large)
            guard Self.fileExtension(of: data) != nil, context.isCurrent() else { return nil }
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            return data
        } catch {
            AppLogger.breadcrumb("moodle member large picture not downloaded: \(error)", category: "moodle")
            return nil
        }
    }

    private nonisolated static func fileExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { return nil }
        return type.preferredFilenameExtension
    }

    private func readInTurn(_ file: URL) async -> CGImage? {
        let previous = lastPictureRead
        let read = readPictureFile
        let decode = decodePicture
        let turn = Task.detached(priority: .userInitiated) { () -> CGImage? in
            _ = await previous?.value
            return read(file).flatMap(decode)
        }
        lastPictureRead = turn
        return await turn.value
    }

    /// A visit asks for a picture once, failed or not, and a turn whose picture another row already
    /// asked for asks nothing. A request its row cancelled learned nothing, so the row asks again.
    private func downloadInTurn(_ url: URL) async -> Data? {
        let previous = lastPictureDownload
        let turn = Task { [api] () -> Data? in
            _ = await previous?.value
            guard !Task.isCancelled, !self.askedPictures.contains(url) else { return nil }
            self.askedPictures.insert(url)
            self.picturesInFlight.insert(url)
            defer { self.picturesInFlight.remove(url) }
            do {
                return try await api.picture(url)
            } catch {
                if Task.isCancelled {
                    self.askedPictures.remove(url)
                } else {
                    AppLogger.breadcrumb("moodle member picture not downloaded: \(error)", category: "moodle")
                }
                return nil
            }
        }
        lastPictureDownload = turn
        return await withTaskCancellationHandler { await turn.value } onCancel: { turn.cancel() }
    }

    /// Named for the member's student ID, or for a member without one, their Moodle user id and the
    /// picture's revision. Either way the files that go with it are the name and a dash before more.
    private func pictureFile(of member: MoodleMember, url: URL) -> URL {
        let account = Self.folderName(context.account)
        let studentId = Self.folderName(member.studentId ?? "")
        let name = studentId.isEmpty ? "\(member.id)-\(Self.revision(of: url))" : studentId
        return context.cache.moodleFilesDir
            .appendingPathComponent(account.isEmpty ? "_" : account, isDirectory: true)
            .appendingPathComponent("pictures", isDirectory: true)
            .appendingPathComponent(name)
    }

    private nonisolated static func folderName(_ text: String) -> String {
        String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    private nonisolated static func revision(of url: URL) -> String {
        folderName(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rev" }?.value ?? "")
    }

    /// Deletes the member's other files, which a new picture outdates, but not a newer revision's
    /// or the preview folders Quick Look may have open, and writes the picture to a temporary file
    /// for `place`.
    private nonisolated static func stage(_ data: Data, for file: URL, revision: Int) -> URL? {
        let files = FileManager.default
        let prefix = String(file.lastPathComponent.prefix { $0 != "-" }) + "-"
        let earlier = (try? files.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for old in earlier where old.lastPathComponent.hasPrefix(prefix) && old.lastPathComponent != file.lastPathComponent
            && (try? old.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            let oldRevision = Int(old.lastPathComponent.dropFirst(prefix.count).prefix { $0 != "-" })
            if (oldRevision ?? 0) <= revision { try? files.removeItem(at: old) }
        }
        let staged = files.temporaryDirectory.appendingPathComponent("MoodlePicture-\(UUID().uuidString)")
        do {
            try data.write(to: staged, options: [.atomic, .completeFileProtectionUnlessOpen])
            return staged
        } catch {
            return nil
        }
    }

    /// Runs on the main actor right after the account check, so no picture lands after a sign-out.
    private nonisolated static func place(_ staged: URL, at file: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: file)
        if (try? files.moveItem(at: staged, to: file)) == nil { try? files.removeItem(at: staged) }
    }

    private nonisolated static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    var shownSummary: MoodleCourseSummary? {
        guard let value = summary.value, value.isWorthShowing(besides: courseCodes) else { return nil }
        return value
    }

    /// One call for this course. A site that does not allow it answers as if the course had no
    /// summary, which shows nothing.
    func refreshSummary() async {
        await summary.refresh { [api, courseId] in
            guard try await api.functions().contains(MoodleCourseSummaryService.coursesFunction) else { return .empty }
            return try await api.summary(courseId)
        }
    }
}
