import SwiftUI

struct TodayCourseCards: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool
    var onSelect: ((SDCourse) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                ForEach(sortedCourses, id: \.courseNo) { course in
                    Button {
                        onSelect?(course)
                    } label: {
                        ClassTableCourseCard(
                            course: course,
                            showBadge: hasAssignment(course.courseNo)
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(opacityForCourse(course))
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

    /// Sort by start time: earliest (left) → latest (right)
    private var sortedCourses: [SDCourse] {
        courses.sorted { a, b in
            courseStartTime(a) < courseStartTime(b)
        }
    }

    private func courseStartTime(_ course: SDCourse) -> String {
        let today = Date().weekdayIndex + 1
        guard let periods = course.schedule[today]?.sortedByPeriodOrder(),
              let first = periods.first,
              let times = AppConstants.PeriodTimes.mapping[first] else { return "" }
        return times.start
    }

    private func opacityForCourse(_ course: SDCourse) -> Double {
        guard let progress = courseProgress(course) else { return 1.0 }
        if progress >= 1.0 { return 0.35 }
        if progress > 0 { return 1.0 - (progress * 0.6) }
        return 1.0
    }

    private func courseProgress(_ course: SDCourse) -> Double? {
        let today = Date().weekdayIndex + 1
        guard let periods = course.schedule[today]?.sortedByPeriodOrder() else { return nil }
        let now = Date()
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        guard let firstPeriod = periods.first,
              let lastPeriod = periods.last,
              let firstTimes = AppConstants.PeriodTimes.mapping[firstPeriod],
              let lastTimes = AppConstants.PeriodTimes.mapping[lastPeriod],
              let startDate = formatter.date(from: firstTimes.start),
              let endDate = formatter.date(from: lastTimes.end) else { return nil }

        let startComponents = cal.dateComponents([.hour, .minute], from: startDate)
        let endComponents = cal.dateComponents([.hour, .minute], from: endDate)
        guard let start = cal.date(bySettingHour: startComponents.hour!, minute: startComponents.minute!, second: 0, of: now),
              let end = cal.date(bySettingHour: endComponents.hour!, minute: endComponents.minute!, second: 0, of: now) else { return nil }

        if now < start { return 0 }
        if now > end { return 1 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

private struct ClassTableCourseCard: View {
    let course: SDCourse
    var showBadge: Bool = false

    private var periods: String {
        let today = Date().weekdayIndex + 1
        guard let p = course.schedule[today]?.sortedByPeriodOrder(),
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
