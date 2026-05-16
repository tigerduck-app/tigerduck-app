import Foundation

struct CourseTimeSlot: Identifiable, Equatable {
    static func == (lhs: CourseTimeSlot, rhs: CourseTimeSlot) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let course: SDCourse
    let start: Date
    let end: Date
    /// The calendar date this slot belongs to (for display purposes).
    let date: Date

    /// Build slots for a single day.
    static func buildSlots(from courses: [SDCourse], weekday: Int, on date: Date = AppClock.now()) -> [CourseTimeSlot] {
        let calendar = Calendar.current
        var slots: [CourseTimeSlot] = []

        for course in courses {
            guard let periods = course.schedule[weekday], !periods.isEmpty else { continue }
            let sorted = periods.sortedByPeriodOrder()
            guard let firstPeriod = sorted.first,
                  let lastPeriod = sorted.last,
                  let firstTime = AppConstants.PeriodTimes.mapping[firstPeriod],
                  let lastTime = AppConstants.PeriodTimes.mapping[lastPeriod],
                  let startDate = Self.dateFromTimeString(firstTime.start, on: date, calendar: calendar),
                  let endDate = Self.dateFromTimeString(lastTime.end, on: date, calendar: calendar)
            else { continue }

            let dayKey = Self.dayKeyFormatter.string(from: date)
            slots.append(CourseTimeSlot(
                id: "\(course.courseNo)_\(dayKey)",
                course: course,
                start: startDate,
                end: endDate,
                date: date
            ))
        }

        return slots.sorted { $0.start < $1.start }
    }

    /// Build a multi-day timeline centered on `centerDate`, spanning ±`dayRadius` days.
    static func buildMultiDaySlots(
        from courses: [SDCourse],
        centerDate: Date,
        dayRadius: Int = TimeSliderMetrics.timelineDayRadius
    ) -> [CourseTimeSlot] {
        let calendar = Calendar.current
        var allSlots: [CourseTimeSlot] = []

        for offset in -dayRadius...dayRadius {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: centerDate)) else { continue }
            let weekday = date.scheduleWeekday
            let daySlots = buildSlots(from: courses, weekday: weekday, on: date)
            allSlots.append(contentsOf: daySlots)
        }

        return allSlots.sorted { $0.start < $1.start }
    }

    static func dateFromTimeString(_ time: String, on date: Date, calendar: Calendar = .current) -> Date? {
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
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
