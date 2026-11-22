import SwiftUI

struct ScoreView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app
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
                    ScoreTranscript(viewModel: viewModel, policy: app.preferences.visualStylePolicy) { selectedCourse = $0 }
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
            ScoreCourseDetailSheet(course: course, policy: app.preferences.visualStylePolicy)
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
}

struct ScoreTranscript: View {
    let viewModel: ScoreViewModel
    let policy: VisualStylePolicy
    let onCourseTap: (CourseGrade) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StudentHeaderCard(student: viewModel.report.student, currentTerm: viewModel.report.currentTerm, policy: policy)

        CreditSummaryBento(summary: viewModel.report.creditSummary, policy: policy)

        RankingsTrendCard(
            points: viewModel.gpaTrend,
            scope: Binding(
                get: { viewModel.rankingScope },
                set: { viewModel.rankingScope = $0 }
            ),
            policy: policy
        )

        LazyVStack(spacing: TigerDuckTheme.Spacing.md) {
            ForEach(viewModel.groupedCourses, id: \.term) { group in
                SemesterSection(
                    term: group.term,
                    courses: group.courses,
                    gpaPoint: viewModel.gpaPoint(for: group.term),
                    isCollapsed: viewModel.isCollapsed(term: group.term),
                    policy: policy,
                    onToggle: {
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            viewModel.toggleCollapse(term: group.term)
                        }
                    },
                    onCourseTap: onCourseTap
                )
            }
        }
    }
}
