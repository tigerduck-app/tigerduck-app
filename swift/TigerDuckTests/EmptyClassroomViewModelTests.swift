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
    }

    @MainActor
    private final class ClassTable {
        var courses: [SDCourse] = []
    }

    @MainActor
    private struct Harness {
        let url = URL(string: "https://cour01.stub.invalid/\(UUID().uuidString)/classroom_usecondition.aspx")!
        let signIn = SignIn()
        let classTable = ClassTable()
        let service: ClassroomUsageService
        let model: EmptyClassroomViewModel

        init(at now: Date, holiday: Holiday? = nil) {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            service = ClassroomUsageService(
                session: URLSession(configuration: config),
                queryURL: url,
                sessionGeneration: { 1 },
                signIn: { _, _, _ in true }
            )
            let classTable = classTable
            model = EmptyClassroomViewModel(
                service: service,
                clock: { now },
                holidays: { day in holiday.map { $0.contains(day) ? [$0] : [] } ?? [] },
                isClassDay: { _ in true },
                courses: { classTable.courses },
                rawRoom: { $0 }
            )
            let signIn = signIn
            model.reader = {
                .init(credentials: Self.credentials, isCurrent: { signIn.isCurrent })
            }
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

    @Test("the day's rooms show once read, and a day the site has no rooms for is no data")
    func rooms() async throws {
        let harness = Harness(at: Self.time(14, 10, 5))
        harness.serveDay([Pages.row("TR-210", "cc..cc..cc...."), Pages.row("IB-508", "..............")])
        harness.model.appear()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.usage?.rooms.map(\.room) == ["TR-210", "IB-508"])
        #expect(harness.model.directory?.buildings.map(\.code) == ["IB", "TR"])

        harness.serve(Pages.page())
        harness.model.select(day: Self.day(15))
        try await waitUntil { harness.model.content == .noData }
        #expect(harness.requestCount == 4)
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
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]))
        let usage = try await harness.service.usage(
            on: Self.day(14), isToday: true, force: false, credentials: Harness.credentials
        )

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        #expect(harness.model.content == .loading)
    }

    @Test("coming back while the day loads keeps that load")
    func comingBackKeepsTheLoad() async throws {
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

        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]), gate: thursday)
        harness.model.select(day: Self.day(15))
        // Thursday's read starts only once Wednesday's has ended, so its handling has run.
        try await waitUntil { harness.requestCount == 4 }
        #expect(harness.model.content == .loading)

        thursday.open()
        wednesday.open()
        try await waitUntil { harness.model.usage != nil }
        #expect(harness.model.usage?.rooms.map(\.room) == ["TR-209"])
        #expect(harness.model.selectedDay == Self.day(15))
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
