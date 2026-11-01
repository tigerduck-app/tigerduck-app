import Foundation
import TigerDuckCore

@MainActor
@Observable
final class CalendarViewModel {
    var events: [AssignmentStore.CalendarEvent] = []
    var selectedDate: Date = .now
    var displayedMonth: Date = .now {
        didSet { calendarDays = Self.buildCalendarDays(for: displayedMonth) }
    }

    private(set) var calendarDays: [Date?] = CalendarViewModel.buildCalendarDays(for: .now)

    private var hasLoaded = false
    @ObservationIgnored private var storeObservation: StoreObservation?

    private var eventsByDay: [DateComponents: [AssignmentStore.CalendarEvent]] = [:]

    var eventsForSelectedDate: [AssignmentStore.CalendarEvent] {
        events.filter { $0.date.isSameDay(as: selectedDate) }
            .sorted { $0.date < $1.date }
    }

    func eventsOnDate(_ date: Date) -> [AssignmentStore.CalendarEvent] {
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
        selectedDate = .now
        displayedMonth = .now
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        setEvents(AssignmentStore.shared.loadCalendarEvents())

        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.setEvents(AssignmentStore.shared.loadCalendarEvents())
        }
    }

    private var isRefreshing = false

    func triggerRefresh(authService: AuthService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let signIn = authService.session.currentSignIn
        Task {
            await refresh(authService: authService, for: signIn)
            isRefreshing = false
        }
    }

    func refresh(authService: AuthService, for signIn: SignIn) async {
        guard await SchoolRefresh.begin() else { return }
        SchoolRefresh.dropMoodleCourses()
        async let moodleEvents = SchoolRefresh.moodleEvents(authService: authService, for: signIn)
        async let schoolEvents = SchoolRefresh.schoolEvents()
        let (moodle, school) = await (moodleEvents, schoolEvents)
        defer { SchoolRefresh.end() }
        let updated = moodle + (school ?? events.filter { $0.source == .school })
        guard AssignmentStore.shared.saveCalendarEvents(updated, for: signIn) else { return }
        setEvents(updated)
    }

    static func buildCalendarDays(for month: Date) -> [Date?] {
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

    private func setEvents(_ newEvents: [AssignmentStore.CalendarEvent]) {
        let newEvents = newEvents.filter { $0.source != .holiday && $0.source != .semester }
            + SchoolCalendar.events()
        events = newEvents
        let cal = TaipeiTime.calendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
