import SwiftUI

/// The carousel's start/end inset, inside the scrollable content.
private let carouselEdgeInset = TigerDuckTheme.Spacing.lg

/// How much of the preceding card stays visible when the row scrolls itself
/// to the ongoing class. Past the 12pt gap this leaves roughly 24pt of the
/// card before it — enough to read as "there is more to the left" without
/// stealing width from the class actually happening.
private let carouselOngoingPeek: CGFloat = 36

/// Where the today's-courses row should sit so the ongoing class leads it.
///
/// `isOngoing` is per card, in display order, because a card's width depends
/// on which kind it is — two classes can overlap, so a wide ongoing card can
/// sit before the one being scrolled to.
///
/// Returns 0 when nothing is ongoing (`firstOngoingIndex` < 0) or when the
/// ongoing class is already first: the day should then be read from its
/// start, not nudged off the edge.
///
/// Reads the card widths off the cards themselves rather than repeating the
/// numbers, so a resized card cannot silently desync the scroll from the
/// layout.
func carouselScrollTarget(isOngoing: [Bool], firstOngoingIndex: Int) -> CGFloat {
    guard firstOngoingIndex > 0 else { return 0 }
    var x: CGFloat = 0
    for index in 0..<firstOngoingIndex {
        x += (isOngoing[safe: index] ?? false)
            ? CurrentClassCard.defaultWidth
            : TodayCourseCard.width
        x += TigerDuckTheme.Spacing.md
    }
    // The row's own start inset sits inside the scrollable content, so it
    // counts toward the card's position.
    return max(0, carouselEdgeInset + x - carouselOngoingPeek)
}

struct TodayCourseCarousel: View {
    let courses: [SDCourse]
    let hasAssignment: (String) -> Bool
    var showProgress: Bool = true
    /// The class blocks running right now. A course named here renders as a
    /// "Current class" card *in its own slot in the day*, rather than being
    /// lifted to the head of the row — see `body`. Mirrors Android's
    /// `ongoingCourses`.
    var ongoing: [OngoingCourseInfo] = []
    var onSelect: ((SDCourse) -> Void)? = nil
    /// Dedicated callback for "Current class" cards so callers can
    /// thread the tapped block's specific period range (start/end
    /// minutes) into the detail sheet instead of losing it to the
    /// course-only `onSelect` path. Falls back to `onSelect` when nil.
    var onSelectOngoing: ((OngoingCourseInfo) -> Void)? = nil

    private static let periodTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    #if os(iOS)
    @State private var scrollPosition = ScrollPosition()
    #endif

    var body: some View {
        // The body and its helpers (`today`, `courseProgress`, etc.) read
        // `AppClock.now()`, which Observation can't track. Pulling
        // `AppClockState.shared.version` here wires the view's dependency
        // graph to debug time-override flips.
        let _ = AppClockState.shared.version
        if courses.isEmpty {
            noCourseView
        } else {
            carousel
        }
    }

    /// The ongoing class renders in its own place in the day, in the ongoing
    /// style, rather than lifted to the front of the row. Lifting it showed
    /// the same class twice — once as the big card at the head, once again
    /// further along as an ordinary one — and threw away the thing the
    /// carousel is for: where you are in today's sequence. The head card also
    /// read as "first class of the day" to anyone not looking closely.
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

        // Only iOS presents this view — the Mac draws its timetable from
        // MacClassTableView — and ScrollPosition needs macOS 15 against a
        // macOS 14 deployment target, so the self-scroll is compiled in for
        // iOS alone rather than version-gated at runtime.
        #if os(iOS)
        // Scroll the ongoing class to the front, leaving a sliver of the one
        // before it so the row reads as "you are here" rather than as the
        // start of the day. Keyed on the index alone, not on the course list:
        // that list is rebuilt every minute from the clock tick, and keying
        // on it would yank the row back under anyone who had scrolled away.
        return row
            .scrollPosition($scrollPosition)
            .onChange(of: firstOngoingIndex, initial: true) { _, index in
                guard index > 0 else { return }
                let flags = sortedCourses.map { ongoingByCourseNo[$0.courseNo] != nil }
                withAnimation {
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

    /// Position of the first running class in display order, or -1 if none of
    /// today's courses is running.
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
    /// Named because `carouselScrollTarget` measures the row with it — a
    /// resized card must not silently desync the self-scroll from the layout.
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

            // Push the time row to the bottom so the card visually fills
            // when stretched to match a taller sibling (e.g. the
            // `CurrentClassCard`'s progress + time block). `minLength: 0`
            // keeps short cards from forcing extra height when nothing is
            // stretching them.
            Spacer(minLength: 0)

            if let progress, isActive {
                ProgressView(value: progress)
                    .tint(course.color)
            }

            Text(periods)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        // Inner frame fixes the card's width; outer `maxHeight: .infinity`
        // lets the colored surface stretch to whatever row height
        // `EqualHeightHStack` settled on, so a short card visually
        // matches a taller sibling like `CurrentClassCard`. `.topLeading`
        // keeps content anchored to the top while the background grows
        // downward.
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardPadding()
        .background(course.color.opacity(0.15), in: RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg))
        .glassCard()
        .assignmentBadge(show: showBadge)
    }
}
