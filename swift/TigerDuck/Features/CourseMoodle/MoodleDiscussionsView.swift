import SwiftUI

nonisolated extension MoodleDiscussion {
    static func matching(_ query: String, in discussions: [MoodleDiscussion]) -> [MoodleDiscussion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return discussions }
        return discussions.filter { discussion in
            [discussion.title, discussion.preview, discussion.authorName.map(MoodlePersonName.displayName)]
                .contains { $0?.localizedStandardContains(needle) == true }
        }
    }
}

struct MoodleDiscussionsView: View {
    let pages: MoodleDiscussionPages
    let title: String
    let page: MoodlePage?
    let policy: VisualStylePolicy
    var showsFooter = false
    let open: (MoodleDiscussion) -> Void

    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @State private var isSearchRevealed = false
    #endif

    var body: some View {
        List {
            if let list = pages.list {
                searchRow
                let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let discussions = MoodleDiscussion.matching(needle, in: list.sorted(by: pages.date))
                if discussions.isEmpty, !needle.isEmpty {
                    ContentUnavailableView.search(text: needle)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(discussions) { discussion in
                    Button {
                        open(discussion)
                    } label: {
                        MoodleDiscussionCard(
                            discussion: discussion,
                            date: discussion[keyPath: pages.date],
                            policy: policy,
                            showsFooter: showsFooter
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.rowInsets)
                    .contextMenu {
                        Button {
                            Task { await openURL(MoodlePage.discussion(discussion.id)) }
                        } label: {
                            Label(String(localized: "action_open_in_moodle"), systemImage: "arrow.up.right.square")
                        }
                    }
                    .task {
                        if needle.isEmpty, discussion.id == discussions.last?.id {
                            await pages.loadMore(after: discussion.id)
                        }
                    }
                }
                if needle.isEmpty {
                    pageFooter(list, after: discussions.last?.id)
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
        #if os(iOS)
        .pullToRevealSearch(isRevealed: $isSearchRevealed, isActive: isSearchFocused || !query.isEmpty)
        #endif
        .refreshable { await pages.refresh() }
        .moodleRefreshFailureNote(pages.feed, hasContent: pages.list != nil)
        .moodleListChrome(
            title: title,
            page: page,
            refresh: { await pages.refresh() }
        )
        .moodleAutoRefresh(every: pages.feed.ttl, fetchedAt: { pages.fetchedAt }) {
            await pages.refresh()
        }
    }

    private static let rowInsets = EdgeInsets(
        top: TigerDuckTheme.Spacing.xs, leading: TigerDuckTheme.Spacing.lg,
        bottom: TigerDuckTheme.Spacing.xs, trailing: TigerDuckTheme.Spacing.lg
    )

    @ViewBuilder
    private var searchRow: some View {
        #if os(iOS)
        let isShown = isSearchRevealed || !query.isEmpty
        #else
        let isShown = true
        #endif
        if isShown {
            MoodleSearchField(query: $query, isFocused: $isSearchFocused)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(Self.rowInsets)
        }
    }

    @ViewBuilder
    private func pageFooter(_ list: MoodleDiscussionList, after lastId: Int?) -> some View {
        if pages.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if let failure = pages.pageFailure, list.hasMore {
            pageRetry(failure, after: lastId)
        }
    }

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
