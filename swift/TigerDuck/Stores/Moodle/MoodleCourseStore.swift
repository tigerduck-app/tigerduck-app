import Foundation
import ImageIO
import Observation

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

    private struct Source {
        let termCourseIds: [Int]
        let courseCodes: [String]
        let api: MoodleCourseAPI
        let context: MoodleCacheContext
        let downloads: MoodleFileDownloads
    }

    @ObservationIgnored private let source: Source
    @ObservationIgnored private let forumStore: MoodleCourseForums
    @ObservationIgnored private let memberPictures: MoodleMemberPictures

    private var api: MoodleCourseAPI { source.api }
    private var context: MoodleCacheContext { source.context }
    private var downloads: MoodleFileDownloads { source.downloads }

    init(
        courseId: Int,
        termCourseIds: [Int],
        courseCodes: [String] = [],
        context: MoodleCacheContext,
        api: MoodleCourseAPI = .live,
        downloads: MoodleFileDownloads? = nil
    ) {
        self.courseId = courseId
        let source = Source(
            termCourseIds: Array(Set(termCourseIds).union([courseId])).sorted(),
            courseCodes: courseCodes, api: api, context: context, downloads: downloads ?? .shared
        )
        self.source = source
        let forums = MoodleFeed<MoodleTermForums>(cacheName: "forums", ttl: MoodleRefreshInterval.forums, context: context)
        self.forums = forums
        materials = MoodleFeed(
            cacheName: "courses/\(courseId)/materials", ttl: MoodleRefreshInterval.materials, context: context
        )
        grades = MoodleFeed(cacheName: "courses/\(courseId)/grades", ttl: MoodleRefreshInterval.grades, context: context)
        members = MoodleFeed(cacheName: "courses/\(courseId)/members", ttl: MoodleRefreshInterval.members, context: context)
        summary = MoodleFeed(cacheName: "courses/\(courseId)/summary", ttl: MoodleRefreshInterval.summary, context: context)
        assignments = MoodleCourseAssignments(courseId: courseId, context: context, api: api)
        forumStore = MoodleCourseForums(
            courseId: courseId, termCourseIds: source.termCourseIds, forums: forums, api: api, context: context
        )
        memberPictures = MoodleMemberPictures(api: api, context: context)
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

    var forumsFetchedAt: Date? { forumStore.forumsFetchedAt }

    var newsForum: MoodleForum? { forumStore.newsForum }

    var generalForums: [MoodleForum] { forumStore.generalForums }

    func refreshForums() async { await forumStore.refreshForums() }

    var materialsFetchedAt: Date? { materials.fetchedAt }

    func refreshMaterials() async {
        await materials.refresh { [api, courseId] in
            try await api.ifAllowed(MoodleCourseContentsService.contentsFunction, else: MoodleCourseMaterials(sections: [])) {
                try await api.materials(courseId)
            }
        }
        guard materials.status == .ok, let fresh = materials.value else { return }
        downloads.removeOutdated(fresh.fileRefs.map { ($0.file, location(of: $0.file, in: $0.owner)) })
    }

    @discardableResult
    func logView(of material: MoodleMaterial) -> Task<Void, Never> {
        Task { [api, context] in
            guard let call = MoodleCourseContentsService.viewCalls[material.module],
                  (try? await api.functions())?.contains(call.function) == true else { return }
            do {
                try await api.markMaterialViewed(material, context.signIn)
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
        await downloads.download(file, to: location(of: file, in: owner), fetch: api.download, for: context.signIn)
    }

    func cancelDownload(of file: MoodleFile, in owner: MoodleFileOwner) {
        downloads.cancel(location(of: file, in: owner))
    }

    func refreshGrades() async {
        await grades.refresh { [api, courseId] in
            try await api.ifAllowed(MoodleGradeService.gradeItemsFunction, else: MoodleCourseGrades(items: [])) {
                MoodleCourseGrades(items: try await api.gradeItems(courseId))
            }
        }
    }

    func discussions(of forum: MoodleForum) -> MoodleDiscussionPages { forumStore.discussions(of: forum) }

    var announcementPages: MoodleDiscussionPages? { forumStore.announcementPages }

    func thread(of discussion: MoodleDiscussion) -> MoodleFeed<MoodleDiscussionThread> { forumStore.thread(of: discussion) }

    func refreshThread(of discussion: MoodleDiscussion) async { await forumStore.refreshThread(of: discussion) }

    @discardableResult
    func open(_ discussion: MoodleDiscussion, in forum: MoodleForum?) -> Task<Void, Never> {
        forumStore.open(discussion, in: forum)
    }

    @discardableResult
    func open(_ discussion: MoodleDiscussion) -> Task<Void, Never> { forumStore.open(discussion) }

    func openThread(
        of discussion: MoodleDiscussion, in forum: MoodleForum, isShown: () -> Bool = { true }
    ) async -> Set<Int>? {
        await forumStore.openThread(of: discussion, in: forum, isShown: isShown)
    }

    var membersFetchedAt: Date? { members.fetchedAt }

    func member(_ id: Int?) -> MoodleMember? {
        guard let id else { return nil }
        return members.value?.members.first { $0.id == id }
    }

    func refreshMembers() async {
        await members.refresh(membersFetch)
    }

    private var membersFetch: @Sendable () async throws -> MoodleMemberList {
        { [api, courseId] in
            let none = MoodleMemberList(ownId: nil, members: [])
            return try await api.ifAllowed(MoodleCourseMembersService.membersFunction, else: none) {
                do {
                    return try await api.members(courseId)
                } catch MoodleWebserviceError.malformedResponse(let code) where code == MoodleCourseMembersService.hiddenCode {
                    return none
                }
            }
        }
    }

    func allowsPictureChange() async -> Bool {
        (try? await api.functions())?.contains(MoodleProfilePictureService.updateFunction) == true
    }

    func updatePicture(_ jpeg: Data) async throws {
        try await api.updatePicture(jpeg, context.signIn)
        await refetchMembers()
    }

    func refetchMembers() async {
        guard context.signIn.isCurrent else { return }
        await members.refreshAfterSiteChange(membersFetch)
    }

    var pictures: [URL: CGImage] { memberPictures.pictures }

    var readPictureFile: @Sendable (URL) -> Data? {
        get { memberPictures.readPictureFile } set { memberPictures.readPictureFile = newValue }
    }

    var decodePicture: @Sendable (Data) -> CGImage? {
        get { memberPictures.decodePicture } set { memberPictures.decodePicture = newValue }
    }

    func loadPicture(of member: MoodleMember) async { await memberPictures.loadPicture(of: member) }

    func picturePreview(of member: MoodleMember) async -> URL? { await memberPictures.picturePreview(of: member) }

    var shownSummary: MoodleCourseSummary? {
        guard let value = summary.value, value.isWorthShowing(besides: source.courseCodes) else { return nil }
        return value
    }

    func refreshSummary() async {
        await summary.refresh { [api, courseId] in
            try await api.ifAllowed(MoodleCourseSummaryService.coursesFunction, else: .empty) { try await api.summary(courseId) }
        }
    }
}
