import Foundation
import TigerDuckCore

nonisolated extension AcademicCalendar {

    static let holidayEventPrefix = "holiday:"

    func calendarEvents(locale: Locale = .current) -> [SDCalendarEvent] {
        // One row per day, as the school's multi-day events get, since the calendar lists a day's
        // events; each row carries the holiday's one opt-in toggle.
        let holidayRows = holidays.flatMap { holiday in
            sequence(first: holiday.start) { Self.calendar.date(byAdding: .day, value: 1, to: $0) }
                .prefix { $0 <= holiday.end }
                .map { day in
                    SDCalendarEvent(
                        eventId: "\(Self.holidayEventPrefix)\(holiday.id):\(Int(day.timeIntervalSince1970))",
                        title: holiday.name(for: locale),
                        date: day,
                        source: .holiday
                    )
                }
        }
        let boundaries = terms.flatMap { term -> [SDCalendarEvent] in
            let label = AcademicTerm.label(of: term.code)
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

    static func holidayID(for event: SDCalendarEvent) -> Int? {
        guard event.eventId.hasPrefix(holidayEventPrefix) else { return nil }
        return Int(event.eventId.dropFirst(holidayEventPrefix.count).prefix { $0 != ":" })
    }
}
