#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacScoreView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var viewModel = ScoreViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let err = viewModel.errorMessage {
                    errorBanner(err)
                }
                if !viewModel.hasContent && viewModel.isRefreshing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if !viewModel.hasContent {
                    emptyState
                } else {
                    trendCard
                    semesterSections
                }
            }
            .macReadableContent(maxWidth: MacContentWidth.standard)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker(String(localized: "desktop_score_ranking_scope_label"), selection: $viewModel.rankingScope) {
                    ForEach(ScoreViewModel.RankingScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .help(String(localized: "desktop_score_ranking_scope_help"))
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    SyncStatusDot(servers: ServerKind.transcriptSources, lastSynced: .at(viewModel.cachedAt))
                    Button {
                        Task { await viewModel.refresh(authService: app.authService, force: true) }
                    } label: {
                        if viewModel.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(String(localized: "desktop_action_refresh"), systemImage: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(viewModel.isRefreshing)
                    .help(String(localized: "desktop_score_refresh_help"))
                }
            }
        }
        .task {
            viewModel.load(authService: app.authService)
        }
        .onChange(of: app.authService.session.ticket) {
            viewModel.load(authService: app.authService)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "desktop_score_title"))
                    .font(.title2.bold())
                if let cached = viewModel.cachedAt {
                    Text(String(format: String(localized: "desktop_score_cached_value"), cached.formatted(.relative(presentation: .named))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var trendCard: some View {
        if !viewModel.gpaTrend.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "score_gpa_trend_title"))
                    .font(.title3.bold())
                GPATrendChart(points: viewModel.gpaTrend, scope: viewModel.rankingScope)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                    .fill(Color.secondarySystemGroupedBackgroundCompat)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(String(localized: "desktop_score_empty_title"))
                .font(.headline)
            Text(String(localized: "desktop_score_empty_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
    }

    @ViewBuilder
    private var semesterSections: some View {
        ForEach(viewModel.groupedCourses, id: \.term) { group in
            MacScoreTermCard(viewModel: viewModel, term: group.term, courses: group.courses)
        }
    }
}
#endif
