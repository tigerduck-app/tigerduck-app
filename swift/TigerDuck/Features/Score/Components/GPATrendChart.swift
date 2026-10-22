import SwiftUI
import Charts

struct GPATrendChart: View {
    let points: [GPATrendPoint]
    let scope: ScoreViewModel.RankingScope

    @State private var selectedTerm: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineColor = TintShapeStyle()

    #if os(macOS)
    private let primaryText = Color.primary
    private let secondaryText = Color.secondary
    private let ringFill = Color.secondarySystemGroupedBackgroundCompat
    #else
    private let primaryText = Color.textPrimary
    private let secondaryText = Color.textSecondary
    private let ringFill = Color.backgroundPrimary
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            chart
            summaryRow(for: resolvedSelection)
        }
        .onChange(of: points.map(\.term)) { _, newTerms in
            if let term = selectedTerm, !newTerms.contains(term) {
                selectedTerm = nil
            }
        }
    }

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
                    .foregroundStyle(secondaryText.opacity(0.35))
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
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                selectTerm(
                                    at: drag.location,
                                    proxy: proxy,
                                    geometry: geo
                                )
                            }
                    )
                    #if os(macOS)
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            selectTerm(at: location, proxy: proxy, geometry: geo)
                        }
                    }
                    #endif
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

    @ViewBuilder
    private func symbol(for point: GPATrendPoint) -> some View {
        let size: CGFloat = isSelected(point.term) ? 14 : 9
        if point.isProvisional {
            Circle()
                .strokeBorder(lineColor, lineWidth: 2)
                .background(Circle().fill(ringFill))
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(lineColor)
                .frame(width: size, height: size)
        }
    }

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
        .animation(Self.summaryAnimation(reduceMotion: reduceMotion), value: selectedTerm)
        .animation(Self.summaryAnimation(reduceMotion: reduceMotion), value: scope)
    }

    static func summaryAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smoothSpring
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
                .foregroundStyle(secondaryText)
            Text(value)
                .font(TigerDuckTheme.Typography.headline.monospacedDigit())
                .foregroundStyle(primaryText)
        }
    }

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
