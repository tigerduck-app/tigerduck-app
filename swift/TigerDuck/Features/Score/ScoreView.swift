import SwiftUI

struct ScoreView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = ScoreViewModel()
    @State private var selectedCourse: CourseGrade?

    var body: some View {
        if embedded {
            content
                .onAppear { viewModel.load(authService: appState.authService) }
        } else {
            NavigationStack { content }
                .onAppear { viewModel.load(authService: appState.authService) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                titleBar

                if let reauthError = appState.ntustReauthErrorMessage {
                    NTUSTReauthErrorBanner(
                        message: reauthError,
                        onRetry: {
                            appState.clearNTUSTReauthError()
                            appState.presentNTUSTLogin()
                        },
                        onDismiss: { appState.clearNTUSTReauthError() }
                    )
                }

                switch pageAccessState {
                case .loginRequired:
                    LoginRequiredView(
                        layout: .page,
                        title: String(localized: "common_not_signed_in"),
                        message: String(localized: "score_sign_in_required_message"),
                        onPrimary: { appState.presentNTUSTLogin() }
                    )
                case .empty:
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: String(localized: "score_empty_title"),
                        message: String(localized: "score_empty_pull_to_refresh")
                    )
                    .padding(.vertical, TigerDuckTheme.Spacing.xxl)
                case .content:
                    authenticatedContent
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable {
            // Fire-and-forget: pull gesture dismisses UIRefreshControl
            // immediately; live progress moves to the top-right
            // NetworkStatusOverlay like other pages in the app.
            viewModel.triggerRefresh(authService: appState.authService)
        }
        .sheet(item: $selectedCourse) { course in
            ScoreCourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    private var pageAccessState: NTUSTProtectedAccessState {
        appState.ntustProtectedAccessState(isEmpty: !viewModel.hasContent)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_score"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState, isLocalOnly: appState.isSyncLocalOnly)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        StudentHeaderCard(
            student: viewModel.report.student,
            currentTerm: viewModel.report.currentTerm
        )

        CreditSummaryBento(summary: viewModel.report.creditSummary)

        RankingsTrendCard(
            rankings: viewModel.rankingTrend,
            scope: Binding(
                get: { viewModel.rankingScope },
                set: { viewModel.rankingScope = $0 }
            )
        )

        LazyVStack(spacing: TigerDuckTheme.Spacing.md) {
            ForEach(viewModel.groupedCourses, id: \.term) { group in
                SemesterSection(
                    term: group.term,
                    courses: group.courses,
                    ranking: viewModel.ranking(for: group.term),
                    isCollapsed: viewModel.isCollapsed(term: group.term),
                    onToggle: {
                        withAnimation(.smoothSpring) {
                            viewModel.toggleCollapse(term: group.term)
                        }
                    },
                    onCourseTap: { selectedCourse = $0 }
                )
            }
        }
    }
}
