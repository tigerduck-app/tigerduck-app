import Foundation

/// Turns the published academic calendar into rows the Calendar screens list
/// alongside Moodle deadlines and school events. Not on `CalendarViewModel`,
/// because the Mac needs it and that view model is out of the macOS build: it
/// pulls in EventKit, which the Mac leaves out to avoid the Calendar TCC
/// entitlement. The iPhone view model and `MacCalendarView` both call it, so
/// they agree on semester boundaries and holidays. Rows are never persisted:
/// `DataCache` holds only network data and every load rebuilds these, so a
/// boundary an older build stored under the wrong source does not survive.
nonisolated extension AcademicCalendar {

    /// Marks an event id as a holiday's, so `holidayID(for:)` can read the
    /// id back out of one.
    static let holidayEventPrefix = "holiday:"

    /// Semester boundaries and school holidays, as calendar rows.
    ///
    /// Rebuilt on every call, not cached: holiday names depend on the locale,
    /// and the app language can change under us. Cheap: a few dozen rows from
    /// an in-memory value. One row per holiday and one at each end of a term,
    /// never one per day: a week-long winter break is one event, and eight
    /// identical rows would bury the Moodle deadlines this screen is for.
    func calendarEvents(locale: Locale = .current) -> [SDCalendarEvent] {
        let holidayRows = holidays.map { holiday in
            SDCalendarEvent(
                eventId: "\(Self.holidayEventPrefix)\(holiday.id)",
                title: holiday.name(for: locale),
                date: holiday.start,
                source: .holiday
            )
        }
        let boundaries = terms.flatMap { term -> [SDCalendarEvent] in
            let label = term.code.count == 4
                ? "\(term.code.prefix(3))-\(term.code.suffix(1))"
                : term.code
            return [
                SDCalendarEvent(
                    eventId: "term-start:\(term.code)",
                    title: String(format: String(localized: "calendar_semester_start"), label),
                    date: term.start,
                    source: .semester
                ),
                SDCalendarEvent(
                    eventId: "term-end:\(term.code)",
                    title: String(format: String(localized: "calendar_semester_end"), label),
                    date: term.end,
                    source: .semester
                ),
            ]
        }
        return holidayRows + boundaries
    }

    /// The holiday a row belongs to, or nil for a term boundary or an
    /// ordinary event. Boundaries return nil deliberately: they are
    /// announcements, not days off, so there is nothing to opt back into.
    static func holidayID(for event: SDCalendarEvent) -> Int? {
        guard event.eventId.hasPrefix(holidayEventPrefix) else { return nil }
        return Int(event.eventId.dropFirst(holidayEventPrefix.count))
    }
}
