import Foundation

/// The school calendar as the course and calendar screens read it: class days, the term in
/// session, the calendar's own rows and the school's changes to classes.
enum SchoolCalendar {
    typealias Changes = CourseChanges

    /// The school's changes to classes as last fetched.
    static var changes: Changes { .cached }

    static func isClassDay(_ day: Date) -> Bool { AcademicCalendarStore.shared.isClassDay(day) }

    static func isInSession() -> Bool { AcademicCalendarStore.shared.calendar.isInSession() }

    /// The rows the academic calendar adds to the calendar: holidays and the terms' first and last days.
    static func events() -> [SDCalendarEvent] { AcademicCalendarStore.shared.calendar.calendarEvents() }

    static func holidayID(for event: SDCalendarEvent) -> Int? { AcademicCalendar.holidayID(for: event) }
}
