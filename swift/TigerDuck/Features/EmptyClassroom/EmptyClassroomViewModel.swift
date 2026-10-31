import Defaults
import Foundation
import Observation
import TigerDuckCore

@Observable
@MainActor
final class EmptyClassroomViewModel {
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

    struct Reader {
        let credentials: ClassroomUsageService.Credentials
        let isCurrent: @MainActor () -> Bool
    }

    private(set) var selectedDay: Date {
        didSet { if selectedDay != oldValue { openRoomName = nil } }
    }
    private(set) var selectedPeriod = 0
    private(set) var content = Content.loading {
        didSet { if openRoomName != nil, openRoom == nil { openRoomName = nil } }
    }
    private(set) var siteStatus = ServerStatus.unknown
    private(set) var syncedAt: Date?
    private(set) var isReading = false
    private(set) var classes: [ClassStop] = []
    private(set) var pickedBuilding: String?
    private(set) var openRoomName: String?

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
        selectedDay = TaipeiTime.calendar.startOfDay(for: clock())
        pickedBuilding = Defaults[.emptyClassroomBuilding]
    }

    func connect(_ authService: AuthService) {
        reader = { [weak authService] in
            guard let authService,
                  let studentId = authService.storedStudentId,
                  let password = authService.storedPassword else { return nil }
            return Reader(
                credentials: .init(studentId: studentId, password: password, signIn: AccountSession.school.ticket),
                isCurrent: authService.session.currentCheck()
            )
        }
    }

    var now: Date {
        _ = minuteTicker.tick
        return clock()
    }

    var today: Date { TaipeiTime.calendar.startOfDay(for: now) }

    var days: [Date] {
        let today = today
        return (0..<Self.dayCount).compactMap {
            TaipeiTime.calendar.date(byAdding: .day, value: $0, to: today)
        }
    }

    var isShowingToday: Bool {
        TaipeiTime.calendar.isDate(selectedDay, inSameDayAs: now)
    }

    var endedPeriods: Int {
        isShowingToday ? EmptyClassroomSchedule.endedPeriods(at: now) : 0
    }

    var currentPeriod: Int? {
        isShowingToday ? EmptyClassroomSchedule.upcomingPeriod(at: now) : nil
    }

    var nextTeachingDay: Date? {
        guard let last = days.last else { return nil }
        let remaining = TaipeiTime.calendar.dateComponents([.day], from: selectedDay, to: last).day ?? 0
        return EmptyClassroomSchedule.nextTeachingDay(after: selectedDay, horizon: remaining, isTeachingDay: isTeachingDay)
    }

    private func dayOff(_ day: Date) -> EmptyClassroomSchedule.DayOff? {
        EmptyClassroomSchedule.dayOff(day, holidays: holidays, isInSession: isInSession)
    }

    private func isTeachingDay(_ day: Date) -> Bool {
        dayOff(day) == nil
    }

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

    var openRoom: RoomUsage? {
        guard let openRoomName else { return nil }
        return usage?.rooms.first { $0.room == openRoomName }
    }

    func shownBuilding(in directory: BuildingDirectory, suggestion: RoomSuggestion?) -> String? {
        directory.defaultBuilding(
            picked: pickedBuilding,
            suggested: suggestion?.candidates.first?.place?.building
        )
    }

    func buildingName(_ code: String) -> String {
        CampusBuildingName.of(code) ?? usage?.buildingNames[code] ?? code
    }

    func appear() {
        isOnScreen = true
        if !hasOpened || selectedDay < today || selectedPeriod < endedPeriods {
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

    func disappear() {
        isOnScreen = false
    }

    func accountChanged() {
        stopLoading()
        show(.loading)
        siteStatus = service.siteStatus
        pickedBuilding = Defaults[.emptyClassroomBuilding]
        reloadCourses()
        guard isOnScreen else { return }
        load(force: false)
    }

    func reloadCourses() {
        courses = loadCourses()
        refreshClasses()
    }

    func dataDidUpdate() {
        reloadCourses()
        guard let off = dayOff(selectedDay) else { return }
        stopLoading()
        show(Self.content(for: off))
    }

    func select(day: Date) {
        let day = TaipeiTime.calendar.startOfDay(for: day)
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

    func open(room: RoomUsage) {
        openRoomName = room.room
    }

    func closeRoom() {
        openRoomName = nil
    }

    func refresh() async {
        load(force: true)
        await loadTask?.value
    }

    func retry() {
        show(.loading)
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
        isReading = false
    }

    private func show(_ content: Content, readAt: Date? = nil) {
        self.content = content
        syncedAt = readAt
    }

    private func load(force: Bool) {
        let day = selectedDay
        if !force, running?.day == day { return }
        stopLoading()
        if let off = dayOff(day) {
            show(Self.content(for: off))
            return
        }
        guard let reader = reader() else { return }
        let kept = service.keptUsage(on: day)
        siteStatus = service.siteStatus
        if let kept {
            show(Self.content(for: kept.usage), readAt: kept.fetchedAt)
        } else {
            show(.loading)
        }
        let isToday = TaipeiTime.calendar.isDate(day, inSameDayAs: now)
        loads &+= 1
        let id = loads
        running = (day, id)
        isReading = true
        loadTask = Task { [weak self, service] in
            let outcome: Result<ClassroomUsageService.KeptUsage, any Error>
            do {
                outcome = .success(try await service.usage(
                    on: day, isToday: isToday, force: force, credentials: reader.credentials
                ))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            if running?.id == id {
                running = nil
                isReading = false
            }
            siteStatus = service.siteStatus
            guard !Task.isCancelled, selectedDay == day, reader.isCurrent() else { return }
            switch outcome {
            case .success(let read):
                show(Self.content(for: read.usage), readAt: read.fetchedAt)
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                guard content == .loading else { return }
                content = .failed(offline: Self.isOffline(error))
            }
        }
    }

    private static func content(for usage: CampusUsage) -> Content {
        usage.rooms.isEmpty ? .noData : .rooms(usage)
    }

    private static func content(for off: EmptyClassroomSchedule.DayOff) -> Content {
        switch off {
        case .weekend, .outOfTerm: .noData
        case .holiday(let holiday): .holiday(name: holiday.name())
        }
    }

    private static func isOffline(_ error: any Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .internationalRoamingOff,
        ].contains(code)
    }

    func dayLabel(_ day: Date) -> String {
        let calendar = TaipeiTime.calendar
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

    static func dateText(_ day: Date) -> String {
        var symbols = Calendar(identifier: .gregorian)
        symbols.locale = .autoupdatingCurrent
        let narrow = symbols.veryShortWeekdaySymbols
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
            .weekday(Set(narrow).count == narrow.count ? .narrow : .abbreviated)
        style.timeZone = TaipeiTime.timeZone
        style.calendar = Calendar(identifier: .gregorian)
        return day.formatted(style)
    }

    static func timeRange(of period: Int) -> String {
        guard let range = EmptyClassroomSchedule.timeRange(of: period) else { return "" }
        return "\(range.start)–\(range.end)"
    }
}
