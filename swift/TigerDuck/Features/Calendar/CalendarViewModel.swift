import SwiftUI
import EventKit

@Observable
final class CalendarViewModel {
    var events: [SDCalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now {
        didSet { calendarDays = Self.buildCalendarDays(for: displayedMonth) }
    }

    private(set) var calendarDays: [Date?] = Self.buildCalendarDays(for: .now)

    private let eventStore = EKEventStore()
    var calendarAccessGranted = false
    private var hasLoaded = false

    /// Pre-grouped events by day for O(1) lookups in the month grid.
    private var eventsByDay: [DateComponents: [SDCalendarEvent]] = [:]

    var eventsForSelectedDate: [SDCalendarEvent] {
        events.filter { $0.date.isSameDay(as: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    func eventsOnDate(_ date: Date) -> [SDCalendarEvent] {
        let key = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return eventsByDay[key] ?? []
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
        setEvents(DataCache.shared.loadCalendarEvents())

        requestCalendarAccess()

        Task {
            async let moodleEvents = fetchMoodleEvents(authService: authService)
            async let schoolEvents = fetchSchoolEvents()
            let (moodle, school) = await (moodleEvents, schoolEvents)

            await MainActor.run {
                var updated = events
                updated.removeAll { $0.source == .moodle }
                updated.append(contentsOf: moodle)
                updated.removeAll { $0.source == .school }
                updated.append(contentsOf: school)
                setEvents(updated)
                DataCache.shared.saveCalendarEvents(updated)
            }
        }
    }

    func refresh(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        await MainActor.run { manager.loadingState = .loading }

        async let moodleEvents = fetchMoodleEvents(authService: authService)
        async let schoolEvents = fetchSchoolEvents()
        let (moodle, school) = await (moodleEvents, schoolEvents)

        await MainActor.run {
            var updated = events
            updated.removeAll { $0.source == .moodle }
            updated.append(contentsOf: moodle)
            updated.removeAll { $0.source == .school }
            updated.append(contentsOf: school)
            setEvents(updated)
            DataCache.shared.saveCalendarEvents(updated)
            loadSystemCalendarEvents()
            manager.loadingState = .loaded
        }
    }

    private func fetchMoodleEvents(authService: AuthService) async -> [SDCalendarEvent] {
        let assignments = await KMPServiceBridge.fetchAssignments(authService: authService)
        return assignments.map { assignment in
            SDCalendarEvent(
                eventId: "moodle-\(assignment.assignmentId)",
                title: "\(assignment.title)",
                date: assignment.dueDate,
                source: .moodle
            )
        }
    }

    private func fetchSchoolEvents() async -> [SDCalendarEvent] {
        await CalendarService.fetchAndParseICS()
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
                source: .system
            )
        }

        let existingKeys = Set(events.filter { $0.source != .system }.map { "\($0.title)-\($0.date.startOfDay)" })
        let newEvents = systemEvents.filter { !existingKeys.contains("\($0.title)-\($0.date.startOfDay)") }
        var updated = events
        updated.removeAll { $0.source == .system }
        updated.append(contentsOf: newEvents)
        setEvents(updated)
    }

    private static func buildCalendarDays(for month: Date) -> [Date?] {
        let cal = Calendar.current
        let start = month.startOfMonth
        let daysInMonth = month.daysInMonth
        let firstWeekday = month.firstWeekdayOfMonth // 1=Sunday

        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 1...daysInMonth {
            var components = cal.dateComponents([.year, .month], from: start)
            components.day = day
            days.append(cal.date(from: components))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private func setEvents(_ newEvents: [SDCalendarEvent]) {
        events = newEvents
        let cal = Calendar.current
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
