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
        EventSource(rawValue: sourceRaw) ?? .school
    }
}

enum EventSource: String, Codable {
    case moodle
    case school
    case exam

    var color: Color {
        switch self {
        case .moodle: .moodleBlue
        case .school: .schoolOrange
        case .exam: .examRed
        }
    }

    var label: String {
        switch self {
        case .moodle: "Moodle"
        case .school: "學校"
        case .exam: "考試"
        }
    }
}
