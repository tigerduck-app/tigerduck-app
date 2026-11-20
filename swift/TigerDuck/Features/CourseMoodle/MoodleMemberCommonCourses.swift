import SwiftUI
import TigerDuckCore

struct MoodleMemberCommonCourses: View {
    let terms: [MoodleCommonTerm]
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Text(String(localized: "course_member_common_courses"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(terms) { term in
                Text(term.term.map(AcademicTerm.label(of:)) ?? String(localized: "course_member_common_courses_other"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, TigerDuckTheme.Spacing.xs)
                    .padding(.top, TigerDuckTheme.Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(term.courses.enumerated()), id: \.element.id) { index, course in
                        if index > 0 {
                            Divider().padding(.leading, CourseListRow.textInset)
                        }
                        CourseListRow(
                            color: TigerDuckTheme.courseColor(for: course.colorKey), title: course.name, details: course.details
                        )
                    }
                }
                .presetCard(policy: policy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
