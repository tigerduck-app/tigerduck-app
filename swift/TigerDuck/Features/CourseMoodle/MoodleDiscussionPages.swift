import Foundation
import Observation

@Observable
@MainActor
final class MoodleDiscussionPages {
    let forumId: Int
    let feed: MoodleFeed<MoodleDiscussionList>
    let date: KeyPath<MoodleDiscussion, Date>
    private(set) var isLoadingMore = false
    private(set) var pageFailure: (any Error)?

    @ObservationIgnored private let forums: MoodleFeed<MoodleTermForums>
    @ObservationIgnored private let api: MoodleCourseAPI
    @ObservationIgnored private var listWork: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(
        forumId: Int,
        feed: MoodleFeed<MoodleDiscussionList>,
        date: KeyPath<MoodleDiscussion, Date>,
        forums: MoodleFeed<MoodleTermForums>,
        api: MoodleCourseAPI
    ) {
        self.forumId = forumId
        self.feed = feed
        self.date = date
        self.forums = forums
        self.api = api
    }

    var list: MoodleDiscussionList? {
        guard let list = feed.value, list.forumId == forumId else { return nil }
        return list
    }

    var fetchedAt: Date? {
        list == nil ? nil : feed.fetchedAt
    }

    func refresh() async {
        if let refreshing {
            await refreshing.value
            return
        }
        let task = Task { await refreshInTurn() }
        refreshing = task
        await task.value
        if refreshing == task { refreshing = nil }
    }

    private func refreshInTurn() async {
        await serially { [self] in
            let pages = max(1, list?.pageCount ?? 1)
            await feed.refresh { [api, forumId] in
                var list = MoodleDiscussionList(forumId: forumId, discussions: [], pageCount: 0, hasMore: false)
                guard try await api.functions().contains(MoodleForumService.discussionsFunction) else { return list }
                repeat {
                    list.append(page: try await api.discussions(forumId, list.pageCount))
                } while list.hasMore && list.pageCount < pages
                return list
            }
            guard feed.status == .ok, let list, !list.hasMore else { return }
            pageFailure = nil
            forums.update { term in
                guard let index = term.forums.firstIndex(where: { $0.id == forumId }) else { return }
                term.forums[index].discussionCount = list.discussions.count
                term.forums[index].unreadPostCount = list.discussions.reduce(0) { $0 + $1.unreadCount }
            }
        }
    }

    func loadMore(after lastId: Int?) async {
        await serially { [self] in
            guard let list, list.hasMore, lastId == list.sorted(by: date).last?.id else { return }
            isLoadingMore = true
            defer { isLoadingMore = false }
            do {
                guard try await api.functions().contains(MoodleForumService.discussionsFunction) else {
                    pageFailure = nil
                    feed.update { $0.hasMore = false }
                    return
                }
                let page = try await api.discussions(forumId, list.pageCount)
                pageFailure = nil
                feed.update { current in
                    guard current.forumId == list.forumId, current.pageCount == list.pageCount else { return }
                    current.append(page: page)
                }
            } catch {
                pageFailure = error
            }
        }
    }

    func markRead(_ discussionId: Int) {
        let unread = list?.discussions.first { $0.id == discussionId }?.unreadCount ?? 0
        guard unread > 0 else { return }
        feed.update { list in
            guard let index = list.discussions.firstIndex(where: { $0.id == discussionId }) else { return }
            list.discussions[index].unreadCount = 0
        }
        forums.update { term in
            guard let index = term.forums.firstIndex(where: { $0.id == forumId }) else { return }
            term.forums[index].unreadPostCount = max(0, term.forums[index].unreadPostCount - unread)
        }
    }

    private func serially(_ work: @escaping @MainActor () async -> Void) async {
        let previous = listWork
        let task = Task {
            await previous?.value
            await work()
        }
        listWork = task
        await task.value
    }
}
