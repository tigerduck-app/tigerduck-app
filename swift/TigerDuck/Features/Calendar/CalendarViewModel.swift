import SwiftUI
import UIKit

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
    @ObservationIgnored
    private nonisolated(unsafe) var dataObserver: Any? = nil

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
        let startGeneration = authService.loginGeneration
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
            guard authService.loginGeneration == startGeneration else {
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
        let cal = AppConstants.taipeiCalendar
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
        let cal = AppConstants.taipeiCalendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
