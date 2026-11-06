import Foundation
import TigerDuckCore

enum SchoolCalendar {
    typealias Changes = CourseChanges

    struct Term {
        let code: String
        let days: QuietDayCalendar.Span
        let quietDays: QuietDayCalendar
    }

    static var changes: Changes { .cached }

    static func isClassDay(_ day: Date) -> Bool { AcademicCalendarStore.shared.isClassDay(day) }

    static func isInSession() -> Bool { AcademicCalendarStore.shared.calendar.isInSession() }

    static func week(of term: String, on day: Date) -> Int? { AcademicCalendarStore.shared.calendar.week(of: term, on: day) }

    /// The rows the academic calendar adds to the calendar: holidays and the terms' first and last days.
    static func events() -> [SDCalendarEvent] { AcademicCalendarStore.shared.calendar.calendarEvents() }

    static func holidayID(for event: SDCalendarEvent) -> Int? { AcademicCalendar.holidayID(for: event) }

    static func term(_ code: String, ownTable: Bool) -> Term? {
        let store = AcademicCalendarStore.shared
        return term(code, ownTable: ownTable, calendar: store.calendar, optedIn: store.optedInHolidayIDs)
    }

    static func term(_ code: String, ownTable: Bool, calendar: AcademicCalendar, optedIn: Set<Int>) -> Term? {
        guard let term = calendar.terms.first(where: { $0.code == code }) else { return nil }
        return Term(
            code: code,
            days: QuietDayCalendar.Span(start: term.start, end: term.end),
            quietDays: calendar.quietDays(optedIn: ownTable ? optedIn : [])
        )
    }
}
