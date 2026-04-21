import SwiftUI
import Charts

/// Swift Charts line chart showing GPA evolution across semesters. A picker
/// toggles between the per-semester and cumulative views since they answer
/// different questions ("how did I do last term" vs. "how am I trending").
///
/// Selection is sticky — tapping or dragging picks the nearest term and the
/// highlight survives after the finger lifts, so users can freely compare
/// the chart with other cards on the page. The summary row below the plot
/// renders the GPA / class rank / dept rank of whichever point is pinned.
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance: 0 promotes a single tap into the
                        // same handler used for drags, so the card reacts to
                        // either input style without a separate
                        // SpatialTapGesture. The absence of an onEnded
                        // handler is intentional: the last-known selection
                        // stays pinned after the finger lifts.
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                selectTerm(
                                    at: drag.location,
                                    proxy: proxy,
                                    geometry: geo
                                )
                            }
                    )
            }
        }
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

    /// Map a tap/drag location to the closest ranking term by plot-area
    /// proportion. Using index math instead of `proxy.value(atX:)` keeps this
    /// robust against Swift Charts' categorical-axis quirks (which return
    /// nil at the padding edges and the zero-midpoint between points).
    private func selectTerm(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard !rankings.isEmpty else { return }
        guard let plotFrame = proxy.plotFrame else { return }

        let plotRect = geometry[plotFrame]
        let relativeX = point.x - plotRect.origin.x
        let clampedX = max(0, min(plotRect.width, relativeX))
        let ratio = plotRect.width > 0 ? clampedX / plotRect.width : 0
        let index = Int((ratio * CGFloat(rankings.count - 1)).rounded())
        let clampedIndex = max(0, min(rankings.count - 1, index))
        selectedTerm = rankings[clampedIndex].term
    }

    /// Ranking row matching the selected term, falling back to the most
    /// recent entry so the summary row is never blank before first tap.
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
