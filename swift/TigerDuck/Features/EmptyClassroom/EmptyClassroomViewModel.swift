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

    private enum Presence {
        case unopened
        case shown
        case away
    }

    private(set) var selectedDay: Date {
        didSet { if selectedDay != oldValue { openRoomName = nil } }
    }
    private(set) var selectedPeriod = 0
    private(set) var content = Content.loading {
        didSet { if openRoomName != nil, openRoom == nil { openRoomName = nil } }
    }
    private(set) var syncedAt: Date?
    private(set) var classes: [ClassStop] = []
    private(set) var pickedBuilding: String?
    private(set) var openRoomName: String?

    @ObservationIgnored let calendar: EmptyClassroomCalendar
    @ObservationIgnored let loader: EmptyClassroomLoader
    @ObservationIgnored private var presence = Presence.unopened

    init(calendar: EmptyClassroomCalendar? = nil, loader: EmptyClassroomLoader? = nil) {
        let calendar = calendar ?? EmptyClassroomCalendar()
        self.calendar = calendar
        self.loader = loader ?? EmptyClassroomLoader()
        selectedDay = TaipeiTime.calendar.startOfDay(for: calendar.instant)
        pickedBuilding = Defaults[.emptyClassroomBuilding]
    }

    func connect(_ authService: AuthService) {
        loader.reader = { [weak authService] in
            guard let authService,
                  let studentId = authService.storedStudentId,
                  let password = authService.storedPassword else { return nil }
            let signIn = authService.session.currentSignIn
            return EmptyClassroomLoader.Reader(
                credentials: .init(studentId: studentId, password: password, signIn: signIn)
            )
        }
    }

    var siteStatus: ServerStatus { loader.siteStatus }
    var isReading: Bool { loader.isReading }
    var now: Date { calendar.now }
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
        return EmptyClassroomSchedule.nextTeachingDay(
            after: selectedDay, horizon: remaining, isTeachingDay: calendar.isTeachingDay
        )
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
        let hasOpened = presence != .unopened
        presence = .shown
        if !hasOpened || selectedDay < today || selectedPeriod < endedPeriods {
            let opening = EmptyClassroomSchedule.opening(
                at: now, horizon: Self.dayCount - 1, isTeachingDay: calendar.isTeachingDay
            )
            selectedDay = opening.day
            selectedPeriod = opening.period
        }
        reloadCourses()
        load(force: false)
    }

    /// iOS sends no `onAppear` when the app comes back to the foreground, while today's rooms
    /// have aged and the day shown may have passed, so the screen on view reads again.
    func returnToApp() {
        guard presence == .shown else { return }
        appear()
    }

    func disappear() {
        if presence == .shown { presence = .away }
    }

    func accountChanged() {
        loader.stop()
        show(.loading)
        loader.noteSiteStatus()
        pickedBuilding = Defaults[.emptyClassroomBuilding]
        reloadCourses()
        guard presence == .shown else { return }
        load(force: false)
    }

    func reloadCourses() {
        calendar.reloadCourses()
        refreshClasses()
    }

    func storesDidChange() {
        reloadCourses()
        guard let off = calendar.dayOff(selectedDay) else { return }
        loader.stop()
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
        SchoolAccountKeys.pickEmptyClassroomBuilding(building, for: AccountSession.school.currentSignIn)
    }

    func open(room: RoomUsage) {
        openRoomName = room.room
    }

    func closeRoom() {
        openRoomName = nil
    }

    func refresh() async {
        load(force: true)
        await loader.wait()
    }

    func retry() {
        show(.loading)
        load(force: true)
    }

    private func refreshClasses() {
        classes = ClassStop.stops(from: calendar.classSlots(on: selectedDay), rawRoom: calendar.rawRoom)
    }

    private func show(_ content: Content, readAt: Date? = nil) {
        self.content = content
        syncedAt = readAt
    }

    private func load(force: Bool) {
        let day = selectedDay
        if !force, loader.isReading(day) { return }
        loader.stop()
        if let off = calendar.dayOff(day) {
            show(Self.content(for: off))
            return
        }
        guard let reader = loader.reader() else { return }
        let kept = loader.kept(on: day)
        loader.noteSiteStatus()
        if let kept {
            show(Self.content(for: kept.usage), readAt: kept.readAt)
        } else {
            show(.loading)
        }
        let isToday = TaipeiTime.calendar.isDate(day, inSameDayAs: now)
        loader.read(day, isToday: isToday, force: force, by: reader, isWanted: { [weak self] in
            self?.selectedDay == day
        }, finish: { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let read):
                show(Self.content(for: read.usage), readAt: read.readAt)
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                guard content == .loading else { return }
                content = .failed(offline: Self.isOffline(error))
            }
        })
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
        EmptyClassroomDayText.label(day, today: today)
    }
}
