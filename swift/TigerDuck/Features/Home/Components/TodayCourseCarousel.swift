import SwiftUI

struct TodayCourseCarousel: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool

    var body: some View {
        if courses.isEmpty {
            noCourseView
        } else {
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                ForEach(courses, id: \.courseNo) { course in
                    TodayCourseRow(
                        course: course,
                        showBadge: hasAssignment(course.courseNo),
                        isActive: isCourseActive(course),
                        progress: courseProgress(course)
                    )
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

    private var noCourseView: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("今日沒有課程")
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .cardPadding()
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func isCourseActive(_ course: SDCourse) -> Bool {
        let today = Date().weekdayIndex + 1
        guard let periods = course.schedule[today] else { return false }
        let now = Date()
        for periodId in periods {
            guard let times = AppConstants.PeriodTimes.mapping[periodId] else { continue }
            let cal = Calendar.current
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            guard let startDate = formatter.date(from: times.start),
                  let endDate = formatter.date(from: times.end) else { continue }
            let startComponents = cal.dateComponents([.hour, .minute], from: startDate)
            let endComponents = cal.dateComponents([.hour, .minute], from: endDate)
            guard let start = cal.date(bySettingHour: startComponents.hour!, minute: startComponents.minute!, second: 0, of: now),
                  let end = cal.date(bySettingHour: endComponents.hour!, minute: endComponents.minute!, second: 0, of: now) else { continue }
            if now >= start && now <= end { return true }
        }
        return false
    }

    private func courseProgress(_ course: SDCourse) -> Double? {
        let today = Date().weekdayIndex + 1
        guard let periods = course.schedule[today] else { return nil }
        let now = Date()
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        // Get overall start/end for this course block
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

struct TodayCourseRow: View {
    let course: SDCourse
    var showBadge: Bool = false
    var isActive: Bool = false
    var progress: Double? = nil

    private var timeRange: String {
        let today = Date().weekdayIndex + 1
        guard let periods = course.schedule[today],
              let first = periods.first,
              let last = periods.last,
              let firstTimes = AppConstants.PeriodTimes.mapping[first],
              let lastTimes = AppConstants.PeriodTimes.mapping[last] else { return "" }
        return "\(firstTimes.start) - \(lastTimes.end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                // Color accent bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(course.color)
                    .frame(width: 4, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(course.courseName)
                            .font(TigerDuckTheme.Typography.headline)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)

                        if isActive {
                            Text("進行中")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green, in: Capsule())
                        }

                        Spacer()

                        if showBadge {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.badgeRed)
                        }
                    }

                    HStack(spacing: TigerDuckTheme.Spacing.md) {
                        Label(course.classroom, systemImage: "mappin")
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                        Label(timeRange, systemImage: "clock")
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            // Progress bar for active course
            if let progress, isActive {
                ProgressView(value: progress)
                    .tint(course.color)
            }
        }
        .cardPadding()
        .glassCard()
    }
}
