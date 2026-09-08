import SwiftUI
import EventKit

// `EKEventStore.requestFullAccessToEvents` invokes its callback off
// the main actor; the previous `Task { ... }` (no @MainActor) then
// mutated `calendarAccessGranted`, `events`, and `eventsByDay` from a
// background context while SwiftUI was reading them — a real data
// race on @Observable storage. Annotating the whole VM @MainActor
// confines mutations correctly without sprinkling MainActor.run.
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
    // `nonisolated(unsafe)` so `deinit` (which is nonisolated under
    // Swift 6 on a @MainActor class) can read this to remove the
    // NotificationCenter observer at end-of-life. `@ObservationIgnored`
    // is required for the isolation modifier to take effect — without
    // it the `@Observable` macro replaces the stored var with a
    // computed accessor, which strips the modifier and produces a
    // "'nonisolated(unsafe)' has no effect" warning.
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
            // The notification is delivered on the main queue, but the
            // closure crosses into the @MainActor class — hop explicitly
            // so accessing `events` / calling `setEvents` is sound under
            // Swift 6 strict concurrency.
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

    /// Semester boundaries and school holidays, from the published academic
    /// calendar.
    ///
    /// Rebuilt on every merge rather than cached: the holiday name is
    /// locale-dependent and the app language can change under us. Cheap —
    /// a few dozen rows off an in-memory value.
    ///
    /// One row per holiday and one at each end of a term, never one per day:
    /// a week-long 寒假 is a single thing that happened, and eight identical
    /// rows would bury the Moodle deadlines this screen exists to show.
    /// `calendar` is passed rather than defaulted from the store because a
    /// default argument is evaluated in a nonisolated context, and the store
    /// is `@MainActor`. Callers on the main actor hand it in.
    static func academicEvents(
        calendar: AcademicCalendar,
        locale: Locale = .current
    ) -> [SDCalendarEvent] {
        let holidays = calendar.holidays.map { holiday in
            SDCalendarEvent(
                eventId: "\(holidayEventPrefix)\(holiday.id)",
                title: holiday.name(for: locale),
                date: holiday.start,
                source: .holiday
            )
        }
        let boundaries = calendar.terms.flatMap { term -> [SDCalendarEvent] in
            let label = term.code.count == 4
                ? "\(term.code.prefix(3))-\(term.code.suffix(1))"
                : term.code
            return [
                SDCalendarEvent(
                    eventId: "term-start:\(term.code)",
                    title: String(format: String(localized: "calendar_semester_start"), label),
                    date: term.start,
                    source: .semester
                ),
                SDCalendarEvent(
                    eventId: "term-end:\(term.code)",
                    title: String(format: String(localized: "calendar_semester_end"), label),
                    date: term.end,
                    source: .semester
                ),
            ]
        }
        return holidays + boundaries
    }

    static let holidayEventPrefix = "holiday:"

    /// The holiday a row belongs to, or nil for a term boundary or an
    /// ordinary event. Boundaries return nil deliberately: they are
    /// announcements, not days off, so there is nothing to opt back into.
    static func holidayID(for event: SDCalendarEvent) -> Int? {
        guard event.eventId.hasPrefix(holidayEventPrefix) else { return nil }
        return Int(event.eventId.dropFirst(holidayEventPrefix.count))
    }

    private func setEvents(_ newEvents: [SDCalendarEvent]) {
        // Merged here rather than at each call site because this is the one
        // funnel every load path goes through, including the sign-out reset.
        // Both academic sources are dropped and rebuilt from the feed, so a
        // boundary left over from the build that still filed them under
        // `.holiday` is not kept forever from the cache.
        let newEvents = newEvents.filter { $0.source != .holiday && $0.source != .semester }
            + Self.academicEvents(calendar: AcademicCalendarStore.shared.calendar)
        events = newEvents
        let cal = AppConstants.taipeiCalendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
