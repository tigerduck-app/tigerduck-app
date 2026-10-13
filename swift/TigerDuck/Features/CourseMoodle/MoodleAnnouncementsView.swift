import SwiftUI

/// A course's announcements, from its news forum on Moodle: pinned ones first, then newest first.
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
            // The forums no longer name a news forum: what they say, and a way to ask again.
            MoodleFirstLoadView(
                failure: store.forums.isRefreshing ? nil : store.forums.failure,
                retry: { await store.refreshForums() }
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.backgroundPrimary)
            .moodleListChrome(
                title: String(localized: "feature_announcements"),
                status: store.forums.status,
                isLoading: store.forums.isRefreshing,
                page: nil,
                refresh: { await store.refreshForums() }
            )
        }
    }
}
