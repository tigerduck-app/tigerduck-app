import Foundation
import SwiftData
import SwiftUI

@Model
final class SDCalendarEvent {
    @Attribute(.unique) var eventId: String
    var title: String
    var date: Date
    var sourceRaw: String // "moodle", "school", "exam"

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
}

enum EventSource: String, Codable {
    case moodle
    case school
    case exam
    case system  // iOS Calendar events

    var color: Color {
        switch self {
        case .moodle: .moodleBlue
        case .school: .schoolOrange
        case .exam: .examRed
        case .system: .gray
        }
    }

    var label: String {
        switch self {
        case .moodle: "Moodle"
        case .school: String(localized: "calendar_event_source_school")
        case .exam: String(localized: "calendar_event_source_exam")
        case .system: String(localized: "feature_calendar")
        }
    }
}
