import SwiftUI

/// A course's announcements, from its news forum on Moodle: pinned ones first, then newest first.
/// Opening one is what tells Moodle it was read; the list never does.
struct MoodleAnnouncementsView: View {
    let store: MoodleCourseStore
    let open: (MoodleCourseRoute) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let list = store.announcementList {
                let discussions = list.sorted
                ForEach(discussions) { discussion in
                    Button {
                        open(.announcement(discussion))
                    } label: {
                        MoodleDiscussionCard(
                            discussion: discussion, date: discussion.created, policy: appState.visualStylePolicy
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: TigerDuckTheme.Spacing.xs,
                        leading: TigerDuckTheme.Spacing.lg,
                        bottom: TigerDuckTheme.Spacing.xs,
                        trailing: TigerDuckTheme.Spacing.lg
                    ))
                    .contextMenu {
                        Button {
                            Task { await openURL(MoodlePage.discussion(discussion.id)) }
                        } label: {
                            Label(String(localized: "action_open_in_moodle"), systemImage: "arrow.up.right.square")
                        }
                    }
                    .task {
                        if discussion.id == discussions.last?.id {
                            await store.loadMoreAnnouncements(after: discussion.id)
                        }
                    }
                }
                if store.isLoadingMoreAnnouncements {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if let failure = store.announcementsPageFailure, list.hasMore {
                    pageRetry(failure, after: discussions.last?.id)
                }
            } else {
                MoodleFirstLoadView(
                    failure: store.announcements.isRefreshing ? nil : store.announcements.failure,
                    retry: { await store.refreshAnnouncements() }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .refreshable { await store.refreshAnnouncements() }
        .moodleListChrome(
            title: String(localized: "feature_announcements"),
            status: store.announcements.status,
            isLoading: store.announcements.isRefreshing,
            page: store.newsForum.map { MoodlePage.forum(cmid: $0.cmid) },
            refresh: { await store.refreshAnnouncements() }
        )
        .moodleAutoRefresh(every: MoodleRefreshInterval.announcements, fetchedAt: { store.announcementsFetchedAt }) {
            await store.refreshAnnouncements()
        }
    }

    /// The list's end when its next page failed, so a partial list does not pass for the whole.
    private func pageRetry(_ failure: any Error, after lastId: Int?) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Text(MoodleFirstLoadView.message(for: failure))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "action_retry")) {
                Task { await store.loadMoreAnnouncements(after: lastId) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
