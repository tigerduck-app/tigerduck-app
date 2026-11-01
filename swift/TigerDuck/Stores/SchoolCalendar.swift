import Foundation

enum SchoolCalendar {
    typealias Changes = CourseChanges

    static var changes: Changes { .cached }

    static func isClassDay(_ day: Date) -> Bool { AcademicCalendarStore.shared.isClassDay(day) }

    static func isInSession() -> Bool { AcademicCalendarStore.shared.calendar.isInSession() }

    /// The rows the academic calendar adds to the calendar: holidays and the terms' first and last days.
    static func events() -> [SDCalendarEvent] { AcademicCalendarStore.shared.calendar.calendarEvents() }

    static func holidayID(for event: SDCalendarEvent) -> Int? { AcademicCalendar.holidayID(for: event) }
}
