import Foundation

/// Turns the published academic calendar into rows the Calendar screens list
/// alongside Moodle deadlines and school events.
///
/// Lives here rather than on `CalendarViewModel` because the Mac needs it
/// too, and that view model is excluded from the macOS build — it pulls in
/// EventKit, which the Mac surface deliberately stays out of to avoid the
/// Calendar TCC entitlement. Both the iPhone view model and `MacCalendarView`
/// call in here so the two screens cannot drift on what a semester boundary
/// or a holiday looks like.
///
/// These rows are never persisted. `DataCache` holds only what came off the
/// network, and every load path rebuilds these from the in-memory calendar —
/// so a boundary written by an older build under the wrong source doesn't
/// survive in the cache forever.
nonisolated extension AcademicCalendar {

    /// Marks an event id as a holiday's, so `holidayID(for:)` can read the
    /// id back out of one.
    static let holidayEventPrefix = "holiday:"

    /// Semester boundaries and school holidays, as calendar rows.
    ///
    /// Rebuilt on every call rather than cached: the holiday name is
    /// locale-dependent and the app language can change under us. Cheap —
    /// a few dozen rows off an in-memory value.
    ///
    /// One row per holiday and one at each end of a term, never one per day:
    /// a week-long 寒假 is a single thing that happened, and eight identical
    /// rows would bury the Moodle deadlines this screen exists to show.
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
