import SwiftUI

struct MoodleAnnouncementsView: View {
    let store: MoodleCourseStore
    let open: (MoodleCourseRoute) -> Void

    var body: some View {
        if let pages = store.announcementPages {
            MoodleDiscussionsView(
                pages: pages,
                title: String(localized: "feature_announcements"),
                page: store.newsForum.map { MoodlePage.forum(cmid: $0.cmid) }
            ) { open(.announcement($0)) }
        } else {
            ScrollView {
                if store.forumsFetchedAt == nil {
                    MoodleFirstLoadView(
                        failure: store.forums.isRefreshing ? nil : store.forums.failure,
                        retry: { await store.refreshForums() }
                    )
                }
            }
            .background(Color.backgroundPrimary)
            .refreshable { await store.refreshForums() }
            .moodleListChrome(
                title: String(localized: "feature_announcements"),
                page: nil,
                refresh: { await store.refreshForums() }
            )
            .moodleAutoRefresh(every: store.forums.ttl, fetchedAt: { store.forumsFetchedAt }) {
                await store.refreshForums()
            }
        }
    }
}
