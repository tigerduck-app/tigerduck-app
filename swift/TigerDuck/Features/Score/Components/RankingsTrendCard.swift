import SwiftUI
import Charts

/// Swift Charts line chart showing GPA evolution across semesters. A picker
/// toggles between the per-semester and cumulative views since they answer
/// different questions ("how did I do last term" vs. "how am I trending").
///
/// Terms whose ranking the school has not posted yet still get a point —
/// the GPA computed from the grades in so far — drawn hollow at the end of
/// a dashed stretch so it reads as an estimate. Ranks for those terms are
/// simply absent.
///
/// Selection is sticky — tapping or dragging picks the nearest term and the
/// highlight survives after the finger lifts, so users can freely compare
/// the chart with other cards on the page. The summary row below the plot
/// renders the GPA / class rank / dept rank of whichever point is pinned.
struct RankingsTrendCard: View {
    @Environment(AppState.self) private var appState

    let points: [GPATrendPoint]
    @Binding var scope: ScoreViewModel.RankingScope

    @State private var selectedTerm: String?

    private let lineColor = Color(hex: 0x4ECDC4)

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            header

            if points.isEmpty {
                Text(String(localized: "score_no_ranking_data"))
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
        // Reset selection if the term it pointed to is gone after a refresh,
        // so the indicator/RuleMark doesn't silently point at a missing entry.
        .onChange(of: points.map(\.term)) { _, newTerms in
            if let term = selectedTerm, !newTerms.contains(term) {
                selectedTerm = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "score_gpa_trend_title"))
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

    // MARK: - Chart

    /// Consecutive published terms, split wherever a provisional term
    /// sits, so the solid line never bridges an estimate.
    private var publishedRuns: [[GPATrendPoint]] {
        var runs: [[GPATrendPoint]] = [[]]
        for point in points {
            if point.isProvisional {
                if !runs[runs.count - 1].isEmpty { runs.append([]) }
            } else {
                runs[runs.count - 1].append(point)
            }
        }
        return runs.filter { !$0.isEmpty }
    }

    /// Each provisional term paired with the point before it, so the dashed
    /// stretch continues the line into the estimate.
    private var provisionalSegments: [[GPATrendPoint]] {
        points.indices.compactMap { index in
            guard points[index].isProvisional else { return nil }
            return index > 0 ? [points[index - 1], points[index]] : [points[index]]
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(publishedRuns.enumerated()), id: \.offset) { run, segment in
                ForEach(segment) { point in
                    if let value = gpa(for: point) {
                        LineMark(x: xValue(point.term), y: yValue(value), series: .value("Series", "published-\(run)"))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(lineColor)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                }
            }

            ForEach(Array(provisionalSegments.enumerated()), id: \.offset) { run, segment in
                ForEach(segment) { point in
                    if let value = gpa(for: point) {
                        LineMark(x: xValue(point.term), y: yValue(value), series: .value("Series", "provisional-\(run)"))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(lineColor)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [5, 4]))
                    }
                }
            }

            ForEach(points) { point in
                if let value = gpa(for: point) {
                    PointMark(x: xValue(point.term), y: yValue(value))
                        .foregroundStyle(lineColor)
                        .symbol { symbol(for: point) }
                        .accessibilityLabel(Text(description(of: point, value: value)))
                }
            }

            if let selected = resolvedSelection,
               let value = gpa(for: selected) {
                RuleMark(x: xValue(selected.term))
                    .foregroundStyle(Color.textSecondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(x: xValue(selected.term), y: yValue(value))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "a11y_rankings_trend_chart")))
        .accessibilityValue(Text(currentSelectionDescription))
    }

    private func xValue(_ term: String) -> PlottableValue<String> {
        .value(String(localized: "class_table_semester_picker_label"), term)
    }

    private func yValue(_ gpa: Double) -> PlottableValue<Double> {
        .value("GPA", gpa)
    }

    /// Filled dot for a published term, hollow ring for an estimate; the
    /// pinned term grows either way.
    @ViewBuilder
    private func symbol(for point: GPATrendPoint) -> some View {
        let size: CGFloat = isSelected(point.term) ? 14 : 9
        if point.isProvisional {
            Circle()
                .strokeBorder(lineColor, lineWidth: 2)
                .background(Circle().fill(Color.backgroundPrimary))
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(lineColor)
                .frame(width: size, height: size)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryRow(for point: GPATrendPoint?) -> some View {
        let source = point ?? points.last
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            summaryCell(
                title: gpaTitle(for: source),
                value: formatGPA(source.flatMap(gpa))
            )
            summaryCell(
                title: String(localized: "score_rank_class"),
                value: formatRank(source.map(rank)?.classRank)
            )
            summaryCell(
                title: String(localized: "score_ranking_dept_label"),
                value: formatRank(source.map(rank)?.deptRank)
            )
            Spacer()
        }
        .contentTransition(.numericText())
        .animation(.smoothSpring, value: selectedTerm)
        .animation(.smoothSpring, value: scope)
    }

    private func gpaTitle(for point: GPATrendPoint?) -> String {
        let base = selectedTerm != nil
            ? String(format: String(localized: "score_gpa_term_label"), displayTerm(point?.term ?? ""))
            : String(localized: "score_gpa_latest")
        guard point?.isProvisional == true else { return base }
        return base + " · " + String(localized: "score_gpa_provisional")
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

    /// Map a tap/drag location to the closest term by plot-area
    /// proportion. Using index math instead of `proxy.value(atX:)` keeps this
    /// robust against Swift Charts' categorical-axis quirks (which return
    /// nil at the padding edges and the zero-midpoint between points).
    private func selectTerm(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard !points.isEmpty else { return }
        guard let plotFrame = proxy.plotFrame else { return }

        let plotRect = geometry[plotFrame]
        let relativeX = location.x - plotRect.origin.x
        let clampedX = max(0, min(plotRect.width, relativeX))
        let ratio = plotRect.width > 0 ? clampedX / plotRect.width : 0
        let index = Int((ratio * CGFloat(points.count - 1)).rounded())
        let clampedIndex = max(0, min(points.count - 1, index))
        selectedTerm = points[clampedIndex].term
    }

    /// Point matching the selected term, falling back to the most recent
    /// entry so the summary row is never blank before first tap.
    private var resolvedSelection: GPATrendPoint? {
        if let term = selectedTerm,
           let match = points.first(where: { $0.term == term }) {
            return match
        }
        return points.last
    }

    private func isSelected(_ term: String) -> Bool {
        selectedTerm == term
    }

    private var currentSelectionDescription: String {
        guard let selected = resolvedSelection,
              let value = gpa(for: selected) else {
            return String(localized: "a11y_rankings_trend_no_selection")
        }
        return description(of: selected, value: value)
    }

    private func description(of point: GPATrendPoint, value: Double) -> String {
        let base = String(
            format: String(localized: "a11y_rankings_trend_point"),
            point.term as CVarArg,
            value.formatted(.number.precision(.fractionLength(2))) as CVarArg
        )
        guard point.isProvisional else { return base }
        return base + " · " + String(localized: "score_gpa_provisional")
    }

    // MARK: - Helpers

    private func gpa(for point: GPATrendPoint) -> Double? {
        rank(point).gpa
    }

    private func rank(_ point: GPATrendPoint) -> RankingStats {
        switch scope {
        case .semester:   return point.semester
        case .cumulative: return point.cumulative
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.compactMap { gpa(for: $0) }
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
        let label = sem == "1"
            ? String(localized: "score_semester_first_short")
            : sem == "2"
                ? String(localized: "score_semester_second_short")
                : sem
        return "\(year)-\(label)"
    }
}
