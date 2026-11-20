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

    @ObservationIgnored private var storeObservation: StoreObservation?
    @ObservationIgnored private let assignmentStore: AssignmentStore
    @ObservationIgnored private let courseStore: CourseStore

    private var eventsByDay: [DateComponents: [AssignmentStore.CalendarEvent]] = [:]
    private var assignmentsByEventId: [String: AssignmentStore.Assignment] = [:]

    init(assignments: AssignmentStore = .shared, courses: CourseStore = .shared) {
        assignmentStore = assignments
        courseStore = courses
    }

    func assignment(for event: AssignmentStore.CalendarEvent) -> AssignmentStore.Assignment? {
        event.source == .moodle ? assignmentsByEventId[event.eventId] : nil
    }

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

    func load(moodle: @escaping () -> MoodleCacheContext?) {
        guard storeObservation == nil else { return }

        setEvents(assignmentStore.loadCalendarEvents(), moodle: moodle())

        storeObservation = StoreObservation(read: { [assignmentStore, courseStore] in
            _ = (AppDataRevision.current, assignmentStore.revision, courseStore.revision)
        }) { [weak self] in
            guard let self else { return }
            setEvents(assignmentStore.loadCalendarEvents(), moodle: moodle())
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
        guard assignmentStore.saveCalendarEvents(updated, for: signIn) else { return }
        setEvents(updated, moodle: MoodleCacheContext.signedIn(authService, for: signIn))
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

    private func openableAssignments(moodle: MoodleCacheContext?) -> [String: AssignmentStore.Assignment] {
        let cachedRecordIds = moodle.map { Set(MoodleCourseAssignments.records(in: $0).map { String($0.assignId) }) } ?? []
        return Dictionary(
            assignmentStore.loadAssignments().ofTimetable(CanonicalCourseProvider(courses: courseStore).currentCourses())
                .filter { MoodleCourseStore.opens($0, cachedRecordIds: cachedRecordIds) }
                .map { ($0.calendarEventId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func setEvents(_ newEvents: [AssignmentStore.CalendarEvent], moodle: MoodleCacheContext?) {
        let newEvents = newEvents.filter { $0.source != .holiday && $0.source != .semester }
            + SchoolCalendar.events()
        events = newEvents
        assignmentsByEventId = openableAssignments(moodle: moodle)
        let cal = TaipeiTime.calendar
        eventsByDay = Dictionary(grouping: newEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }
}
