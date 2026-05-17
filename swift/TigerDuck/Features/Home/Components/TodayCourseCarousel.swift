import SwiftUI

struct TodayCourseCarousel: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool
    var showProgress: Bool = true
    /// When non-empty, dedicated "Current class" cards render leftmost in
    /// the carousel, ahead of the regular today cards. Mirrors Android's
    /// `ongoingCourses` cards.
    var ongoing: [OngoingCourseInfo] = []
    var onSelect: ((SDCourse) -> Void)? = nil

    private static let periodTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    var body: some View {
        // The body and its helpers (`today`, `courseProgress`, etc.) read
        // `AppClock.now()`, which Observation can't track. Pulling
        // `AppClockState.shared.version` here wires the view's dependency
        // graph to debug time-override flips.
        let _ = AppClockState.shared.version
        if courses.isEmpty && ongoing.isEmpty {
            noCourseView
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TigerDuckTheme.Spacing.md) {
                    ForEach(ongoing) { info in
                        CurrentClassCard(
                            info: info,
                            hasAssignment: hasAssignment(info.course.courseNo),
                            onTap: { onSelect?(info.course) }
                        )
                    }
                    ForEach(sortedCourses, id: \.courseNo) { course in
                        Button {
                            onSelect?(course)
                        } label: {
                            TodayCourseCard(
                                course: course,
                                showBadge: hasAssignment(course.courseNo),
                                progress: showProgress ? courseProgress(course) : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(opacityForCourse(course))
                    }
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private var noCourseView: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text(String(localized: "home_no_courses_today"))
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .cardPadding()
        .glassCard()
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var today: Int { AppClock.now().scheduleWeekday }

    private var sortedCourses: [SDCourse] {
        let t = today
        return courses.sorted { a, b in
            startTime(a, weekday: t) < startTime(b, weekday: t)
        }
    }

    private func startTime(_ course: SDCourse, weekday: Int) -> String {
        guard let periods = course.schedule[weekday]?.sortedByPeriodOrder(),
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
        guard let periods = course.schedule[today]?.sortedByPeriodOrder() else { return nil }
        let now = AppClock.now()
        let cal = AppConstants.taipeiCalendar
        let formatter = Self.periodTimeFormatter

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

private struct TodayCourseCard: View {
    let course: SDCourse
    var showBadge: Bool = false
    var progress: Double? = nil

    private var periods: String {
        course.timeRange(for: AppClock.now().scheduleWeekday)?.replacingOccurrences(of: " - ", with: "-") ?? ""
    }

    private var isActive: Bool {
        guard let p = progress else { return false }
        return p > 0 && p < 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Text(course.displayName)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if isActive {
                    Text(String(localized: "widget_ongoing"))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
            }

            Text(course.classroom(for: AppClock.now().scheduleWeekday))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)

            Text(periods)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)

            if let progress, isActive {
                ProgressView(value: progress)
                    .tint(course.color)
            }
        }
        .frame(width: 140, alignment: .leading)
        .cardPadding()
        .background(course.color.opacity(0.15), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .assignmentBadge(show: showBadge)
    }
}
