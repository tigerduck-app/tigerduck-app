import SwiftUI
import EventKit

@Observable
final class CalendarViewModel {
    var events: [SDCalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now

    private let eventStore = EKEventStore()
    var calendarAccessGranted = false
    private var hasLoaded = false

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

    func goToToday() {
        withAnimation(.smoothSpring) {
            selectedDate = .now
            displayedMonth = .now
        }
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        // Load cached events first
        events = DataCache.shared.loadCalendarEvents()

        requestCalendarAccess()

        Task {
            await fetchMoodleEvents(authService: authService)
            await fetchSchoolEvents()
        }
    }

    func refresh(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        await MainActor.run { manager.loadingState = .loading }

        await fetchMoodleEvents(authService: authService)
        await fetchSchoolEvents()
        loadSystemCalendarEvents()

        await MainActor.run { manager.loadingState = .loaded }
    }

    private func fetchMoodleEvents(authService: AuthService) async {
        let assignments = await KMPServiceBridge.fetchAssignments(authService: authService)

        let moodleEvents = assignments.map { assignment in
            SDCalendarEvent(
                eventId: "moodle-\(assignment.assignmentId)",
                title: "\(assignment.title)",
                date: assignment.dueDate,
                source: .moodle
            )
        }

        await MainActor.run {
            // Remove old moodle events, keep system events
            events.removeAll { $0.source == .moodle }
            events.append(contentsOf: moodleEvents)
            DataCache.shared.saveCalendarEvents(events)
        }
    }

    private func fetchSchoolEvents() async {
        let schoolEvents = await CalendarService.fetchAndParseICS()
        guard !schoolEvents.isEmpty else { return }

        await MainActor.run {
            events.removeAll { $0.source == .school }
            events.append(contentsOf: schoolEvents)
            DataCache.shared.saveCalendarEvents(events)
        }
    }

    func requestCalendarAccess() {
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarAccessGranted = granted
                if granted {
                    loadSystemCalendarEvents()
                }
            } catch {
                calendarAccessGranted = false
            }
        }
    }

    @MainActor
    private func loadSystemCalendarEvents() {
        let cal = Calendar.current
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

        let existingKeys = Set(events.map { "\($0.title)-\($0.date.startOfDay)" })
        let newEvents = systemEvents.filter { !existingKeys.contains("\($0.title)-\($0.date.startOfDay)") }
        events.append(contentsOf: newEvents)
    }
}
