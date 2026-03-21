import SwiftUI

struct TodayCourseCards: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool
    var onSelect: ((SDCourse) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                ForEach(courses, id: \.courseNo) { course in
                    Button {
                        onSelect?(course)
                    } label: {
                        ClassTableCourseCard(
                            course: course,
                            showBadge: hasAssignment(course.courseNo)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}

private struct ClassTableCourseCard: View {
    let course: SDCourse
    var showBadge: Bool = false

    private var periods: String {
        let today = Date().weekdayIndex + 1
        guard let p = course.schedule[today],
              let first = p.first,
              let last = p.last,
              let firstTimes = AppConstants.PeriodTimes.mapping[first],
              let lastTimes = AppConstants.PeriodTimes.mapping[last] else { return "" }
        return "\(firstTimes.start)-\(lastTimes.end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Text(course.courseName)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            Text(course.classroom)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)

            Text(periods)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(width: 140, alignment: .leading)
        .cardPadding()
        .background(course.color.opacity(0.15), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .assignmentBadge(show: showBadge)
    }
}
