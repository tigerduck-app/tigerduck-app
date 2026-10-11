import Foundation
import Testing
@testable import TigerDuck

/// A report on screen belongs to whoever was signed in when it was read. Sign-out deletes the
/// cached report, not the copy the screen holds, so the account change has to take that down.
@MainActor
struct ScoreViewModelAccountTests {
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

    /// A student ID no real account has, so the cached report never collides with one.
    private static func testStudentId() -> String {
        "TEST\(UUID().uuidString)"
    }

    private static func withCachedReport(_ body: (String) -> Void) {
        let studentId = testStudentId()
        DataCache.shared.saveScoreReport(report(for: studentId), studentId: studentId)
        defer { DataCache.shared.invalidateScoreReport(studentId: studentId) }
        body(studentId)
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

    @Test func aReportFetchedForThePreviousAccountStaysOffTheNextOnesScreen() {
        let model = ScoreViewModel()
        let previous = Self.testStudentId()
        let next = Self.testStudentId()
        model.showCachedReport(for: next)

        model.showFetchedReport(Self.report(for: previous), for: previous)
        #expect(!model.hasContent)

        model.showFetchedReport(Self.report(for: next), for: next)
        #expect(model.report.student == next)
    }
}
