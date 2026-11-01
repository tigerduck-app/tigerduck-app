import SwiftUI

struct ScoreView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = ScoreViewModel()
    @State private var selectedCourse: CourseGrade?

    var body: some View {
        if embedded {
            content
                .onAppear { viewModel.load(authService: app.authService) }
                .onChange(of: app.authService.session.currentSignIn) { viewModel.load(authService: app.authService) }
        } else {
            NavigationStack { content }
                .onAppear { viewModel.load(authService: app.authService) }
                .onChange(of: app.authService.session.currentSignIn) { viewModel.load(authService: app.authService) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                titleBar

                if let reauthError = app.authService.reauthErrorMessage {
                    NTUSTReauthErrorBanner(
                        message: reauthError,
                        onRetry: {
                            app.authService.clearReauthError()
                            app.router.presentNTUSTLogin()
                        },
                        onDismiss: { app.authService.clearReauthError() }
                    )
                }

                switch pageAccessState {
                case .loginRequired:
                    LoginRequiredView(
                        layout: .page,
                        title: String(localized: "common_not_signed_in"),
                        message: String(localized: "score_sign_in_required_message"),
                        onPrimary: { app.router.presentNTUSTLogin() }
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
            viewModel.triggerRefresh(authService: app.authService)
        }
        .sheet(item: $selectedCourse) { course in
            ScoreCourseDetailSheet(course: course)
                .presentationDetents([.medium, .large])
        }
    }

    private var pageAccessState: NTUSTProtectedAccessState {
        NTUSTProtectedAccessState(signedIn: app.authService.hasStoredCredentials, isEmpty: !viewModel.hasContent)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_score"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            SyncStatusDot(servers: ServerKind.transcriptSources, lastSynced: .at(viewModel.cachedAt))
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
            points: viewModel.gpaTrend,
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
                    gpaPoint: viewModel.gpaPoint(for: group.term),
                    isCollapsed: viewModel.isCollapsed(term: group.term),
                    onToggle: {
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            viewModel.toggleCollapse(term: group.term)
                        }
                    },
                    onCourseTap: { selectedCourse = $0 }
                )
            }
        }
    }
}
