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
                        title: "尚未登入",
                        message: "尚未登入，無法查看歷年成績",
                        onPrimary: { appState.presentNTUSTLogin() }
                    )
                case .empty:
                    EmptyStateView(
                        icon: "doc.text.magnifyingglass",
                        title: "沒有成績資料",
                        message: "下拉以重新整理，或稍後再試"
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
            await viewModel.refresh(authService: appState.authService)
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
            Text("歷年成績")
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
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
