import SwiftUI

struct AnnouncementsView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = AnnouncementsViewModel()
    @State private var showSearch = false

    var body: some View {
        if embedded {
            content
                .onAppear { viewModel.load(appState: appState) }
        } else {
            NavigationStack { content }
                .onAppear { viewModel.load(appState: appState) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                HStack {
                    Text("公告")
                        .font(TigerDuckTheme.Typography.title)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Button {
                        withAnimation(.smoothSpring) {
                            showSearch.toggle()
                            if !showSearch { viewModel.searchText = "" }
                        }
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.top, TigerDuckTheme.Spacing.md)

                if showSearch {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.textSecondary)
                        TextField("搜尋公告", text: $viewModel.searchText)
                            .foregroundStyle(Color.textPrimary)
                    }
                    .presetSearchBarSurface(policy: appState.visualStylePolicy)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Filter chips
                FilterChipsView(
                    departments: viewModel.departments,
                    selected: viewModel.selectedDepartments,
                    onToggle: { viewModel.toggleDepartment($0, appState: appState) }
                )

                // Announcement cards
                if viewModel.filteredAnnouncements.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "沒有公告",
                        message: "稍後再回來查看"
                    )
                    .frame(height: 200)
                } else {
                    LazyVStack(spacing: TigerDuckTheme.Spacing.md) {
                        ForEach(viewModel.filteredAnnouncements, id: \.announcementId) { announcement in
                            NavigationLink {
                                AnnouncementDetailView(announcement: announcement)
                            } label: {
                                AnnouncementCardView(announcement: announcement)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }
}
