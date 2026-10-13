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
                .init(credentials: .init(studentId: "B00000000", password: "not-a-password"), isCurrent: { signIn.isCurrent })
            }
        }

        func serve(_ html: String) {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(html.utf8)), for: url)
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
