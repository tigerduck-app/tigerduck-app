import SwiftUI
import UIKit
import TigerDuckCore

@MainActor
@Observable
final class CalendarViewModel {
    var events: [SDCalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now {
        didSet { calendarDays = Self.buildCalendarDays(for: displayedMonth) }
    }

    private(set) var calendarDays: [Date?] = CalendarViewModel.buildCalendarDays(for: .now)

    private var hasLoaded = false
    // `nonisolated(unsafe)` lets `deinit`, nonisolated under Swift 6, read this to
    // remove the observer. `@ObservationIgnored` is required: without it `@Observable`
    // makes this a computed accessor, and the modifier has no effect (a warning).
    @ObservationIgnored
    private nonisolated(unsafe) var dataObserver: Any? = nil

    private var eventsByDay: [DateComponents: [SDCalendarEvent]] = [:]

    var eventsForSelectedDate: [SDCalendarEvent] {
        events.filter { $0.date.isSameDay(as: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    func eventsOnDate(_ date: Date) -> [SDCalendarEvent] {
        let key = TaipeiTime.calendar.dateComponents([.year, .month, .day], from: date)
        return eventsByDay[key] ?? []
    }

    func previousMonth() {
        displayedMonth = TaipeiTime.calendar.date(byAdding: .month, value: -1, to: displayedMonth)!
    }

    func nextMonth() {
        displayedMonth = TaipeiTime.calendar.date(byAdding: .month, value: 1, to: displayedMonth)!
    }

    func goToToday() {
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smoothSpring) {
            selectedDate = .now
            displayedMonth = .now
        }
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        setEvents(DataCache.shared.loadCalendarEvents())

        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, but the closure crosses into this
            // @MainActor class, so hop explicitly to make calling `setEvents` sound
            // under Swift 6 strict concurrency.
            Task { @MainActor [weak self] in
                self?.setEvents(DataCache.shared.loadCalendarEvents())
            }
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var isRefreshing = false

    func triggerRefresh(authService: AuthService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await refresh(authService: authService)
            isRefreshing = false
        }
    }

    func refresh(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        let ticket = authService.session.ticket
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
            guard authService.session.isCurrent(ticket) else {
                manager.loadingState = .loaded
                return
            }
            let updated = moodle + (school ?? events.filter { $0.source == .school })
            setEvents(updated)
            DataCache.shared.saveCalendarEvents(updated)
            manager.loadingState = .loaded
        }
    }

    private func fetchMoodleEvents(authService: AuthService) async -> [SDCalendarEvent] {
        await AppServiceBridge.fetchAssignments(authService: authService, recheckSubmissions: true)
            .map(AppServiceBridge.moodleCalendarEvent)
    }

    private func fetchSchoolEvents() async -> [SDCalendarEvent]? {
        await CalendarService.fetchAndParseICS()
    }

    private static func buildCalendarDays(for month: Date) -> [Date?] {
        let cal = TaipeiTime.calendar
        let start = month.startOfMonth
        let daysInMonth = month.daysInMonth
        let firstWeekday = month.firstWeekdayOfMonth

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
        let newEvents = newEvents.filter { $0.source != .holiday && $0.source != .semester }
            + AcademicCalendarStore.shared.calendar.calendarEvents()
        events = newEvents
        let cal = TaipeiTime.calendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
