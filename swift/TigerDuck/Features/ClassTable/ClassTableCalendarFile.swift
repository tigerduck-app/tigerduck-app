import Foundation
import TigerDuckCore

/// The class table on screen as an iCalendar file (RFC 5545) for a calendar app to import: each
/// meeting of a course repeats weekly through its term, less the days a holiday takes its class.
enum ClassTableCalendarFile {
    /// A meeting's first class and the course it belongs to.
    struct Event {
        let uid: String
        let summary: String
        let location: String
        let description: String
        let start: Date
        let end: Date
    }

    /// The table's courses, not the clubs drawn over its grid. Someone else's table gets uids of its
    /// own, so a calendar that imports both tables keeps both.
    static func events(of table: ClassTableViewModel, in term: SchoolCalendar.Term) -> [Event] {
        events(courses: table.courses, term: term, owner: table.shownPerson?.id.uuidString)
    }

    /// One event per meeting, a run of consecutive periods of a course on a weekday; a period with no
    /// time on the timetable makes none, and nor does a day the grid has no column for or the term
    /// does not reach.
    static func events(courses: [CourseStore.Course], term: SchoolCalendar.Term, owner: String?) -> [Event] {
        let lastDay = TaipeiTime.calendar.startOfDay(for: term.days.end)
        return courses.flatMap { course in
            course.schedule.keys.filter { (1...7).contains($0) }.sorted().flatMap { weekday -> [Event] in
                let firstDay = ClassTableViewModel.nextDate(onWeekday: weekday, from: term.days.start)
                guard firstDay <= lastDay else { return [] }
                return CourseMeeting.meetings(of: course, weekday: weekday, on: firstDay, changes: .empty).map { meeting in
                    Event(
                        uid: "\(term.code)-\(course.courseNo)-\(weekday)-\(meeting.periods[0])"
                            + (owner.map { "-\($0)" } ?? "") + "@tigerduck.app",
                        summary: course.displayName,
                        location: course.classroom(weekday: weekday, periods: meeting.periods),
                        description: [course.instructor, course.courseNo].filter { !$0.isEmpty }.joined(separator: "\n"),
                        start: meeting.start,
                        end: meeting.end
                    )
                }
            }
        }
    }

    /// The file: each event repeats weekly to the term's last day, except on its quiet days. CRLF line
    /// ends, long lines folded, and times in Taipei under the zone they name.
    static func text(of events: [Event], in term: SchoolCalendar.Term, now: Date) -> String {
        let calendar = TaipeiTime.calendar
        let zone = TaipeiTime.timeZone.identifier
        let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: term.days.end))?
            .addingTimeInterval(-1) ?? term.days.end
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TigerDuck//Class Table//EN", "CALSCALE:GREGORIAN",
            // Taipei has kept UTC+8 all year since 1980, so one standard rule covers every class.
            "BEGIN:VTIMEZONE", "TZID:\(zone)", "BEGIN:STANDARD", "DTSTART:19700101T000000",
            "TZOFFSETFROM:+0800", "TZOFFSETTO:+0800", "END:STANDARD", "END:VTIMEZONE",
        ]
        for event in events {
            let weeks = sequence(first: event.start) { calendar.date(byAdding: .day, value: 7, to: $0) }
            lines += [
                "BEGIN:VEVENT",
                "UID:" + ICSFormat.escaped(event.uid),
                "DTSTAMP:" + ICSFormat.utcDateTime.string(from: now),
                "DTSTART;TZID=\(zone):" + ICSFormat.dateTime.string(from: event.start),
                "DTEND;TZID=\(zone):" + ICSFormat.dateTime.string(from: event.end),
                // RFC 5545 §3.3.10: under a start with a time zone, UNTIL is in UTC.
                "RRULE:FREQ=WEEKLY;UNTIL=" + ICSFormat.utcDateTime.string(from: until),
            ]
            lines += weeks.prefix(while: { $0 <= until }).filter { !term.quietDays.isClassDay($0) }
                .map { "EXDATE;TZID=\(zone):" + ICSFormat.dateTime.string(from: $0) }
            lines.append("SUMMARY:" + ICSFormat.escaped(event.summary))
            if !event.location.isEmpty { lines.append("LOCATION:" + ICSFormat.escaped(event.location)) }
            if !event.description.isEmpty { lines.append("DESCRIPTION:" + ICSFormat.escaped(event.description)) }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(ICSFormat.folded).joined(separator: "\r\n") + "\r\n"
    }
}
