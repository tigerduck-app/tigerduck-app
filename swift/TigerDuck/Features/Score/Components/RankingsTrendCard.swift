import SwiftUI
import Charts

/// Swift Charts line chart showing GPA evolution across semesters. A picker
/// toggles between the per-semester and cumulative views since they answer
/// different questions ("how did I do last term" vs. "how am I trending").
///
/// Tapping or dragging across the chart selects the nearest term and surfaces
/// the full rank stat line (GPA + class rank + dept rank) in a summary row
/// beneath the plot; the selection marker is a vertical `RuleMark` so users
/// never lose track of which point they're inspecting.
struct RankingsTrendCard: View {
    @Environment(AppState.self) private var appState

    let rankings: [SemesterRanking]
    @Binding var scope: ScoreViewModel.RankingScope

    @State private var selectedTerm: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            header

            if rankings.isEmpty {
                Text("尚無排名資料")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, TigerDuckTheme.Spacing.lg)
            } else {
                chart
                summaryRow(for: resolvedSelection)
            }
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .onChange(of: scope) { _, _ in
            // Re-pin selection; the highlighted term stays the same but its
            // stat line changes when switching semester↔cumulative.
        }
    }

    private var header: some View {
        HStack {
            Text("GPA 趨勢")
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Picker("Scope", selection: $scope) {
                ForEach(ScoreViewModel.RankingScope.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(rankings) { ranking in
                if let value = gpa(for: ranking) {
                    LineMark(
                        x: .value("學期", ranking.term),
                        y: .value("GPA", value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color(hex: 0x4ECDC4))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    PointMark(
                        x: .value("學期", ranking.term),
                        y: .value("GPA", value)
                    )
                    .foregroundStyle(Color(hex: 0x4ECDC4))
                    .symbolSize(isSelected(ranking.term) ? 160 : 64)
                }
            }

            if let selected = resolvedSelection,
               let value = gpa(for: selected) {
                RuleMark(x: .value("學期", selected.term))
                    .foregroundStyle(Color.textSecondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("學期", selected.term),
                    y: .value("GPA", value)
                )
                .foregroundStyle(Color.white)
                .symbolSize(60)
                .zIndex(10)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartXSelection(value: $selectedTerm)
        .frame(height: 160)
    }

    @ViewBuilder
    private func summaryRow(for ranking: SemesterRanking?) -> some View {
        let source = ranking ?? rankings.last
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            summaryCell(
                title: selectedTerm != nil ? "\(displayTerm(source?.term ?? "")) GPA" : "最新 GPA",
                value: formatGPA(source.flatMap(gpa))
            )
            summaryCell(
                title: "班排名",
                value: formatRank(source.map(rank)?.classRank)
            )
            summaryCell(
                title: "系排名",
                value: formatRank(source.map(rank)?.deptRank)
            )
            Spacer()
        }
        .contentTransition(.numericText())
        .animation(.smoothSpring, value: selectedTerm)
    }

    private func summaryCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TigerDuckTheme.Typography.caption2)
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(TigerDuckTheme.Typography.headline.monospacedDigit())
                .foregroundStyle(Color.textPrimary)
        }
    }

    // MARK: - Selection resolution

    /// Ranking row matching the term the user dragged to, falling back to the
    /// most recent entry so the summary row is never blank.
    private var resolvedSelection: SemesterRanking? {
        if let term = selectedTerm,
           let match = rankings.first(where: { $0.term == term }) {
            return match
        }
        return rankings.last
    }

    private func isSelected(_ term: String) -> Bool {
        selectedTerm == term
    }

    // MARK: - Helpers

    private func gpa(for ranking: SemesterRanking) -> Double? {
        rank(ranking).gpa
    }

    private func rank(_ ranking: SemesterRanking) -> RankingStats {
        switch scope {
        case .semester:   return ranking.semester
        case .cumulative: return ranking.cumulative
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = rankings.compactMap { gpa(for: $0) }
        guard let minV = values.min(), let maxV = values.max() else {
            return 0...4.3
        }
        let lower = max(0, minV - 0.3)
        let upper = min(4.3, maxV + 0.3)
        return lower...upper
    }

    private func formatGPA(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func formatRank(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func displayTerm(_ code: String) -> String {
        guard code.count == 4 else { return code }
        let year = String(code.prefix(3))
        let sem = String(code.suffix(1))
        let label = sem == "1" ? "上" : sem == "2" ? "下" : sem
        return "\(year)-\(label)"
    }
}
