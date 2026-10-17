import SwiftUI

struct MoodleForumsView: View {
    let store: MoodleCourseStore
    let open: (MoodleCourseRoute) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            if store.forumsFetchedAt == nil {
                MoodleFirstLoadView(
                    failure: store.forums.isRefreshing ? nil : store.forums.failure,
                    retry: { await store.refreshForums() }
                )
            } else if !store.generalForums.isEmpty {
                forumCard(store.generalForums)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.vertical, TigerDuckTheme.Spacing.xs)
            }
        }
        .background(Color.backgroundPrimary)
        .refreshable { await store.refreshForums() }
        .moodleRefreshFailureNote(store.forums)
        .moodleListChrome(
            title: String(localized: "course_detail_forums_label"),
            page: .forums(courseId: store.courseId),
            refresh: { await store.refreshForums() }
        )
        .moodleAutoRefresh(every: store.forums.ttl, fetchedAt: { store.forumsFetchedAt }) {
            await store.refreshForums()
        }
    }

    private func forumCard(_ forums: [MoodleForum]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(forums.enumerated()), id: \.element.id) { index, forum in
                if index > 0 {
                    Divider().padding(.leading, MoodleCountRow.textInset)
                }
                Button {
                    open(.forum(forum))
                } label: {
                    MoodleCountRow(
                        icon: "bubble.left.and.bubble.right",
                        title: forum.name,
                        subtitle: forum.intro,
                        count: forum.discussionCount,
                        hasUnread: forum.unreadPostCount > 0
                    )
                }
                .buttonStyle(.plain)
                .moodleRowHover()
            }
        }
        .presetCard(policy: appState.visualStylePolicy)
    }
}

struct MoodleForumView: View {
    let store: MoodleCourseStore
    let forum: MoodleForum
    let open: (MoodleCourseRoute) -> Void

    var body: some View {
        MoodleDiscussionsView(
            pages: store.discussions(of: forum),
            title: forum.name,
            page: .forum(cmid: forum.cmid),
            showsFooter: true
        ) { open(.discussion($0, in: forum)) }
    }
}
