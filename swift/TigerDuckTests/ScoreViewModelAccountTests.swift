import Foundation
import os
import Testing
@testable import TigerDuck

/// A report on screen belongs to whoever was signed in when it was read. Sign-out deletes the
/// cached report, not the copy the screen holds, so the account change has to take that down,
/// and a refresh still in flight for the previous account must not put it back. Serialized:
/// the refreshes write the process-wide `NTUSTSessionManager.shared.loadingState`.
@MainActor
@Suite(.serialized)
struct ScoreViewModelAccountTests {
    /// A sign-in that a test ends while a refresh waits.
    private final class SignIn: Sendable {
        private let signedIn = OSAllocatedUnfairLock(initialState: true)
        var isCurrent: Bool { signedIn.withLock { $0 } }
        func signOut() { signedIn.withLock { $0 = false } }
    }

    /// Stands in for the reachability probe and the score fetch, and holds either until the
    /// test releases it.
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

        /// `cachedAt` is when the school gave the report: earlier for one the cache answers.
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

    /// A student ID no real account has, so a cached report never collides with one.
    private static func testStudentId() -> String {
        "TEST\(UUID().uuidString)"
    }

    private static func withCachedReport(_ body: (String) -> Void) {
        let studentId = testStudentId()
        DataCache.shared.saveScoreReport(report(for: studentId), studentId: studentId)
        defer { DataCache.shared.invalidateScoreReport(studentId: studentId) }
        body(studentId)
    }

    private static func withCachedReport(_ body: (String) async throws -> Void) async rethrows {
        let studentId = testStudentId()
        DataCache.shared.saveScoreReport(report(for: studentId), studentId: studentId)
        defer { DataCache.shared.invalidateScoreReport(studentId: studentId) }
        try await body(studentId)
    }

    private static func refresh(
        _ model: ScoreViewModel,
        for studentId: String,
        generation: Int = 1,
        signIn: SignIn,
        school: School
    ) async {
        await model.refresh(
            for: studentId,
            generation: generation,
            isCurrent: { signIn.isCurrent },
            isReachable: { await school.probe() },
            fetch: { await school.fetch(report(for: studentId)) }
        )
    }

    /// The status dot's last sync is when the school gave the report, which a refresh the
    /// day-long cache answers does not move.
    @Test func aReportTheCacheAnsweredKeepsTheTimeItWasRead() async {
        let model = ScoreViewModel()
        let studentId = Self.testStudentId()
        let school = School()
        let readAt = Date().addingTimeInterval(-3 * 3600)

        await model.refresh(
            for: studentId,
            generation: 1,
            isCurrent: { true },
            isReachable: { await school.probe() },
            fetch: { await school.fetch(Self.report(for: studentId), cachedAt: readAt) }
        )

        #expect(model.report.student == studentId)
        #expect(model.cachedAt == readAt)
    }

    /// The cache answers with the time it read the report, which the session it is handed never
    /// gets to use.
    @Test func theDayLongCacheAnswersWithTheTimeItWasRead() async throws {
        try await Self.withCachedReport { studentId in
            let cached = try #require(DataCache.shared.loadScoreReport(studentId: studentId))

            let fetched = try await NTUSTScoreService.fetchScoreReport(
                session: URLSession(configuration: .ephemeral), studentId: studentId, password: "unused"
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
            await Self.refresh(model, for: previous, generation: 1, signIn: departing, school: slowSchool)
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        model.showCachedReport(for: next)
        await Self.refresh(model, for: next, generation: 2, signIn: SignIn(), school: School())
        #expect(model.report.student == next)

        slowSchool.release()
        await first.value
        #expect(model.report.student == next)
        #expect(!model.isRefreshing)
    }

    @Test func aDiscardedFetchLeavesTheNextAccountsProgressAlone() async throws {
        let model = ScoreViewModel()
        let departing = SignIn()
        let slowSchool = School()
        slowSchool.holdsFetch = true
        let first = Task {
            await Self.refresh(model, for: Self.testStudentId(), generation: 1, signIn: departing, school: slowSchool)
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        let nextSchool = School()
        nextSchool.holdsFetch = true
        let next = Task {
            await Self.refresh(model, for: Self.testStudentId(), generation: 2, signIn: SignIn(), school: nextSchool)
        }
        try await waitUntil { nextSchool.isHolding }
        slowSchool.release()
        await first.value

        #expect(NTUSTSessionManager.shared.loadingState == .loading)
        nextSchool.release()
        await next.value
        #expect(NTUSTSessionManager.shared.loadingState == .loaded)
    }

    @Test func aDiscardedFetchLeavesTheNextAccountsOfflineErrorAlone() async throws {
        let model = ScoreViewModel()
        let departing = SignIn()
        let slowSchool = School()
        slowSchool.holdsFetch = true
        let first = Task {
            await Self.refresh(model, for: Self.testStudentId(), generation: 1, signIn: departing, school: slowSchool)
        }
        try await waitUntil { slowSchool.isHolding }

        departing.signOut()
        let offline = School()
        offline.isOnline = false
        await Self.refresh(model, for: Self.testStudentId(), generation: 2, signIn: SignIn(), school: offline)
        let offlineState = NTUSTSessionManager.shared.loadingState
        slowSchool.release()
        await first.value

        #expect(offlineState == .error(String(localized: "error_network_unavailable")))
        #expect(NTUSTSessionManager.shared.loadingState == offlineState)
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
