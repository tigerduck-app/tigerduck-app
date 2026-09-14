import Foundation
import SwiftData
import SwiftUI

@Model
final class SDCalendarEvent {
    @Attribute(.unique) var eventId: String
    var title: String
    var date: Date
    var sourceRaw: String // "moodle", "school", "exam", "holiday"

    init(
        eventId: String,
        title: String,
        date: Date,
        source: EventSource
    ) {
        self.eventId = eventId
        self.title = title
        self.date = date
        self.sourceRaw = source.rawValue
    }

    var source: EventSource {
        if let s = EventSource(rawValue: sourceRaw) { return s }
        // Future-case raw values silently coerced to `.school` are
        // indistinguishable from real school events; surface as a
        // breadcrumb so we notice on next data migration.
        AppLogger.breadcrumb(
            "SDCalendarEvent: unknown sourceRaw '\(sourceRaw)' coerced to .school",
            category: "model.calendar"
        )
        return .school
    }

    /// Whether this row is a whole day rather than a moment, so a time on
    /// it ("00:00", or "12:00 AM" on a 12-hour clock) says nothing.
    /// Holidays and term boundaries are days by construction. A school
    /// calendar row is one when the feed gave a date with no time, which
    /// `CalendarService` parses to midnight in Taipei. A Moodle deadline at
    /// midnight is a real deadline and keeps its time.
    var isAllDay: Bool {
        switch source {
        case .holiday, .semester:
            return true
        case .school:
            return AppConstants.taipeiCalendar.startOfDay(for: date) == date
        case .moodle, .exam, .system:
            return false
        }
    }
}

enum EventSource: String, Codable {
    case moodle
    case school
    case exam
    case system  // iOS Calendar events
    /// A school holiday, from the published academic calendar. Distinct from
    /// `.school` because these are the only rows the user can act on — a
    /// holiday offers the "still remind me" toggle — and because they are the
    /// ones that silence class reminders.
    case holiday

    /// The first or last day of a term, from the same feed.
    ///
    /// Deliberately not `.holiday`: a term boundary is an announcement,
    /// there is still class that day, and nothing is silenced. Folding the
    /// two together made these rows read "假日", which was simply wrong.
    case semester

    var color: Color {
        switch self {
        case .moodle: .moodleBlue
        case .school: .schoolOrange
        case .exam: .examRed
        case .system: .gray
        // Green reads as "no class" against school orange and exam red, and
        // is the one colour not already spoken for.
        case .holiday: .green
        // Neither a day off nor a deadline, so it borrows neither holiday
        // green nor exam red.
        case .semester: .indigo
        }
    }

    var label: String {
        switch self {
        case .moodle: "Moodle"
        case .school: String(localized: "calendar_source_school")
        case .exam: String(localized: "calendar_source_exam")
        case .system: String(localized: "feature_calendar")
        case .holiday: String(localized: "calendar_source_holiday")
        case .semester: String(localized: "calendar_source_semester")
        }
    }
}
