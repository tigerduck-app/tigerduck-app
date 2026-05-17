#if os(macOS)
import SwiftUI

/// macOS Score (GPA) surface.
///
/// Reuses the cross-platform `ScoreViewModel` directly — its dependencies
/// (NTUSTScoreService, AuthService, ScoreReport models) are all
/// platform-agnostic. The Mac shell renders the same per-term grouping
/// the iPhone uses, expanded into wider cards with the per-row table
/// columns Mac users expect.
struct MacScoreView: View {
    @Environment(AppState.self) private var appState
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
                    semesterSections
                }
            }
            .macReadableContent(maxWidth: MacContentWidth.standard)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Ranking scope", selection: $viewModel.rankingScope) {
                    ForEach(ScoreViewModel.RankingScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .help("Toggle between per-semester and cumulative rank")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh(authService: appState.authService, force: true) }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isRefreshing)
                .help("Refresh from the NTUST score portal (⌘R)")
            }
        }
        .task {
            viewModel.load(authService: appState.authService)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Academic Record")
                    .font(.title2.bold())
                if let cached = viewModel.cachedAt {
                    Text("Cached \(cached, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let latest = viewModel.latestRanking {
                rankSummary(latest)
            }
        }
    }

    private func rankSummary(_ ranking: SemesterRanking) -> some View {
        let stats = viewModel.rankingScope == .semester ? ranking.semester : ranking.cumulative
        return HStack(spacing: 22) {
            statColumn(label: "GPA", value: stats.gpa.map { String(format: "%.2f", $0) } ?? "—")
            if let cls = stats.classRank {
                statColumn(label: "Class rank", value: "#\(cls)")
            }
            if let dep = stats.deptRank {
                statColumn(label: "Dept rank", value: "#\(dep)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.secondarySystemGroupedBackgroundCompat)
        )
    }

    private func statColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No score data yet")
                .font(.headline)
            Text("Hit Refresh (⌘R) to fetch your transcript from the NTUST score portal.")
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
            semesterCard(term: group.term, courses: group.courses)
        }
    }

    private func semesterCard(term: String, courses: [CourseGrade]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayTerm(term))
                    .font(.title3.bold())
                Spacer()
                if let ranking = viewModel.ranking(for: term) {
                    let stats = viewModel.rankingScope == .semester ? ranking.semester : ranking.cumulative
                    HStack(spacing: 12) {
                        if let gpa = stats.gpa {
                            Text("GPA \(String(format: "%.2f", gpa))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let cls = stats.classRank {
                            Text("#\(cls)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            tableHeader

            VStack(spacing: 0) {
                ForEach(courses) { course in
                    courseRow(course)
                    if course.id != courses.last?.id {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                    .fill(Color.secondarySystemGroupedBackgroundCompat)
            )
        }
        .padding(.bottom, 8)
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Course")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Credits")
                .frame(width: 64, alignment: .trailing)
            Text("Grade")
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }

    private func courseRow(_ course: CourseGrade) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(course.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    if !course.remark.isEmpty {
                        Text(course.remark)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(course.credits.map { "\($0)" } ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)

            Text(course.grade.isEmpty ? "—" : course.grade)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(course.isPassStatusPassed ? Color.primary : Color.red)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Map NTUST term codes ("1131") to a friendlier "113 學年 第 1 學期".
    private func displayTerm(_ raw: String) -> String {
        guard raw.count == 4 else { return raw }
        let year = String(raw.prefix(3))
        let sem = String(raw.suffix(1))
        return "\(year) Academic Year · Semester \(sem)"
    }
}
#endif
