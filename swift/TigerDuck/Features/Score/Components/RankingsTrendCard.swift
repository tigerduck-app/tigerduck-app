import SwiftUI
import Charts

/// Swift Charts line chart showing GPA evolution across semesters. A picker
/// toggles between the per-semester and cumulative views since they answer
/// different questions ("how did I do last term" vs. "how am I trending").
struct RankingsTrendCard: View {
    @Environment(AppState.self) private var appState

    let rankings: [SemesterRanking]
    @Binding var scope: ScoreViewModel.RankingScope

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
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

            if rankings.isEmpty {
                Text("尚無排名資料")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, TigerDuckTheme.Spacing.lg)
            } else {
                chart
                if let latest = rankings.last {
                    latestSummary(latest)
                }
            }
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var chart: some View {
        Chart(rankings) { ranking in
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
                .symbolSize(64)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 160)
    }

    private func latestSummary(_ latest: SemesterRanking) -> some View {
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            summaryCell(title: "最新 GPA", value: formatGPA(gpa(for: latest)))
            summaryCell(title: "班排名", value: formatRank(rank(for: latest).classRank))
            summaryCell(title: "系排名", value: formatRank(rank(for: latest).deptRank))
            Spacer()
        }
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

    // MARK: - Helpers

    private func gpa(for ranking: SemesterRanking) -> Double? {
        rank(for: ranking).gpa
    }

    private func rank(for ranking: SemesterRanking) -> RankingStats {
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
}
