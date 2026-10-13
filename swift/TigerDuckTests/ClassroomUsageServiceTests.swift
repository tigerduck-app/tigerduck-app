import Foundation
import Testing
@testable import TigerDuck

/// The cour01 client against made-up pages: the sign-in, the campus and date postbacks, the
/// pages of a day, the kept days, and what a sign-out leaves behind. Each test serves its own
/// URL, so the stub's queues do not cross.
@MainActor
struct ClassroomUsageServiceTests {
    private typealias Pages = ClassroomPageFixtures

    @MainActor
    private final class Account {
        var generation = 1
        var signIns = 0
    }

    @MainActor
    private struct Harness {
        let url = URL(string: "https://cour01.stub.invalid/\(UUID().uuidString)/classroom_usecondition.aspx")!
        let account = Account()
        let service: ClassroomUsageService

        init() {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let account = account
            service = ClassroomUsageService(
                session: URLSession(configuration: config),
                queryURL: url,
                sessionGeneration: { account.generation },
                signIn: { _, _, _ in
                    account.signIns += 1
                    return true
                }
            )
        }

        func serve(_ html: String, gate: SettingsAPIStub.ReplyGate? = nil) {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(html.utf8), gate: gate), for: url)
        }

        /// The sign-in, the campus postback and both pages of 2026-10-14.
        func serveFirstDay() {
            serve(Pages.page(campus: ""))
            serve(Pages.page(rows: [Pages.row("TR-212", "cc....cc..b...")], viewState: "campus"))
            serve(Pages.page(
                rows: [Pages.row("E1-306", "cccc.........."), Pages.row("IB-508", "..............")],
                pager: Pages.firstOfTwoPages,
                viewState: "first"
            ))
            serve(Pages.page(rows: [Pages.row("TR-617", "cc............")], pager: Pages.secondOfTwoPages, viewState: "second"))
        }

        var requests: [URLRequest] { SettingsAPIStub.requests(for: url) }

        func form(_ index: Int) -> [String: String] {
            let body = SettingsAPIStub.bodyData(from: requests[index]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var fields: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                }
                fields[parts[0]] = parts.count > 1 ? parts[1] : ""
            }
            return fields
        }

        func usage(on day: Date, force: Bool = false) async throws -> CampusUsage {
            try await service.usage(
                on: day, isToday: true, force: force,
                credentials: .init(studentId: "B00000000", password: "not-a-password")
            )
        }
    }

    private static func day(_ month: Int, _ day: Int) -> Date {
        AppConstants.taipeiCalendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9)) ?? .distantPast
    }

    @Test("a day is read from the campus page through every page of the grid, then kept")
    func readsEveryPage() async throws {
        let harness = Harness()
        harness.serveFirstDay()

        let usage = try await harness.usage(on: Self.day(10, 14))

        #expect(usage.rooms.map(\.room) == ["E1-306", "IB-508", "TR-617"])
        #expect(usage.buildingNames["TR"] == "研揚大樓")
        #expect(harness.requests.map(\.httpMethod) == ["GET", "POST", "POST", "POST"])
        #expect(harness.account.signIns == 0)
        let campus = harness.form(1)
        #expect(campus["__EVENTTARGET"] == "DropdownCampusListID")
        #expect(campus["DropdownCampusListID"] == "HQ")
        let date = harness.form(2)
        #expect(date["__EVENTTARGET"] == "date_cal")
        #expect(date["__EVENTARGUMENT"] == "9783")
        #expect(date["__VIEWSTATE"] == "campus")
        let pager = harness.form(3)
        #expect(pager["__EVENTTARGET"] == "showinfo_grd$_ctl54$_ctl1")
        #expect(pager["__VIEWSTATE"] == "first")

        #expect(try await harness.usage(on: Self.day(10, 14)) == usage)
        #expect(harness.requests.count == 4)
        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == usage)
    }

    @Test("a pull reads the day again from the kept page, without signing in")
    func forcedReadUsesTheKeptPage() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")], viewState: "again"))

        let usage = try await harness.usage(on: Self.day(10, 14), force: true)

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        #expect(harness.requests.count == 5)
        #expect(harness.form(4)["__EVENTARGUMENT"] == "9783")
        #expect(harness.form(4)["__VIEWSTATE"] == "second")
    }

    @Test("a date past the calendar's month steps to the next month first")
    func monthStep() async throws {
        let harness = Harness()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(calendar: Pages.november, viewState: "november"))
        harness.serve(Pages.page(rows: [Pages.row("IB-508", "..............")], calendar: Pages.november))

        let usage = try await harness.usage(on: Self.day(11, 12))

        #expect(usage.rooms.map(\.room) == ["IB-508"])
        #expect(harness.form(2)["__EVENTARGUMENT"] == "V9801")
        #expect(harness.form(3)["__EVENTARGUMENT"] == "9812")
        #expect(harness.form(3)["__VIEWSTATE"] == "november")
    }

    @Test("a page without the grid signs in again once and starts over")
    func signsInAgainOnce() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        harness.serve(Pages.signInPage)
        harness.serve(Pages.signInPage)
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]))

        let usage = try await harness.usage(on: Self.day(10, 15))

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        #expect(harness.account.signIns == 1)
        #expect(harness.requests.dropFirst(4).map(\.httpMethod) == ["POST", "GET", "GET", "POST", "POST"])
    }

    @Test("a second page without the grid is an error")
    func unreadableTwice() async {
        let harness = Harness()
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage)

        await #expect(throws: ClassroomUsageError.unreadable) {
            try await harness.usage(on: Self.day(10, 14))
        }
        #expect(harness.account.signIns == 2)
    }

    @Test("a sign-out drops the kept days and the page, so the next read signs in from the start")
    func signOutDropsEverything() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))

        harness.account.generation += 1

        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == nil)
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        #expect(harness.requests.count == 8)
        #expect(harness.requests[4].httpMethod == "GET")
    }

    @Test("forgetting drops the kept days and the page")
    func forget() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))

        harness.service.forget()

        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == nil)
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        #expect(harness.requests[4].httpMethod == "GET")
    }

    @Test("a day still loading when the user signs out is not kept")
    func signOutDuringARead() async throws {
        let harness = Harness()
        let gate = SettingsAPIStub.ReplyGate()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]), gate: gate)

        let read = Task { try await harness.usage(on: Self.day(10, 14)) }
        try await waitUntil { harness.requests.count == 3 }
        harness.service.forget()
        gate.open()

        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == nil)
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        #expect(harness.requests[3].httpMethod == "GET")
    }
}
