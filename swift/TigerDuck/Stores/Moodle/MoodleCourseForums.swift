import Foundation

@MainActor
final class MoodleCourseForums {
    private let courseId: Int
    private let termCourseIds: [Int]
    private let forums: MoodleFeed<MoodleTermForums>
    private let api: MoodleCourseAPI
    private let context: MoodleCacheContext
    private var discussionPages: [Int: MoodleDiscussionPages] = [:]
    private var threads: [Int: MoodleFeed<MoodleDiscussionThread>] = [:]

    init(
        courseId: Int, termCourseIds: [Int], forums: MoodleFeed<MoodleTermForums>, api: MoodleCourseAPI,
        context: MoodleCacheContext
    ) {
        self.courseId = courseId
        self.termCourseIds = termCourseIds
        self.forums = forums
        self.api = api
        self.context = context
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

    func refreshForums() async {
        await forums.refresh { [api, termCourseIds] in
            let functions = try await api.functions()
            guard functions.isSuperset(of: MoodleCourseStore.forumFunctions) else {
                return MoodleTermForums(courseIds: termCourseIds, forums: [])
            }
            let all = try await api.forums(termCourseIds)
            return MoodleTermForums(courseIds: termCourseIds, forums: Self.shown(all, allowedFunctions: functions))
        }
    }

    private nonisolated static func shown(_ forums: [MoodleForum], allowedFunctions: Set<String>) -> [MoodleForum] {
        allowedFunctions.contains(MoodleForumService.discussionPostsFunction) ? forums : forums.filter(\.isNews)
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

    func refreshThread(of discussion: MoodleDiscussion) async {
        await thread(of: discussion).refresh { [api] in
            MoodleDiscussionThread(
                discussionId: discussion.id,
                posts: try await api.ifAllowed(MoodleForumService.discussionPostsFunction, else: []) {
                    try await api.posts(discussion.id)
                }
            )
        }
    }

    @discardableResult
    func open(_ discussion: MoodleDiscussion, in forum: MoodleForum?) -> Task<Void, Never> {
        guard context.signIn.isCurrent, !Task.isCancelled else { return Task {} }
        if let forum { discussions(of: forum).markRead(discussion.id) }
        if let thread = threads[discussion.id], thread.value?.posts.contains(where: \.isUnread) == true {
            thread.applyUserEdit { value in
                for index in value.posts.indices { value.posts[index].isUnread = false }
            }
        }
        return Task { [api, context] in
            guard context.signIn.isCurrent, !Task.isCancelled else { return }
            guard (try? await api.functions())?.contains(MoodleForumService.viewDiscussionFunction) == true else { return }
            guard context.signIn.isCurrent, !Task.isCancelled else { return }
            do {
                try await api.markViewed(discussion.id, context.signIn)
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
        guard context.signIn.isCurrent, !Task.isCancelled else { return nil }
        let feed = thread(of: discussion)
        await refreshThread(of: discussion)
        guard context.signIn.isCurrent, !Task.isCancelled, isShown(),
              feed.status == .ok, let posts = feed.value?.posts else {
            return nil
        }
        let unread = Set(posts.filter(\.isUnread).map(\.id))
        open(discussion, in: forum)
        return unread
    }
}
