import Foundation

nonisolated extension AcademicCalendar {

    static let holidayEventPrefix = "holiday:"

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

    static func holidayID(for event: SDCalendarEvent) -> Int? {
        guard event.eventId.hasPrefix(holidayEventPrefix) else { return nil }
        return Int(event.eventId.dropFirst(holidayEventPrefix.count))
    }
}
