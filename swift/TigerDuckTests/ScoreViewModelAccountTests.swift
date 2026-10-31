import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct ScoreViewModelAccountTests {
    private final class SignIn: Sendable {
        private let signedIn = OSAllocatedUnfairLock(initialState: true)
        var isCurrent: Bool { signedIn.withLock { $0 } }
        func signOut() { signedIn.withLock { $0 = false } }
    }

    @MainActor
    private final class School {
        var isOnline = true
        var holdsProbe = false
        var holdsFetch = false
        private(set) var fetches = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        var isHolding: Bool { !held.isEmpty }

        func probe() async -> Bool {
            if holdsProbe { await withCheckedContinuation { held.append($0) } }
            return isOnline
        }

        func fetch(_ report: ScoreReport, cachedAt: Date = Date()) async -> (report: ScoreReport, cachedAt: Date) {
            fetches += 1
            if holdsFetch { await withCheckedContinuation { held.append($0) } }
            return (report, cachedAt)
        }

        func release() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    @MainActor
    private final class Indicator: LoadingIndicator {
        var loadingState: LoadingState = .idle {
            didSet { if loadingState == .loading { loadingStarts &+= 1 } }
        }
        private(set) var loadingStarts = 0
    }

    private static func report(for student: String) -> ScoreReport {
        func grade(_ term: String, _ code: String, _ name: String, _ grade: String) -> CourseGrade {
            CourseGrade(
                index: 1, term: term, code: code, name: name, credits: 3, creditType: .normal,
                grade: grade, status: .graded, remark: "", geDimension: nil, distanceLearning: false
            )
        }
        return ScoreReport(
            student: student,
            currentTerm: "1151",
            rankings: [],
            courses: [
                grade("1151", "CS1001301", "程式設計", "A"),
                grade("1142", "MA1001301", "微積分", "B+"),
            ],
            creditSummary: .empty
        )
    }

    private static func testStudentId() -> String {
        "TEST\(UUID().uuidString)"
    }

    private static func withCachedReport(_ body: (String) -> Void) {
        let studentId = testStudentId()
        ScoreReportFiles.shared.saveScoreReport(report(for: studentId), studentId: studentId)
        defer { ScoreReportFiles.shared.invalidateScoreReport(studentId: studentId) }
        body(studentId)
    }

    private static func withCachedReport(_ body: (String) async throws -> Void) async rethrows {
        let studentId = testStudentId()
        ScoreReportFiles.shared.saveScoreReport(report(for: studentId), studentId: studentId)
        defer { ScoreReportFiles.shared.invalidateScoreReport(studentId: studentId) }
        try await body(studentId)
    }

    private static func refresh(
        _ model: ScoreViewModel,
        for studentId: String,
        ticket: AccountSession.Ticket = .after(signOuts: 1),
        signIn: SignIn,
        school: School,
        indicator: Indicator? = nil
    ) async {
        await model.refresh(
            for: studentId,
            ticket: ticket,
            isCurrent: { signIn.isCurrent },
            isReachable: { await school.probe() },
            fetch: { await school.fetch(report(for: studentId)) },
            indicator: indicator ?? Indicator()
        )
    }

    @Test func aReportTheCacheAnsweredKeepsTheTimeItWasRead() async {
        let model = ScoreViewModel()
        let studentId = Self.testStudentId()
        let school = School()
        let readAt = Date().addingTimeInterval(-3 * 3600)

        await model.refresh(
            for: studentId,
            ticket: .after(signOuts: 1),
            isCurrent: { true },
            isReachable: { await school.probe() },
            fetch: { await school.fetch(Self.report(for: studentId), cachedAt: readAt) }
        )

        #expect(model.report.student == studentId)
        #expect(model.cachedAt == readAt)
    }

    @Test func theDayLongCacheAnswersWithTheTimeItWasRead() async throws {
        try await Self.withCachedReport { studentId in
            let cached = try #require(ScoreReportFiles.shared.loadScoreReport(studentId: studentId))
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OfflineURLProtocol.self]

            let fetched = try await NTUSTScoreService.fetchScoreReport(
                session: URLSession(configuration: config), studentId: studentId, password: "unused"
            )

            #expect(fetched.report == cached.report)
            #expect(fetched.cachedAt == cached.cachedAt)
        }
    }

    @Test func anotherAccountsReportComesOffTheScreen() {
        Self.withCachedReport { previous in
            let model = ScoreViewModel()
            model.showCachedReport(for: previous)
            #expect(model.report.student == previous)
            model.toggleCollapse(term: "1151")

            model.showCachedReport(for: Self.testStudentId())

            #expect(model.report == .empty)
            #expect(!model.hasContent)
            #expect(model.groupedCourses.isEmpty)
            #expect(model.gpaTrend.isEmpty)
            #expect(model.cachedAt == nil)
            #expect(model.collapsedTerms.isEmpty)
        }
    }

    @Test func signingOutTakesTheReportOffTheScreen() {
        Self.withCachedReport { previous in
            let model = ScoreViewModel()
            model.showCachedReport(for: previous)
            #expect(model.hasContent)

            model.showCachedReport(for: nil)

            #expect(!model.hasContent)
        }
    }

    @Test func theSameAccountKeepsItsReportAndCollapsedTerms() {
        Self.withCachedReport { student in
            let model = ScoreViewModel()
            model.showCachedReport(for: student)
            model.toggleCollapse(term: "1151")

            model.showCachedReport(for: student)

            #expect(model.report.student == student)
            #expect(model.isCollapsed(term: "1151"))
        }
    }

    @Test func aFetchThatASignOutOvertookStaysOffTheScreen() async throws {
        let model = ScoreViewModel()
        let signIn = SignIn()
        let school = School()
        school.holdsFetch = true
        let refresh = Task { await Self.refresh(model, for: Self.testStudentId(), signIn: signIn, school: school) }
        try await waitUntil { school.isHolding }

        signIn.signOut()
        school.release()
        await refresh.value

        #expect(!model.hasContent)
        #expect(!model.isRefreshing)
    }

    @Test func aSignOutDuringTheReachabilityProbeStopsTheFetch() async throws {
        let model = ScoreViewModel()
        let signIn = SignIn()
        let school = School()
        school.holdsProbe = true
        let refresh = Task { await Self.refresh(model, for: Self.testStudentId(), signIn: signIn, school: school) }
        try await waitUntil { school.isHolding }

        signIn.signOut()
        school.release()
        await refresh.value

        #expect(school.fetches == 0)
        #expect(!model.hasContent)
    }

    @Test func theNextAccountsRefreshDoesNotWaitOnThePreviousOnes() async throws {
        let model = ScoreViewModel()
        let previous = Self.testStudentId()
        let next = Self.testStudentId()
        let departing = SignIn()
        let slowSchool = School()
        slowSchool.holdsFetch = true
        let first = Task {
            await Self.refresh(model, for: previous, ticket: .after(signOuts: 1), signIn: departing, school: slowSchool)
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        model.showCachedReport(for: next)
        await Self.refresh(model, for: next, ticket: .after(signOuts: 2), signIn: SignIn(), school: School())
        #expect(model.report.student == next)

        slowSchool.release()
        await first.value
        #expect(model.report.student == next)
        #expect(!model.isRefreshing)
    }

    @Test func aDiscardedFetchLeavesTheNextAccountsProgressAlone() async throws {
        let model = ScoreViewModel()
        let indicator = Indicator()
        let departing = SignIn()
        let slowSchool = School()
        slowSchool.holdsFetch = true
        let first = Task {
            await Self.refresh(
                model, for: Self.testStudentId(), ticket: .after(signOuts: 1), signIn: departing, school: slowSchool, indicator: indicator
            )
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        let nextSchool = School()
        nextSchool.holdsFetch = true
        let next = Task {
            await Self.refresh(
                model, for: Self.testStudentId(), ticket: .after(signOuts: 2), signIn: SignIn(), school: nextSchool, indicator: indicator
            )
        }
        try await waitUntil { nextSchool.isHolding }
        slowSchool.release()
        await first.value

        #expect(indicator.loadingState == .loading)
        nextSchool.release()
        await next.value
        #expect(indicator.loadingState == .loaded)
    }

    @Test func aDiscardedFetchLeavesTheNextAccountsOfflineErrorAlone() async throws {
        let model = ScoreViewModel()
        let departing = SignIn()
        let slowSchool = School()
        slowSchool.holdsFetch = true
        let indicator = Indicator()
        let first = Task {
            await Self.refresh(
                model, for: Self.testStudentId(), ticket: .after(signOuts: 1), signIn: departing, school: slowSchool, indicator: indicator
            )
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        let offline = School()
        offline.isOnline = false
        await Self.refresh(
            model, for: Self.testStudentId(), ticket: .after(signOuts: 2), signIn: SignIn(), school: offline, indicator: indicator
        )
        let offlineState = indicator.loadingState
        slowSchool.release()
        await first.value

        #expect(offlineState == .error(String(localized: "error_network_unavailable")))
        #expect(indicator.loadingState == offlineState)
    }

    @Test func aSecondRefreshForTheSameSignInSharesTheFirst() async throws {
        let model = ScoreViewModel()
        let student = Self.testStudentId()
        let signIn = SignIn()
        let school = School()
        school.holdsFetch = true
        let first = Task { await Self.refresh(model, for: student, signIn: signIn, school: school) }
        try await waitUntil { school.isHolding }

        await Self.refresh(model, for: student, signIn: signIn, school: school)
        #expect(school.fetches == 1)

        school.release()
        await first.value
        #expect(model.report.student == student)
    }
}

private nonisolated final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
