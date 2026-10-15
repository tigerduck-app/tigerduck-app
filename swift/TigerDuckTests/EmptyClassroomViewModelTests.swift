import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// The finder's screen state against made-up pages: where it opens, the days it never asks the
/// site about, and what a read leaves on screen.
@MainActor
struct EmptyClassroomViewModelTests {
    private typealias Pages = ClassroomPageFixtures

    @MainActor
    private final class SignIn {
        var isCurrent = true
        /// Each read of the site first asks whom it reads for.
        var reads = 0
    }

    @MainActor
    private final class ClassTable {
        var courses: [SDCourse] = []
    }

    @MainActor
    private final class Now {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    @MainActor
    private final class Term {
        var isInSession = true
    }

    @MainActor
    private struct Harness {
        let url = URL(string: "https://cour01.stub.invalid/\(UUID().uuidString)/classroom_usecondition.aspx")!
        let signIn = SignIn()
        let classTable = ClassTable()
        let now: Now
        let service: ClassroomUsageService
        let model: EmptyClassroomViewModel
        /// Another screen on the same service, as each visit from More or Home builds one.
        let newScreen: @MainActor () -> EmptyClassroomViewModel

        init(at time: Date, holiday: Holiday? = nil, isInSession: @escaping @MainActor (Date) -> Bool = { _ in true }) {
            let now = Now(time)
            self.now = now
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            service = ClassroomUsageService(
                session: URLSession(configuration: config),
                queryURL: url,
                sessionGeneration: { 1 },
                signIn: { _, _, _ in true },
                timeouts: (600, 600)
            )
            let classTable = classTable
            let signIn = signIn
            let service = service
            newScreen = {
                let model = EmptyClassroomViewModel(
                    service: service,
                    clock: { now.date },
                    holidays: { day in holiday.map { $0.contains(day) ? [$0] : [] } ?? [] },
                    isInSession: isInSession,
                    isClassDay: { _ in true },
                    courses: { classTable.courses },
                    rawRoom: { $0 }
                )
                model.reader = {
                    signIn.reads += 1
                    return .init(credentials: Self.credentials, isCurrent: { signIn.isCurrent })
                }
                return model
            }
            model = newScreen()
        }

        static let credentials = ClassroomUsageService.Credentials(
            studentId: "B00000000", password: "not-a-password", generation: 1
        )

        func serve(_ html: String, gate: SettingsAPIStub.ReplyGate? = nil) {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(html.utf8), gate: gate), for: url)
        }

        /// The sign-in, the campus postback and the day's one page.
        func serveDay(_ rows: [String]) {
            serve(Pages.page(campus: ""))
            serve(Pages.page(viewState: "campus"))
            serve(Pages.page(rows: rows))
        }

        var requestCount: Int { SettingsAPIStub.requests(for: url).count }
    }

    private static func time(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        AppConstants.taipeiCalendar.date(
            from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)
        ) ?? .distantPast
    }

    private static func day(_ day: Int) -> Date { time(day, 0) }

    @Test("it opens on the period in progress, and after the last one on the next teaching day")
    func opening() {
        let wednesday = Harness(at: Self.time(14, 10, 5))
        wednesday.model.appear()
        #expect(wednesday.model.selectedDay == Self.day(14))
        #expect(wednesday.model.selectedPeriod == 2)

        let friday = Harness(at: Self.time(16, 23))
        friday.model.appear()
        #expect(friday.model.selectedDay == Self.day(19))
        #expect(friday.model.selectedPeriod == 0)
    }

    @Test("a weekend shows no data without asking the site")
    func weekend() {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.model.select(day: Self.day(17))

        #expect(harness.model.content == .noData)
        #expect(harness.requestCount == 0)
        #expect(harness.model.nextTeachingDay == Self.day(19))
    }

    @Test("a holiday shows its name and no rooms, without asking the site")
    func holiday() {
        let holiday = Holiday(id: 1, nameZh: "國慶日", nameEn: "National Day", start: Self.day(15), end: Self.day(15))
        let harness = Harness(at: Self.time(14, 22, 30), holiday: holiday)
        harness.model.appear()
        #expect(harness.model.selectedDay == Self.day(16))

        harness.model.select(day: Self.day(15))

        #expect(harness.model.content == .holiday(name: holiday.name()))
        #expect(harness.requestCount == 0)
    }

    @Test("a weekday outside the term shows no data without asking the site, and is passed over")
    func outsideTheTerm() {
        // The term ends on Thursday 10/15 and the next one starts on Monday 10/26.
        let harness = Harness(at: Self.time(15, 22, 30), isInSession: { $0 < Self.day(16) || $0 >= Self.day(26) })
        harness.model.appear()
        #expect(harness.model.selectedDay == Self.day(26))

        harness.model.select(day: Self.day(19))

        #expect(harness.model.content == .noData)
        #expect(harness.model.nextTeachingDay == Self.day(26))
        #expect(harness.requestCount == 0)
    }

    @Test("a term's dates that arrive after the day was read take its rooms off the screen")
    func lateCalendar() async throws {
        let term = Term()
        let harness = Harness(at: Self.time(14, 10, 5), isInSession: { _ in term.isInSession })
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }

        harness.model.dataDidUpdate()
        #expect(harness.model.usage?.rooms.map(\.room) == ["IB-508"])

        term.isInSession = false
        harness.model.dataDidUpdate()
        #expect(harness.model.content == .noData)
    }

    @Test("the day's rooms show once read, and a day the site has no rooms for is no data")
    func rooms() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("TR-210", "cc..cc..cc...."), Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.usage?.rooms.map(\.room) == ["TR-210", "IB-508"])
        #expect(harness.model.directory?.buildings.map(\.code) == ["IB", "TR"])

        harness.serveDay([])
        harness.model.select(day: Self.day(15))
        try await waitUntil { harness.model.content == .noData }
        #expect(harness.requestCount == 6)
    }

    @Test("a failed read shows the error, and a later pull that fails keeps the rooms on screen")
    func failures() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        harness.model.appear()
        try await waitUntil { harness.model.content == .failed(offline: false) }

        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.retry()
        try await waitUntil { harness.model.usage != nil }

        harness.serve(Pages.errorPage)
        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        await harness.model.refresh()
        #expect(harness.model.usage?.rooms.map(\.room) == ["IB-508"])
    }

    @Test("the dot says how the site last answered, and a failed pull turns it with the rooms on screen")
    func siteStatus() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        #expect(harness.model.siteStatus == .unknown)
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.siteStatus == .ok)

        harness.serve(Pages.errorPage)
        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        await harness.model.refresh()
        #expect(harness.model.usage?.rooms.map(\.room) == ["IB-508"])
        #expect(harness.model.siteStatus == .failed)

        // The answer was the account before's: a sign-out drops it, then the screen hears.
        harness.service.forget()
        harness.model.accountChanged()
        #expect(harness.model.siteStatus == .unknown)
        #expect(harness.newScreen().siteStatus == .unknown)
    }

    @Test("an account change on a day the site is not asked about greys the dot as well")
    func accountChangeOnAWeekend() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        harness.model.select(day: Self.day(17))
        #expect(harness.model.siteStatus == .ok)

        harness.service.forget()
        harness.model.accountChanged()

        #expect(harness.model.siteStatus == .unknown)
    }

    @Test("a new screen shows how the site last answered, though it reads a kept day without asking")
    func aNewScreenKeepsTheStatus() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        harness.model.disappear()
        let requests = harness.requestCount

        let again = harness.newScreen()
        again.appear()
        // At once, before the screen's own read has ended.
        #expect(again.siteStatus == .ok)
        try await waitUntil { !again.isReading }
        #expect(again.usage?.rooms.map(\.room) == ["IB-508"])
        #expect(harness.requestCount == requests)
        #expect(again.siteStatus == .ok)
    }

    @Test("a new screen after a failed read shows the failure")
    func aNewScreenKeepsTheFailure() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        await harness.model.refresh()
        #expect(harness.model.siteStatus == .failed)
        harness.model.disappear()

        let again = harness.newScreen()
        again.appear()
        try await waitUntil { !again.isReading }
        #expect(again.usage?.rooms.map(\.room) == ["IB-508"])
        #expect(again.siteStatus == .failed)
    }

    @Test("rooms kept from an earlier read leave the dot as the site last answered")
    func keptRoomsLeaveTheStatus() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.siteStatus == .ok)

        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        harness.model.select(day: Self.day(15))
        try await waitUntil { harness.model.content == .failed(offline: false) }
        #expect(harness.model.siteStatus == .failed)

        // Wednesday is kept and still fresh, so the site is not asked again.
        let requests = harness.requestCount
        harness.model.select(day: Self.day(14))
        try await waitUntil { !harness.model.isReading }
        #expect(harness.model.usage?.rooms.map(\.room) == ["IB-508"])
        #expect(harness.requestCount == requests)
        #expect(harness.model.siteStatus == .failed)
    }

    @Test("the last sync is when the day on screen was read, which a failed pull leaves as it was")
    func lastSync() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        #expect(harness.model.syncedAt == nil)
        let before = Date()
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        let read = try #require(harness.model.syncedAt)
        #expect(read >= before && read <= Date())

        harness.serve(Pages.errorPage)
        for _ in 0..<4 { harness.serve(Pages.errorPage) }
        await harness.model.refresh()
        #expect(harness.model.syncedAt == read)

        // A day the site answers with no rooms was still read.
        harness.serveDay([])
        harness.model.select(day: Self.day(15))
        try await waitUntil { harness.model.content == .noData }
        #expect(try #require(harness.model.syncedAt) >= read)

        // A weekend is never asked about, and a day kept from earlier brings its own time back.
        harness.model.select(day: Self.day(17))
        #expect(harness.model.syncedAt == nil)
        harness.model.select(day: Self.day(14))
        #expect(harness.model.syncedAt == read)
    }

    @Test("the dot spins while the day shown is read, and stops once it is read or the screen leaves")
    func reading() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        let gate = SettingsAPIStub.ReplyGate()
        Self.serveHeldWednesday(harness, gate: gate)
        harness.model.appear()
        #expect(harness.model.isReading)
        try await waitUntil { harness.requestCount == 3 }
        gate.open()
        try await waitUntil { harness.model.usage != nil }
        #expect(!harness.model.isReading)

        harness.model.select(day: Self.day(17))
        #expect(!harness.model.isReading)

        let held = SettingsAPIStub.ReplyGate()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]), gate: held)
        harness.model.select(day: Self.day(15))
        #expect(harness.model.isReading)
        harness.model.disappear()
        #expect(!harness.model.isReading)
        held.open()
    }

    @Test("an answer that arrives after the account changed is not shown")
    func anotherAccount() async {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.signIn.isCurrent = false
        harness.serveDay([Pages.row("IB-508", "..............")])

        await harness.model.refresh()

        #expect(harness.model.content == .loading)
    }

    @Test("the user's classes follow the class table while the screen is open")
    func classesFollowTheClassTable() {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.model.appear()
        #expect(harness.model.classes.isEmpty)

        harness.classTable.courses = [SDCourse(
            courseNo: "CS1001301", courseName: "計算機網路", schedule: [3: ["1", "2"]],
            classroomMap: ["3-1": "TR-214", "3-2": "TR-214"]
        )]
        harness.model.reloadCourses()

        #expect(harness.model.classes.map(\.room) == ["TR-214"])
        #expect(harness.model.classes.map(\.lastPeriod) == [1])
    }

    @Test("a picked building is kept for the next visit, and an account change forgets it")
    func pickedBuilding() {
        let saved = Defaults[.emptyClassroomBuilding]
        defer { Defaults[.emptyClassroomBuilding] = saved }
        Defaults[.emptyClassroomBuilding] = nil
        let harness = Harness(at: Self.time(14, 10, 5))

        harness.model.pick(building: "IB")
        #expect(harness.model.pickedBuilding == "IB")
        #expect(Harness(at: Self.time(14, 10, 5)).model.pickedBuilding == "IB")

        // A sign-out clears the stored pick, as AppState.logoutNTUST() does, then the screen hears.
        Defaults[.emptyClassroomBuilding] = nil
        harness.model.accountChanged()
        #expect(harness.model.pickedBuilding == nil)
    }

    @Test("an account change off screen reads nothing until the screen shows again")
    func accountChangeOffScreen() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        harness.model.disappear()

        // A sign-out drops the kept days, then a sign-in from Settings reaches a hidden tab.
        harness.service.forget()
        harness.model.accountChanged()
        #expect(harness.model.content == .loading)
        #expect(harness.signIn.reads == 1)

        harness.serveDay([Pages.row("TR-209", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage?.rooms.map(\.room) == ["TR-209"] }
        #expect(harness.signIn.reads == 2)
        #expect(harness.requestCount == 6)
    }

    @Test("an open room's sheet follows each read of the day and closes once a read lacks the room")
    func openRoomFollowsTheReads() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("TR-214", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        harness.model.open(room: try #require(harness.model.usage?.rooms.first))
        #expect(harness.model.openRoom?.isFree(at: 2) == true)

        harness.serveDay([Pages.row("TR-214", "..b...........")])
        await harness.model.refresh()
        #expect(harness.model.openRoom?.isFree(at: 2) == false)

        harness.serveDay([Pages.row("IB-508", "..............")])
        await harness.model.refresh()
        #expect(harness.model.openRoom == nil)

        // The room back in a later read does not open the sheet again.
        harness.serveDay([Pages.row("TR-214", "..............")])
        await harness.model.refresh()
        #expect(harness.model.openRoom == nil)
    }

    @Test("an open room's sheet closes on another day, even one with the room, and on an account change")
    func openRoomCloses() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("TR-214", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        harness.serveDay([Pages.row("TR-214", "..............")])
        harness.model.select(day: Self.day(15))
        try await waitUntil { harness.model.usage != nil }
        harness.model.select(day: Self.day(14))
        let room = try #require(harness.model.usage?.rooms.first)

        harness.model.open(room: room)
        harness.model.select(day: Self.day(15))
        #expect(harness.model.usage?.rooms.map(\.room) == ["TR-214"])
        #expect(harness.model.openRoom == nil)

        harness.model.open(room: room)
        harness.model.accountChanged()
        #expect(harness.model.openRoom == nil)
    }

    @Test("a period chosen today moves to the current one at a later visit once it has ended")
    func endedPeriod() {
        let harness = Harness(at: Self.time(14, 8, 30))
        harness.model.appear()
        #expect(harness.model.selectedPeriod == 0)

        // A pinned tab tapped again in the afternoon.
        harness.model.disappear()
        harness.now.date = Self.time(14, 13, 40)
        harness.model.appear()
        #expect(harness.model.selectedDay == Self.day(14))
        #expect(harness.model.selectedPeriod == 5)

        // A period still to come stays, and so does one on a later day.
        harness.model.select(period: 9)
        harness.model.appear()
        #expect(harness.model.selectedPeriod == 9)
        harness.model.select(day: Self.day(15))
        harness.model.select(period: 0)
        harness.model.appear()
        #expect(harness.model.selectedDay == Self.day(15))
        #expect(harness.model.selectedPeriod == 0)

        // After the last period it moves to the next teaching day.
        harness.model.select(day: Self.day(14))
        harness.now.date = Self.time(14, 22, 30)
        harness.model.appear()
        #expect(harness.model.selectedDay == Self.day(15))
        #expect(harness.model.selectedPeriod == 0)
    }

    /// Wednesday's sign-in and campus pages, and its one page of rooms held until `gate` opens.
    private static func serveHeldWednesday(_ harness: Harness, gate: SettingsAPIStub.ReplyGate) {
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("IB-508", "..............")]), gate: gate)
    }

    @Test("leaving the screen stops its read, so nothing it started lands later")
    func leavingStopsTheRead() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        let gate = SettingsAPIStub.ReplyGate()
        Self.serveHeldWednesday(harness, gate: gate)
        harness.model.appear()
        try await waitUntil { harness.requestCount == 3 }

        harness.model.disappear()
        gate.open()
        harness.serveDay([Pages.row("TR-209", "..............")])
        let usage = try await harness.service.usage(
            on: Self.day(14), isToday: true, force: false, credentials: Harness.credentials
        ).usage

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        #expect(harness.model.content == .loading)
    }

    @Test("a second appear while the day loads keeps that load")
    func repeatedAppearKeepsTheLoad() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        let gate = SettingsAPIStub.ReplyGate()
        Self.serveHeldWednesday(harness, gate: gate)
        harness.model.appear()
        try await waitUntil { harness.requestCount == 3 }

        harness.model.appear()
        gate.open()

        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.usage?.rooms.map(\.room) == ["IB-508"])
        #expect(harness.requestCount == 3)
    }

    @Test("a day chosen while another loads shows its own rooms, and the first day's end changes nothing")
    func switchingDaysMidRead() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        let wednesday = SettingsAPIStub.ReplyGate()
        let thursday = SettingsAPIStub.ReplyGate()
        Self.serveHeldWednesday(harness, gate: wednesday)
        harness.model.appear()
        try await waitUntil { harness.requestCount == 3 }

        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]), gate: thursday)
        harness.model.select(day: Self.day(15))
        // Thursday's read starts only once Wednesday's has ended, so its handling has run.
        try await waitUntil { harness.requestCount == 6 }
        #expect(harness.model.content == .loading)

        thursday.open()
        wednesday.open()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.usage?.rooms.map(\.room) == ["TR-209"])
        #expect(harness.model.selectedDay == Self.day(15))
    }

    @Test("a return to the app reads the screen on view again, on today once the day shown has passed")
    func returnToTheApp() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }

        // Off screen, a return to the app reads nothing.
        harness.model.disappear()
        harness.now.date = Self.time(15, 8, 30)
        harness.model.returnToApp()
        #expect(harness.model.selectedDay == Self.day(14))
        #expect(harness.requestCount == 3)

        harness.serveDay([Pages.row("TR-209", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage?.rooms.map(\.room) == ["TR-209"] }

        harness.serveDay([Pages.row("TR-301", "..............")])
        harness.now.date = Self.time(16, 8, 30)
        harness.model.returnToApp()
        try await waitUntil { harness.model.usage?.rooms.map(\.room) == ["TR-301"] }
        #expect(harness.model.selectedDay == Self.day(16))
    }

    /// A building has only a Chinese and an English name, which the app gives by code; the site's
    /// list, Chinese in every language, names the rest.
    @Test("a building goes by the app's name for its code, and by the site's for a code it has none for")
    func buildingNames() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(
            rows: [Pages.row("TR-214", ".............."), Pages.row("IA-501", "..............")],
            buildings: [("TR", "研揚大樓（舊名）"), ("IA", "醫揚大樓（舊名）"), ("QQ", "測試大樓")]
        ))
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }

        #expect(harness.model.buildingName("TR") == String(localized: "empty_classroom_building_tr"))
        #expect(harness.model.buildingName("IA") == String(localized: "empty_classroom_building_ia"))
        #expect(harness.model.buildingName("QQ") == "測試大樓")
        #expect(harness.model.buildingName("ZZ") == "ZZ")
    }

    @Test("today and tomorrow are named before the date")
    func dayLabels() {
        let harness = Harness(at: Self.time(14, 10, 5))
        let model = harness.model
        #expect(model.dayLabel(Self.day(14)) == "\(String(localized: "calendar_today")) \(EmptyClassroomViewModel.dateText(Self.day(14)))")
        #expect(model.dayLabel(Self.day(15)) == "\(String(localized: "widget_tomorrow")) \(EmptyClassroomViewModel.dateText(Self.day(15)))")
        #expect(model.dayLabel(Self.day(16)) == EmptyClassroomViewModel.dateText(Self.day(16)))
        #expect(model.days.count == 14)
        #expect(EmptyClassroomViewModel.timeRange(of: 2) == "10:20–11:10")
    }
}
