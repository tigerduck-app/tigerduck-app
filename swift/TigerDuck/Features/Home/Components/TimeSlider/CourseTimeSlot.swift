import Foundation

struct CourseTimeSlot: Identifiable {
    let id: String
    let course: SDCourse
    let start: Date
    let end: Date

    static func buildSlots(from courses: [SDCourse], weekday: Int, on date: Date = Date()) -> [CourseTimeSlot] {
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

            slots.append(CourseTimeSlot(id: course.courseNo, course: course, start: startDate, end: endDate))
        }

        return slots.sorted { $0.start < $1.start }
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
}
