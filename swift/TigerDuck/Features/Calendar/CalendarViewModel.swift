import SwiftUI
import EventKit

// `EKEventStore.requestFullAccessToEvents` calls back off the main actor, and
// mutating state from there races SwiftUI's reads of @Observable storage.
// @MainActor on the whole type confines mutations without scattered `MainActor.run`.
@MainActor
@Observable
final class CalendarViewModel {
    var events: [SDCalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now {
        didSet { calendarDays = Self.buildCalendarDays(for: displayedMonth) }
    }

    private(set) var calendarDays: [Date?] = CalendarViewModel.buildCalendarDays(for: .now)

    private let eventStore = EKEventStore()
    var calendarAccessGranted = false
    private var hasLoaded = false
    // `nonisolated(unsafe)` lets `deinit`, nonisolated under Swift 6, read this to
    // remove the observer. `@ObservationIgnored` is required: without it `@Observable`
    // makes this a computed accessor, and the modifier has no effect (a warning).
    @ObservationIgnored
    private nonisolated(unsafe) var dataObserver: Any? = nil

    /// Pre-grouped events by day for O(1) lookups in the month grid.
    private var eventsByDay: [DateComponents: [SDCalendarEvent]] = [:]

    var eventsForSelectedDate: [SDCalendarEvent] {
        events.filter { $0.date.isSameDay(as: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    func eventsOnDate(_ date: Date) -> [SDCalendarEvent] {
        let key = AppConstants.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        return eventsByDay[key] ?? []
    }

    func previousMonth() {
        displayedMonth = AppConstants.taipeiCalendar.date(byAdding: .month, value: -1, to: displayedMonth)!
    }

    func nextMonth() {
        displayedMonth = AppConstants.taipeiCalendar.date(byAdding: .month, value: 1, to: displayedMonth)!
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

        setEvents(DataCache.shared.loadCalendarEvents())
        requestCalendarAccess()

        // backgroundSync() on app launch handles the network refresh
        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, but the closure crosses into this
            // @MainActor class, so hop explicitly to make touching `events` and
            // calling `setEvents` sound under Swift 6 strict concurrency.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fresh = DataCache.shared.loadCalendarEvents()
                var updated = fresh
                updated.removeAll { $0.source == .system }
                updated.append(contentsOf: self.events.filter { $0.source == .system })
                self.setEvents(updated)
            }
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func triggerRefresh(authService: AuthService) {
        Task { await refresh(authService: authService) }
    }

    func refresh(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        let startGeneration = authService.loginGeneration
        // Pre-flight captive-portal probe so a hotel/campus Wi-Fi login
        // page doesn't surface as an opaque ATS pin failure from the
        // actual Moodle / ICS fetch downstream.
        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }
        await MainActor.run { manager.loadingState = .loading }

        MoodleEnrolledCoursesService.dropSharedAnswer()
        async let moodleEvents = fetchMoodleEvents(authService: authService)
        async let schoolEvents = fetchSchoolEvents()
        let (moodle, school) = await (moodleEvents, schoolEvents)

        await MainActor.run {
            // Bail out if logout happened mid-fetch — otherwise the previous
            // user's moodle events would be saved back into the calendar
            // cache after AppState.clearUserScopedData() already purged it.
            guard authService.loginGeneration == startGeneration else {
                manager.loadingState = .loaded
                return
            }
            // Preserve system events (from EventKit); only replace network-sourced events
            let systemEvents = events.filter { $0.source == .system }
            var updated = systemEvents
            updated.append(contentsOf: moodle)
            updated.append(contentsOf: school)
            setEvents(updated)
            // Save only non-system events to cache
            DataCache.shared.saveCalendarEvents(updated.filter { $0.source != .system })
            loadSystemCalendarEvents()
            manager.loadingState = .loaded
        }
    }

    private func fetchMoodleEvents(authService: AuthService) async -> [SDCalendarEvent] {
        let assignments = await AppServiceBridge.fetchAssignments(authService: authService)
        return assignments.map { assignment in
            SDCalendarEvent(
                eventId: "moodle-\(assignment.assignmentId)",
                title: assignment.displayTitle,
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
                AppLogger.captureError(error, context: ["feature": "calendar.requestAccess"])
                calendarAccessGranted = false
            }
        }
    }

    @MainActor
    private func loadSystemCalendarEvents() {
        let cal = AppConstants.taipeiCalendar
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

        struct DedupKey: Hashable { let title: String; let day: Date }
        let existingKeys = Set(events.filter { $0.source != .system }.map { DedupKey(title: $0.title, day: $0.date.startOfDay) })
        let newEvents = systemEvents.filter { !existingKeys.contains(DedupKey(title: $0.title, day: $0.date.startOfDay)) }
        var updated = events
        updated.removeAll { $0.source == .system }
        updated.append(contentsOf: newEvents)
        setEvents(updated)
    }

    private static func buildCalendarDays(for month: Date) -> [Date?] {
        let cal = AppConstants.taipeiCalendar
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
        // Merged here because every load path, the sign-out reset included, goes
        // through this funnel. Both academic sources are rebuilt from the feed, so a
        // cached boundary an older build filed under `.holiday` does not linger.
        let newEvents = newEvents.filter { $0.source != .holiday && $0.source != .semester }
            + AcademicCalendarStore.shared.calendar.calendarEvents()
        events = newEvents
        let cal = AppConstants.taipeiCalendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
