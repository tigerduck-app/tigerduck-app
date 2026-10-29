import Foundation

struct OngoingCourseInfo: Identifiable {
    let course: SDCourse
    let weekday: Int
    let firstPeriodId: String
    let periods: [String]
    let startMinute: Int
    let endMinute: Int
    let classroom: String

    var id: String { "\(course.courseNo)-\(weekday)-\(firstPeriodId)" }

    init(slot: CourseTimeSlot) {
        func minute(_ date: Date) -> Int {
            let parts = AppConstants.taipeiCalendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        course = slot.course
        weekday = slot.date.scheduleWeekday
        firstPeriodId = slot.periods.first ?? ""
        periods = slot.periods
        startMinute = minute(slot.start)
        endMinute = minute(slot.end)
        classroom = slot.room
    }

    var formattedTimeRange: String {
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(hm(startMinute)) - \(hm(endMinute))"
    }
}

extension Array where Element == SDCourse {
    /// The classes running at `date` as the school changed them; a cancelled one is not running.
    func ongoingCourses(at date: Date, changes: CourseChanges = .cached) -> [OngoingCourseInfo] {
        CourseTimeSlot.buildSlots(from: self, weekday: date.scheduleWeekday, on: date, changes: changes)
            .filter { !$0.isCancelled && $0.start <= date && date < $0.end }
            .map(OngoingCourseInfo.init(slot:))
    }
}
