import Foundation
import TigerDuckCore

enum ClassTableCalendarFile {
    struct Event {
        let uid: String
        let summary: String
        let location: String
        let description: String
        let start: Date
        let end: Date
        let excluded: [Date]
    }

    static func events(of table: ClassTableViewModel, in term: SchoolCalendar.Term) -> [Event] {
        events(courses: table.courses, term: term, owner: table.shownPerson?.id.uuidString)
    }

    static func events(courses: [CourseStore.Course], term: SchoolCalendar.Term, owner: String?) -> [Event] {
        let calendar = TaipeiTime.calendar
        let until = lastMoment(of: term)
        return courses.flatMap { course in
            course.schedule.keys.filter { Self.weekdays.contains($0) }.sorted().flatMap { weekday -> [Event] in
                let firstDay = ClassTableViewModel.nextDate(onWeekday: weekday, from: term.days.start)
                return CourseMeeting.meetings(of: course, weekday: weekday, on: firstDay, changes: .empty).compactMap { meeting -> Event? in
                    let starts = sequence(first: meeting.start) { calendar.date(byAdding: .day, value: 7, to: $0) }
                        .prefix(while: { $0 <= until })
                    // RFC 5545 counts DTSTART as a meeting even when an EXDATE names it, so a series starts
                    // at the first meeting a holiday leaves.
                    guard let held = starts.firstIndex(where: term.quietDays.isClassDay) else { return nil }
                    return Event(
                        // A calendar keeps one event per UID (RFC 5545 §3.8.4.7), so another student's
                        // table adds its owner to them.
                        uid: "\(term.code)-\(course.courseNo)-\(weekday)-\(meeting.periods[0])"
                            + (owner.map { "-\($0)" } ?? "") + "@tigerduck.app",
                        summary: course.displayName,
                        location: course.classroom(weekday: weekday, periods: meeting.periods),
                        description: [course.instructor, course.courseNo].filter { !$0.isEmpty }.joined(separator: "\n"),
                        start: starts[held],
                        end: starts[held].addingTimeInterval(meeting.end.timeIntervalSince(meeting.start)),
                        excluded: starts[(held + 1)...].filter { !term.quietDays.isClassDay($0) }
                    )
                }
            }
        }
    }

    static func hasTimedMeeting(in courses: [CourseStore.Course]) -> Bool {
        courses.contains { course in
            course.schedule.contains { weekday, periods in
                weekdays.contains(weekday) && periods.contains { AppConstants.PeriodTimes.mapping[$0] != nil }
            }
        }
    }

    private static let weekdays = 1...7

    private static func lastMoment(of term: SchoolCalendar.Term) -> Date {
        let calendar = TaipeiTime.calendar
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: term.days.end))?
            .addingTimeInterval(-1) ?? term.days.end
    }

    static func text(of events: [Event], in term: SchoolCalendar.Term, now: Date) -> String {
        let zone = TaipeiTime.timeZone.identifier
        let until = lastMoment(of: term)
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TigerDuck//Class Table//EN", "CALSCALE:GREGORIAN",
            // Taipei has kept UTC+8 all year since 1980, so one standard rule covers every class.
            "BEGIN:VTIMEZONE", "TZID:\(zone)", "BEGIN:STANDARD", "DTSTART:19700101T000000",
            "TZOFFSETFROM:+0800", "TZOFFSETTO:+0800", "END:STANDARD", "END:VTIMEZONE",
        ]
        for event in events {
            lines += [
                "BEGIN:VEVENT",
                "UID:" + ICSFormat.escaped(event.uid),
                "DTSTAMP:" + ICSFormat.utcDateTime.string(from: now),
                "DTSTART;TZID=\(zone):" + ICSFormat.dateTime.string(from: event.start),
                "DTEND;TZID=\(zone):" + ICSFormat.dateTime.string(from: event.end),
                // RFC 5545 §3.3.10: under a start with a time zone, UNTIL is in UTC.
                "RRULE:FREQ=WEEKLY;UNTIL=" + ICSFormat.utcDateTime.string(from: until),
            ]
            lines += event.excluded.map { "EXDATE;TZID=\(zone):" + ICSFormat.dateTime.string(from: $0) }
            lines.append("SUMMARY:" + ICSFormat.escaped(event.summary))
            if !event.location.isEmpty { lines.append("LOCATION:" + ICSFormat.escaped(event.location)) }
            if !event.description.isEmpty { lines.append("DESCRIPTION:" + ICSFormat.escaped(event.description)) }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(ICSFormat.folded).joined(separator: "\r\n") + "\r\n"
    }
}
