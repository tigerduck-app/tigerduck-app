import Foundation

/// The calendar's events: the Moodle rows rebuilt with each assignment round and the school's
/// calendar feed.
final class CalendarEventFiles: AccountScoped {
    private let cache: JSONFiles

    init(folders: CacheFolders = .app) {
        cache = folders.cacheFiles
    }

    static func forgetAccount(in storage: AccountStorage) {
        storage.folders.cacheFiles.remove("calendar_events.json")
    }

    func saveCalendarEvents(_ events: [SDCalendarEvent]) {
        cache.save(events.map { CachedCalendarEvent(from: $0) }, to: "calendar_events.json")
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        let dtos: [CachedCalendarEvent] = cache.load("calendar_events.json") ?? []
        return dtos.map { $0.toSDCalendarEvent() }
    }
}

private struct CachedCalendarEvent: Codable {
    let eventId: String
    let title: String
    let date: Date
    let sourceRaw: String

    init(from event: SDCalendarEvent) {
        eventId = event.eventId
        title = event.title
        date = event.date
        sourceRaw = event.sourceRaw
    }

    func toSDCalendarEvent() -> SDCalendarEvent {
        SDCalendarEvent(
            eventId: eventId,
            title: title,
            date: date,
            source: EventSource(rawValue: sourceRaw) ?? .school
        )
    }
}
