#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacScoreTermCard: View {
    let viewModel: ScoreViewModel
    let term: String
    let courses: [CourseGrade]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayTerm(term))
                    .font(.title3.bold())
                Spacer()
                if let point = viewModel.gpaPoint(for: term) {
                    let stats = viewModel.rankingScope == .semester ? point.semester : point.cumulative
                    HStack(spacing: 12) {
                        if let gpa = stats.gpa {
                            let provisional = point.isProvisional
                                ? " · " + String(localized: "score_gpa_provisional") : ""
                            Text(String(format: "GPA %.2f", gpa) + provisional)
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
            Text(String(localized: "desktop_score_course_column"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "course_detail_credits_label"))
                .frame(width: 64, alignment: .trailing)
            Text(String(localized: "desktop_score_grade_column"))
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

            Text(course.credits.map(\.creditsText) ?? "—")
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

    private func displayTerm(_ raw: String) -> String {
        guard case let (year, sem)? = AcademicTerm.displayParts(of: raw) else { return raw }
        return String(format: String(localized: "desktop_score_term_value"), year, sem)
    }
}
#endif
