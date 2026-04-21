import SwiftUI

/// Collapsible group of all courses from a single semester. The header shows
/// the term's GPA + class/dept rank pulled from `SemesterRanking` — keeping
/// the derived stat line here (instead of a separate tab) ties academic
/// context to the course list that produced it.
struct SemesterSection: View {
    @Environment(AppState.self) private var appState

    let term: String
    let courses: [CourseGrade]
    let ranking: SemesterRanking?
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onCourseTap: (CourseGrade) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                    .background(Color.white.opacity(0.08))
                VStack(spacing: 0) {
                    ForEach(Array(courses.enumerated()), id: \.element.id) { offset, course in
                        if offset > 0 {
                            Divider()
                                .background(Color.white.opacity(0.05))
                                .padding(.leading, TigerDuckTheme.Spacing.md)
                        }
                        ScoreCourseRow(course: course) { onCourseTap(course) }
                    }
                }
            }
        }
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTerm)
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textPrimary)
                    HStack(spacing: TigerDuckTheme.Spacing.sm) {
                        statPill(
                            icon: "number",
                            text: "\(totalCredits) 學分"
                        )
                        if let gpa = ranking?.semester.gpa {
                            statPill(icon: "chart.bar", text: String(format: "GPA %.2f", gpa))
                        }
                        if let classRank = ranking?.semester.classRank, let deptRank = ranking?.semester.deptRank {
                            statPill(icon: "person.2", text: "排名 \(deptRank) (\(classRank))")
                        }
                    }
                }
                Spacer()
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(TigerDuckTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var displayTerm: String {
        guard term.count == 4 else { return term }
        let year = String(term.prefix(3))
        let sem = String(term.suffix(1))
        let label = sem == "1" ? "上" : sem == "2" ? "下" : sem
        return "\(year) 學年度 \(label)學期"
    }

    private var totalCredits: Int {
        courses.reduce(0) { $0 + ($1.credits ?? 0) }
    }

    private func statPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(TigerDuckTheme.Typography.caption2)
        }
        .foregroundStyle(Color.textSecondary)
    }
}
