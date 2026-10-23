import Foundation

struct CourseTimeSlot: Identifiable, Equatable {
    static let defaultDayRadius: Int = 28

    static func == (lhs: CourseTimeSlot, rhs: CourseTimeSlot) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let course: SDCourse
    let start: Date
    let end: Date
    let date: Date
    var periods: [String] = []

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
                        id: "\(course.courseNo)_\(dayKey)_\(firstPeriod)",
                        course: course,
                        start: startDate,
                        end: endDate,
                        date: date,
                        periods: Array(periods[blockStart...blockEnd])
                    ))
                }
                blockStart = blockEnd + 1
            }
        }

        return slots.sorted { $0.start < $1.start }
    }

    static func meetingSlots(
        from courses: [SDCourse],
        on date: Date,
        isClassDay: (Date) -> Bool
    ) -> [CourseTimeSlot] {
        guard isClassDay(date) else { return [] }
        return buildSlots(from: courses, weekday: date.scheduleWeekday, on: date)
            .filter { !$0.course.isSkipped(on: $0.date) }
    }

    static func isSkipped(slotId id: String, in courses: [SDCourse]) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3, let day = dayKeyFormatter.date(from: String(parts[parts.count - 2])) else {
            return false
        }
        let courseNo = parts.dropLast(2).joined(separator: "_")
        return courses.contains { $0.courseNo == courseNo && $0.isSkipped(on: day) }
    }

    private static func periodOrder(_ periodId: String) -> Int {
        AppConstants.Periods.chronologicalOrder.firstIndex(of: periodId) ?? Int.max
    }

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
