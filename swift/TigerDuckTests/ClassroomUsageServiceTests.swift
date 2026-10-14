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
        var signInAttempts = 0
        var now = Date()
        var logged: [any Error] = []
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
                // As the SSO sign-in does, refuses a sign-in for a session a sign-out has ended.
                signIn: { _, _, generation in
                    account.signInAttempts += 1
                    guard generation == account.generation else { throw CancellationError() }
                    account.signIns += 1
                    return true
                },
                timeouts: (600, 600),
                now: { account.now },
                logFailure: { account.logged.append($0) }
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

        /// `generation` is the session the credentials were read in, the current one unless given.
        func usage(on day: Date, isToday: Bool = false, force: Bool = false, generation: Int? = nil) async throws -> CampusUsage {
            try await service.usage(
                on: day, isToday: isToday, force: force,
                credentials: .init(
                    studentId: "B00000000", password: "not-a-password",
                    generation: generation ?? account.generation
                )
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

    /// A page left over would post the date it already shows, which the site may answer from that
    /// page's own state (https://github.com/tigerduck-app/tigerduck-app/issues/513).
    @Test("a pull reads the day again from a new campus page, without signing in")
    func forcedReadStartsFromANewCampusPage() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus again"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")], viewState: "again"))

        let usage = try await harness.usage(on: Self.day(10, 14), force: true)

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        #expect(harness.requests.count == 7)
        #expect(harness.requests[4].httpMethod == "GET")
        #expect(harness.form(6)["__EVENTARGUMENT"] == "9783")
        #expect(harness.form(6)["__VIEWSTATE"] == "campus again")
        #expect(harness.account.signIns == 0)
    }

    /// Nothing on the campus page is known to name its grid's day, which the site may keep from an
    /// earlier read (https://github.com/tigerduck-app/tigerduck-app/issues/475).
    @Test("today is read by posting its date, not off the grid the campus page shows")
    func todayPostsItsDate() async throws {
        let harness = Harness()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(rows: [Pages.row("TR-212", "cc....cc..b...")], viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")]))

        let usage = try await harness.usage(on: Self.day(10, 14), isToday: true)

        #expect(usage.rooms.map(\.room) == ["TR-209"])
        try #require(harness.requests.count == 3)
        #expect(harness.form(2)["__EVENTTARGET"] == "date_cal")
        #expect(harness.form(2)["__EVENTARGUMENT"] == "9783")
    }

    /// Past 12 hours a kept day is too old to show while it reloads, so a failed reload shows the
    /// failure (https://github.com/tigerduck-app/tigerduck-app/issues/477).
    @Test("a kept day is shown while it reloads for up to 12 hours")
    func aKeptDayAgesOut() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        let usage = try await harness.usage(on: Self.day(10, 14))

        harness.account.now = harness.account.now.addingTimeInterval(11 * 60 * 60)
        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == usage)
        harness.account.now = harness.account.now.addingTimeInterval(2 * 60 * 60)
        #expect(harness.service.keptUsage(on: Self.day(10, 14)) == nil)
    }

    /// Leaving the screen or signing out ends a read; the device log keeps real failures only
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/514).
    @Test("a read that a sign-out ends while it starts over leaves nothing in the log")
    func cancelledRetryIsNotLogged() async throws {
        let harness = Harness()
        let gate = SettingsAPIStub.ReplyGate()
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage, gate: gate)

        let read = Task { try await harness.usage(on: Self.day(10, 14)) }
        try await waitUntil { harness.requests.count == 3 }
        harness.account.generation += 1
        gate.open()

        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(harness.account.logged.isEmpty)
        #expect(!ClassroomUsageService.isWorthLogging(URLError(.cancelled)))
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
        #expect(harness.requests.dropFirst(4).map(\.httpMethod) == ["GET", "GET", "GET", "POST", "POST"])
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
        #expect(harness.account.logged.map { $0 as? ClassroomUsageError } == [.unreadable])
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

    @Test("a read that a sign-out ends does not sign in again after a page without the grid")
    func signOutBeforeTheRetry() async throws {
        let harness = Harness()
        harness.serveFirstDay()
        _ = try await harness.usage(on: Self.day(10, 14))
        let gate = SettingsAPIStub.ReplyGate()
        harness.serve(Pages.signInPage, gate: gate)

        let read = Task { try await harness.usage(on: Self.day(10, 15)) }
        try await waitUntil { harness.requests.count == 5 }
        harness.service.forget()
        gate.open()

        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(harness.requests.count == 5)
        #expect(harness.account.signIns == 0)
    }

    @Test("a read queued behind a sign-out never signs the departed account in again")
    func queuedReadAfterSignOut() async throws {
        let harness = Harness()
        let gate = SettingsAPIStub.ReplyGate()
        harness.serve(Pages.signInPage, gate: gate)
        harness.serve(Pages.signInPage)
        let departed = harness.account.generation

        let first = Task { try await harness.usage(on: Self.day(10, 14), generation: departed) }
        try await waitUntil { harness.requests.count == 1 }
        let second = Task { try await harness.usage(on: Self.day(10, 15), generation: departed) }
        for _ in 0..<5 { await Task.yield() }
        harness.service.forget()
        harness.account.generation += 1
        gate.open()

        await #expect(throws: (any Error).self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(harness.account.signInAttempts == 0)
        #expect(harness.requests.count == 1)
    }

    @Test("a date that answers with its second page first is read from the first page on")
    func secondPageFirst() async throws {
        let harness = Harness()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(
            rows: [Pages.row("TR-617", "cc............")], pager: Pages.secondOfTwoPages, viewState: "second"
        ))
        harness.serve(Pages.page(
            rows: [Pages.row("E1-306", "cccc.........."), Pages.row("IB-508", "..............")],
            pager: Pages.firstOfTwoPages
        ))

        let usage = try await harness.usage(on: Self.day(10, 14))

        #expect(usage.rooms.map(\.room) == ["E1-306", "IB-508", "TR-617"])
        #expect(harness.form(3)["__EVENTTARGET"] == "showinfo_grd$_ctl42$_ctl0")
        #expect(harness.form(3)["__VIEWSTATE"] == "second")
        #expect(harness.requests.count == 4)
    }

    /// A pager row on page `page` that links the page after it.
    private static func pager(_ page: Int) -> String {
        "<tr align=\"left\"><td colspan=\"15\"><span>\(page)</span>&nbsp;"
            + "<a href=\"\(Pages.postback("pager$\(page + 1)", ""))\">\(page + 1)</a></td></tr>"
    }

    /// Serves the sign-in again after the first read fails, where the query page never returns.
    private static func serveFailingRetry(_ harness: Harness) {
        harness.serve(Pages.errorPage)
        harness.serve(Pages.errorPage)
    }

    @Test("a pager that runs past 20 pages gives no day rather than part of one")
    func pageCap() async {
        let harness = Harness()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        for page in 1...20 {
            harness.serve(Pages.page(rows: [Pages.row("TR-\(500 + page)", "..............")], pager: Self.pager(page)))
        }
        Self.serveFailingRetry(harness)

        await #expect(throws: ClassroomUsageError.unreadable) { try await harness.usage(on: Self.day(10, 14)) }

        let targets = harness.requests.indices.compactMap { harness.form($0)["__EVENTTARGET"] }
        #expect(targets.filter { $0.hasPrefix("pager$") }.count == 19)
        #expect(!targets.contains("pager$21"))
    }

    @Test("a pager that answers with a page already read gives no day")
    func repeatedPage() async {
        let harness = Harness()
        harness.serve(Pages.page(campus: ""))
        harness.serve(Pages.page(viewState: "campus"))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")], pager: Pages.firstOfTwoPages))
        harness.serve(Pages.page(rows: [Pages.row("TR-209", "..............")], pager: Pages.firstOfTwoPages))
        Self.serveFailingRetry(harness)

        await #expect(throws: ClassroomUsageError.unreadable) { try await harness.usage(on: Self.day(10, 14)) }
        #expect(harness.requests.count == 6)
    }

    @Test("a campus postback that leaves another campus chosen is not read as a day without rooms")
    func mainCampusOnly() async {
        let harness = Harness()
        for _ in 0..<4 { harness.serve(Pages.page(campus: "HHC")) }

        await #expect(throws: ClassroomUsageError.unreadable) { try await harness.usage(on: Self.day(10, 14)) }
        #expect(harness.requests.map(\.httpMethod) == ["GET", "POST", "GET", "POST"])
        #expect(harness.account.signIns == 0)
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
