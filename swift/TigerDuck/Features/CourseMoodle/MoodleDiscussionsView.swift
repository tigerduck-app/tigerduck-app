import SwiftUI

/// A forum's discussions as cards, pinned ones first, the next page loading at the end of the
/// list. Opening one is what tells Moodle it was read; the list never does.
struct MoodleDiscussionsView: View {
    let pages: MoodleDiscussionPages
    let title: String
    let page: MoodlePage?
    /// A forum's discussions end with their author and reply count; announcements do not.
    var showsFooter = false
    let open: (MoodleDiscussion) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let list = pages.list {
                let discussions = list.sorted(by: pages.date)
                ForEach(discussions) { discussion in
                    Button {
                        open(discussion)
                    } label: {
                        MoodleDiscussionCard(
                            discussion: discussion,
                            date: discussion[keyPath: pages.date],
                            policy: appState.visualStylePolicy,
                            showsFooter: showsFooter
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
                            await pages.loadMore(after: discussion.id)
                        }
                    }
                }
                if pages.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else if let failure = pages.pageFailure, list.hasMore {
                    pageRetry(failure, after: discussions.last?.id)
                }
            } else {
                MoodleFirstLoadView(
                    failure: pages.feed.isRefreshing ? nil : pages.feed.failure,
                    retry: { await pages.refresh() }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .refreshable { await pages.refresh() }
        .moodleListChrome(
            title: title,
            status: pages.feed.status,
            isLoading: pages.feed.isRefreshing,
            page: page,
            refresh: { await pages.refresh() }
        )
        .moodleAutoRefresh(every: pages.feed.ttl, fetchedAt: { pages.fetchedAt }) {
            await pages.refresh()
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
                Task { await pages.loadMore(after: lastId) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
