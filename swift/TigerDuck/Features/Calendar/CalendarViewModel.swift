import SwiftUI
import EventKit

@Observable
final class CalendarViewModel {
    var events: [SDCalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now

    private let eventStore = EKEventStore()
    var calendarAccessGranted = false

    var eventsForSelectedDate: [SDCalendarEvent] {
        events.filter { $0.date.isSameDay(as: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    func eventsOnDate(_ date: Date) -> [SDCalendarEvent] {
        events.filter { $0.date.isSameDay(as: date) }
    }

    func previousMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth)!
    }

    func nextMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth)!
    }

    func load() {
        events = MockData.calendarEvents
        requestCalendarAccess()
    }

    func requestCalendarAccess() {
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarAccessGranted = granted
                if granted {
                    await loadSystemCalendarEvents()
                }
            } catch {
                calendarAccessGranted = false
            }
        }
    }

    @MainActor
    private func loadSystemCalendarEvents() {
        let cal = Calendar.current
        // Load events for the current month +/- 1 month
        guard let startDate = cal.date(byAdding: .month, value: -1, to: displayedMonth.startOfMonth),
              let endDate = cal.date(byAdding: .month, value: 2, to: displayedMonth.startOfMonth) else { return }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)

        let systemEvents = ekEvents.map { ekEvent in
            SDCalendarEvent(
                eventId: ekEvent.eventIdentifier ?? UUID().uuidString,
                title: ekEvent.title ?? "",
                date: ekEvent.startDate,
                source: .school
            )
        }

        // Merge system events with app events, avoid duplicates by title+date
        let existingKeys = Set(events.map { "\($0.title)-\($0.date.startOfDay)" })
        let newEvents = systemEvents.filter { !existingKeys.contains("\($0.title)-\($0.date.startOfDay)") }
        events.append(contentsOf: newEvents)
    }
}
