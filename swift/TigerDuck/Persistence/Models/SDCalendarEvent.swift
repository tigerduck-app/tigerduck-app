import Foundation
import SwiftData
import SwiftUI
import TigerDuckCore

@Model
final class SDCalendarEvent {
    @Attribute(.unique) var eventId: String
    var title: String
    var date: Date
    var sourceRaw: String

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
        AppLogger.breadcrumb(
            "SDCalendarEvent: unknown sourceRaw '\(sourceRaw)' coerced to .school",
            category: "model.calendar"
        )
        return .school
    }

    var isAllDay: Bool {
        switch source {
        case .holiday, .semester:
            return true
        case .school:
            return TaipeiTime.calendar.startOfDay(for: date) == date
        case .moodle, .exam:
            return false
        }
    }
}

enum EventSource: String, Codable {
    case moodle
    case school
    case exam
    case holiday

    case semester

    var color: Color {
        switch self {
        case .moodle: .moodleBlue
        case .school: .schoolOrange
        case .exam: .examRed
        case .holiday: .green
        case .semester: .indigo
        }
    }

    var label: String {
        switch self {
        case .moodle: "Moodle"
        case .school: String(localized: "calendar_source_school")
        case .exam: String(localized: "calendar_source_exam")
        case .holiday: String(localized: "calendar_source_holiday")
        case .semester: String(localized: "calendar_source_semester")
        }
    }
}
