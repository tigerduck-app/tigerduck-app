import SwiftUI
import TigerDuckCore

private let carouselEdgeInset = TigerDuckTheme.Spacing.lg

private let carouselOngoingPeek: CGFloat = 36

func carouselScrollTarget(isOngoing: [Bool], firstOngoingIndex: Int) -> CGFloat {
    guard firstOngoingIndex > 0 else { return 0 }
    var x: CGFloat = 0
    for index in 0..<firstOngoingIndex {
        x += (isOngoing[safe: index] ?? false)
            ? CurrentClassCard.defaultWidth
            : TodayCourseCard.width
        x += TigerDuckTheme.Spacing.md
    }
    return max(0, carouselEdgeInset + x - carouselOngoingPeek)
}

struct TodayCourseCarousel: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool
    var showProgress: Bool = true
    var ongoing: [OngoingCourseInfo] = []
    var onSelect: ((SDCourse) -> Void)? = nil
    var onSelectOngoing: ((OngoingCourseInfo) -> Void)? = nil

    private static let periodTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TaipeiTime.timeZone
        return f
    }()

    #if os(iOS)
    @State private var scrollPosition = ScrollPosition()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = AppClockState.shared.version
        if courses.isEmpty {
            noCourseView
        } else {
            carousel
        }
    }

    private var carousel: some View {
        let row = ScrollView(.horizontal, showsIndicators: false) {
            EqualHeightHStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
                ForEach(sortedCourses, id: \.courseNo) { course in
                    if let info = ongoingByCourseNo[course.courseNo] {
                        CurrentClassCard(
                            info: info,
                            hasAssignment: hasAssignment(course.courseNo),
                            onTap: {
                                if let onSelectOngoing {
                                    onSelectOngoing(info)
                                } else {
                                    onSelect?(course)
                                }
                            }
                        )
                    } else {
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
            }
            .padding(.horizontal, carouselEdgeInset)
        }

        // Only iOS presents this view (the Mac uses MacClassTableView), and
        // ScrollPosition needs macOS 15 against a macOS 14 deployment target, so
        // the self-scroll is compiled for iOS alone instead of gated at runtime.
        #if os(iOS)
        return row
            .scrollPosition($scrollPosition)
            .onChange(of: firstOngoingIndex, initial: true) { _, index in
                guard index > 0 else { return }
                let flags = sortedCourses.map { ongoingByCourseNo[$0.courseNo] != nil }
                withAnimation(reduceMotion ? nil : .default) {
                    scrollPosition.scrollTo(
                        x: carouselScrollTarget(isOngoing: flags, firstOngoingIndex: index)
                    )
                }
            }
        #else
        return row
        #endif
    }

    private var ongoingByCourseNo: [String: OngoingCourseInfo] {
        Dictionary(ongoing.map { ($0.course.courseNo, $0) }, uniquingKeysWith: { _, last in last })
    }

    private var firstOngoingIndex: Int {
        let byNo = ongoingByCourseNo
        return sortedCourses.firstIndex { byNo[$0.courseNo] != nil } ?? -1
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
        let cal = TaipeiTime.calendar
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
    static let width: CGFloat = 140

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

            Spacer(minLength: 0)

            if let progress, isActive {
                ProgressView(value: progress)
                    .tint(course.color)
            }

            Text(periods)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardPadding()
        .background(course.color.opacity(0.15), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .assignmentBadge(show: showBadge)
    }
}
