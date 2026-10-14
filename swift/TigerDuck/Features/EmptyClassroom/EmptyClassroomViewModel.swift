import Defaults
import Foundation
import Observation

/// The finder's state: the chosen day and period, that day's rooms, the user's classes that
/// day, and the building the user picked. Everything else on the screen derives from these.
@Observable
@MainActor
final class EmptyClassroomViewModel {
    /// Today and the 13 days after it.
    static let dayCount = 14

    enum Content: Equatable {
        case loading
        case rooms(CampusUsage)
        /// A weekend, a weekday outside the term, or a weekday the site answers with no rooms.
        case noData
        /// The site shows the weekly timetable on a holiday, so its rooms are not shown.
        case holiday(name: String)
        case failed(offline: Bool)
    }

    /// Whom the screen reads for, and whether that is still the signed-in account.
    struct Reader {
        let credentials: ClassroomUsageService.Credentials
        let isCurrent: @MainActor () -> Bool
    }

    private(set) var selectedDay: Date
    private(set) var selectedPeriod = 0
    private(set) var content = Content.loading
    private(set) var classes: [ClassStop] = []
    private(set) var pickedBuilding: String?

    /// Nil while no one is signed in. ``connect(_:)`` sets it from the app's account.
    @ObservationIgnored var reader: @MainActor () -> Reader? = { nil }

    @ObservationIgnored private let service: ClassroomUsageService
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let holidays: @MainActor (Date) -> [Holiday]
    @ObservationIgnored private let isInSession: @MainActor (Date) -> Bool
    @ObservationIgnored private let isClassDay: @MainActor (Date) -> Bool
    @ObservationIgnored private let loadCourses: @MainActor () -> [SDCourse]
    @ObservationIgnored private let rawRoom: @MainActor (String) -> String
    @ObservationIgnored private var courses: [SDCourse] = []
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The day the load in flight reads, and which load it is.
    @ObservationIgnored private var running: (day: Date, id: Int)?
    @ObservationIgnored private var loads = 0
    private let minuteTicker: MinuteTicker

    init(
        service: ClassroomUsageService? = nil,
        clock: @escaping () -> Date = { AppClock.now() },
        holidays: (@MainActor (Date) -> [Holiday])? = nil,
        isInSession: (@MainActor (Date) -> Bool)? = nil,
        isClassDay: (@MainActor (Date) -> Bool)? = nil,
        courses: (@MainActor () -> [SDCourse])? = nil,
        rawRoom: (@MainActor (String) -> String)? = nil
    ) {
        self.service = service ?? .shared
        self.clock = clock
        self.holidays = holidays ?? { AcademicCalendarStore.shared.calendar.holidays(on: $0) }
        self.isInSession = isInSession ?? { AcademicCalendarStore.shared.calendar.isInSession(on: $0) }
        self.isClassDay = isClassDay ?? { AcademicCalendarStore.shared.isClassDay($0) }
        loadCourses = courses ?? { CanonicalCourseProvider().currentCourses() }
        self.rawRoom = rawRoom ?? { NameAbbrService.shared.rawClassroom($0) }
        minuteTicker = MinuteTicker(now: clock)
        selectedDay = AppConstants.taipeiCalendar.startOfDay(for: clock())
        pickedBuilding = Defaults[.emptyClassroomBuilding]
    }

    func connect(_ authService: AuthService) {
        reader = { [weak authService] in
            guard let authService,
                  let studentId = authService.storedStudentId,
                  let password = authService.storedPassword else { return nil }
            let generation = authService.loginGeneration
            return Reader(
                credentials: .init(
                    studentId: studentId,
                    password: password,
                    generation: NTUSTSessionManager.shared.generation
                ),
                isCurrent: { [weak authService] in authService?.loginGeneration == generation }
            )
        }
    }

    // MARK: - Time

    /// The app clock, read again as each minute passes.
    var now: Date {
        _ = minuteTicker.tick
        return clock()
    }

    var today: Date { AppConstants.taipeiCalendar.startOfDay(for: now) }

    var days: [Date] {
        let today = today
        return (0..<Self.dayCount).compactMap {
            AppConstants.taipeiCalendar.date(byAdding: .day, value: $0, to: today)
        }
    }

    var isShowingToday: Bool {
        AppConstants.taipeiCalendar.isDate(selectedDay, inSameDayAs: now)
    }

    /// Periods already over on the day shown: none on a later day.
    var endedPeriods: Int {
        isShowingToday ? EmptyClassroomSchedule.endedPeriods(at: now) : 0
    }

    /// The period the dot marks: the one in progress, or the next in a break, today only.
    var currentPeriod: Int? {
        isShowingToday ? EmptyClassroomSchedule.upcomingPeriod(at: now) : nil
    }

    /// The next teaching day after the one shown, within the days the menu offers.
    var nextTeachingDay: Date? {
        guard let last = days.last else { return nil }
        let remaining = AppConstants.taipeiCalendar.dateComponents([.day], from: selectedDay, to: last).day ?? 0
        return EmptyClassroomSchedule.nextTeachingDay(after: selectedDay, horizon: remaining, isTeachingDay: isTeachingDay)
    }

    private func dayOff(_ day: Date) -> EmptyClassroomSchedule.DayOff? {
        EmptyClassroomSchedule.dayOff(day, holidays: holidays, isInSession: isInSession)
    }

    private func isTeachingDay(_ day: Date) -> Bool {
        dayOff(day) == nil
    }

    // MARK: - Derived from the day's rooms

    var usage: CampusUsage? {
        if case .rooms(let usage) = content { return usage }
        return nil
    }

    var suggestion: RoomSuggestion? {
        usage.flatMap { RoomSuggestion.make(rooms: $0.rooms, period: selectedPeriod, classes: classes) }
    }

    var directory: BuildingDirectory? {
        usage.map { BuildingDirectory(rooms: $0.rooms, period: selectedPeriod) }
    }

    func shownBuilding(in directory: BuildingDirectory, suggestion: RoomSuggestion?) -> String? {
        directory.defaultBuilding(
            picked: pickedBuilding,
            suggested: suggestion?.candidates.first?.place?.building
        )
    }

    func buildingName(_ code: String) -> String {
        usage?.buildingNames[code] ?? code
    }

    // MARK: - Actions

    /// Opens on the current period, or the next teaching day's first, the first time and after
    /// the day shown has passed; then loads the day.
    func appear() {
        isOnScreen = true
        if !hasOpened || selectedDay < today {
            let opening = EmptyClassroomSchedule.opening(
                at: now, horizon: Self.dayCount - 1, isTeachingDay: isTeachingDay
            )
            selectedDay = opening.day
            selectedPeriod = opening.period
            hasOpened = true
        }
        reloadCourses()
        load(force: false)
    }

    /// iOS sends no `onAppear` when the app comes back to the foreground, while today's rooms
    /// have aged and the day shown may have passed, so the screen on view reads again.
    func returnToApp() {
        guard isOnScreen else { return }
        appear()
    }

    /// The screen went away: a read it started would otherwise go on, and queue behind it the
    /// reads of the next visits.
    func disappear() {
        isOnScreen = false
        stopLoading()
    }

    /// The signed-in account changed: what the screen holds belonged to the one before.
    func accountChanged() {
        stopLoading()
        content = .loading
        pickedBuilding = Defaults[.emptyClassroomBuilding]
        reloadCourses()
        load(force: false)
    }

    /// The user's classes come from the class table, which a sync can change while the screen
    /// is open.
    func reloadCourses() {
        courses = loadCourses()
        refreshClasses()
    }

    func select(day: Date) {
        let day = AppConstants.taipeiCalendar.startOfDay(for: day)
        guard day != selectedDay else { return }
        selectedDay = day
        refreshClasses()
        load(force: false)
    }

    func select(period: Int) {
        guard EmptyClassroomSchedule.periodIDs.indices.contains(period) else { return }
        selectedPeriod = period
    }

    func pick(building: String) {
        pickedBuilding = building
        Defaults[.emptyClassroomBuilding] = building
    }

    /// A pull: reads the day again even when it was read moments ago.
    func refresh() async {
        load(force: true)
        await loadTask?.value
    }

    func retry() {
        content = .loading
        load(force: true)
    }

    private func refreshClasses() {
        let slots = CourseTimeSlot.meetingSlots(from: courses, on: selectedDay, isClassDay: isClassDay)
        classes = ClassStop.stops(from: slots, rawRoom: rawRoom)
    }

    private func stopLoading() {
        loadTask?.cancel()
        loadTask = nil
        running = nil
    }

    private func load(force: Bool) {
        let day = selectedDay
        // A repeated appear() while this day loads keeps that load. Leaving the screen
        // already stopped it, so coming back after a disappear() always starts a new read.
        if !force, running?.day == day { return }
        stopLoading()
        switch dayOff(day) {
        case .weekend, .outOfTerm:
            content = .noData
            return
        case .holiday(let holiday):
            content = .holiday(name: holiday.name())
            return
        case nil:
            break
        }
        guard let reader = reader() else { return }
        if let kept = service.keptUsage(on: day) {
            content = kept.rooms.isEmpty ? .noData : .rooms(kept)
        } else {
            content = .loading
        }
        let isToday = AppConstants.taipeiCalendar.isDate(day, inSameDayAs: now)
        loads &+= 1
        let id = loads
        running = (day, id)
        loadTask = Task { [weak self, service] in
            let outcome: Result<CampusUsage, any Error>
            do {
                outcome = .success(try await service.usage(
                    on: day, isToday: isToday, force: force, credentials: reader.credentials
                ))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            if running?.id == id { running = nil }
            guard !Task.isCancelled, selectedDay == day, reader.isCurrent() else { return }
            switch outcome {
            case .success(let usage):
                content = usage.rooms.isEmpty ? .noData : .rooms(usage)
            case .failure(let error):
                // A day already on screen stays when reading it again fails.
                guard !(error is CancellationError), content == .loading else { return }
                content = .failed(offline: Self.isOffline(error))
            }
        }
    }

    private static func isOffline(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .internationalRoamingOff,
        ].contains(code)
    }

    // MARK: - Labels

    /// Today and tomorrow say so before the date, as in "Today Wed, 10/14".
    func dayLabel(_ day: Date) -> String {
        let calendar = AppConstants.taipeiCalendar
        let date = Self.dateText(day)
        if calendar.isDate(day, inSameDayAs: today) {
            return "\(String(localized: "calendar_today")) \(date)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "\(String(localized: "widget_tomorrow")) \(date)"
        }
        return date
    }

    /// The locale's short date with its weekday, one letter long where the locale's one-letter
    /// weekdays are all different, as Chinese ones are.
    static func dateText(_ day: Date) -> String {
        var symbols = Calendar(identifier: .gregorian)
        symbols.locale = .autoupdatingCurrent
        let narrow = symbols.veryShortWeekdaySymbols
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
            .weekday(Set(narrow).count == narrow.count ? .narrow : .abbreviated)
        style.timeZone = AppConstants.taipeiTimeZone
        style.calendar = Calendar(identifier: .gregorian)
        return day.formatted(style)
    }

    static func timeRange(of period: Int) -> String {
        guard let range = EmptyClassroomSchedule.timeRange(of: period) else { return "" }
        return "\(range.start)–\(range.end)"
    }
}
