import Foundation

/// Resolved time window of a single course on a specific day.
///
/// Lives in `Models/Domain` so cross-platform code (Mac UI, future
/// widgets, future watch derivations) can derive timelines without
/// pulling in the iOS-only TimeSlider view model.
struct CourseTimeSlot: Identifiable, Equatable {
    /// Number of days on each side of the focus date that
    /// `buildMultiDaySlots` materialises by default. The iOS time-slider
    /// view exposes the same value through `TimeSliderMetrics` so the
    /// horizontal scroll viewport and the in-memory slot set stay in
    /// lockstep.
    static let defaultDayRadius: Int = 28

    static func == (lhs: CourseTimeSlot, rhs: CourseTimeSlot) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let course: SDCourse
    let start: Date
    let end: Date
    /// The calendar date this slot belongs to (for display purposes).
    let date: Date

    /// Build slots for a single day. Emits one slot per contiguous run of
    /// periods (consecutive in `AppConstants.Periods.chronologicalOrder`)
    /// rather than one first-to-last span — otherwise a course scheduled
    /// at P1 and P3 with P2 free would collapse into a single
    /// 08:10-12:10 slot, and `CourseTimelineResolver` would report
    /// `.inClass` during the P2 gap. The block-merge rule matches
    /// `OngoingCourseInfo.ongoingCourses(weekday:minuteOfDay:)`, so the
    /// time-slider, Live Activity, and Mac dashboard cards all draw
    /// blocks consistently with the "Current class" carousel.
    static func buildSlots(from courses: [SDCourse], weekday: Int, on date: Date = AppClock.now()) -> [CourseTimeSlot] {
        let calendar = AppConstants.taipeiCalendar
        var slots: [CourseTimeSlot] = []
        let dayKey = Self.dayKeyFormatter.string(from: date)

        for course in courses {
            guard let raw = course.schedule[weekday], !raw.isEmpty else { continue }
            let periods = raw.sortedByPeriodOrder()

            var blockStart = 0
            while blockStart < periods.count {
                var blockEnd = blockStart
                while blockEnd + 1 < periods.count,
                      Self.periodOrder(periods[blockEnd + 1]) == Self.periodOrder(periods[blockEnd]) + 1 {
                    blockEnd += 1
                }
                let firstPeriod = periods[blockStart]
                let lastPeriod = periods[blockEnd]
                if let firstTime = AppConstants.PeriodTimes.mapping[firstPeriod],
                   let lastTime = AppConstants.PeriodTimes.mapping[lastPeriod],
                   let startDate = Self.dateFromTimeString(firstTime.start, on: date, calendar: calendar),
                   let endDate = Self.dateFromTimeString(lastTime.end, on: date, calendar: calendar) {
                    slots.append(CourseTimeSlot(
                        // Suffix the run's first period so two disjoint
                        // blocks on the same day yield distinct ids
                        // (Identifiable + LiveActivity sourceId).
                        id: "\(course.courseNo)_\(dayKey)_\(firstPeriod)",
                        course: course,
                        start: startDate,
                        end: endDate,
                        date: date
                    ))
                }
                blockStart = blockEnd + 1
            }
        }

        return slots.sorted { $0.start < $1.start }
    }

    private static func periodOrder(_ periodId: String) -> Int {
        AppConstants.Periods.chronologicalOrder.firstIndex(of: periodId) ?? Int.max
    }

    /// Build a multi-day timeline centered on `centerDate`, spanning ±`dayRadius` days.
    static func buildMultiDaySlots(
        from courses: [SDCourse],
        centerDate: Date,
        dayRadius: Int = CourseTimeSlot.defaultDayRadius
    ) -> [CourseTimeSlot] {
        let calendar = AppConstants.taipeiCalendar
        var allSlots: [CourseTimeSlot] = []

        for offset in -dayRadius...dayRadius {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: centerDate)) else { continue }
            let weekday = date.scheduleWeekday
            let daySlots = buildSlots(from: courses, weekday: weekday, on: date)
            allSlots.append(contentsOf: daySlots)
        }

        return allSlots.sorted { $0.start < $1.start }
    }

    static func dateFromTimeString(_ time: String, on date: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var dc = calendar.dateComponents([.year, .month, .day], from: date)
        dc.hour = parts[0]
        dc.minute = parts[1]
        dc.second = 0
        return calendar.date(from: dc)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = AppConstants.taipeiTimeZone
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
