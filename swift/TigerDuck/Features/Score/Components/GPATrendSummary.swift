import SwiftUI
import TigerDuckCore

struct GPATrendSummary: View {
    let point: GPATrendPoint?
    let isPicked: Bool
    let series: GPATrendSeries
    let primaryText: Color
    let secondaryText: Color

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.lg) {
            cell(title: gpaTitle, value: formatGPA(point.flatMap(series.gpa)))
            cell(
                title: String(localized: "score_rank_class"),
                value: formatRank(point.map(series.rank)?.classRank)
            )
            cell(
                title: String(localized: "score_ranking_dept_label"),
                value: formatRank(point.map(series.rank)?.deptRank)
            )
            Spacer()
        }
    }

    private var gpaTitle: String {
        let base = isPicked
            ? String(format: String(localized: "score_gpa_term_label"), displayTerm(point?.term ?? ""))
            : String(localized: "score_gpa_latest")
        guard point?.isProvisional == true else { return base }
        return base + " · " + String(localized: "score_gpa_provisional")
    }

    private func cell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TigerDuckTheme.Typography.caption2)
                .foregroundStyle(secondaryText)
            Text(value)
                .font(TigerDuckTheme.Typography.headline.monospacedDigit())
                .foregroundStyle(primaryText)
        }
    }

    private func formatGPA(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func formatRank(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func displayTerm(_ code: String) -> String {
        guard case let (year, sem)? = AcademicTerm.displayParts(of: code) else { return code }
        let label = sem == "1"
            ? String(localized: "score_semester_first_short")
            : sem == "2"
                ? String(localized: "score_semester_second_short")
                : sem
        return "\(year)-\(label)"
    }
}

struct GPATrendSeries {
    let points: [GPATrendPoint]
    let scope: ScoreViewModel.RankingScope

    var publishedRuns: [[GPATrendPoint]] {
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

    var provisionalSegments: [[GPATrendPoint]] {
        points.indices.compactMap { index in
            guard points[index].isProvisional else { return nil }
            return index > 0 ? [points[index - 1], points[index]] : [points[index]]
        }
    }

    var yDomain: ClosedRange<Double> {
        let values = points.compactMap { gpa(for: $0) }
        guard let minV = values.min(), let maxV = values.max() else {
            return 0...4.3
        }
        let lower = max(0, minV - 0.3)
        let upper = min(4.3, maxV + 0.3)
        return lower...upper
    }

    func gpa(for point: GPATrendPoint) -> Double? {
        rank(point).gpa
    }

    func rank(_ point: GPATrendPoint) -> RankingStats {
        switch scope {
        case .semester:   return point.semester
        case .cumulative: return point.cumulative
        }
    }
}
