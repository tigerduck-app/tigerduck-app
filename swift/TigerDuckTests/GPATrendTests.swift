import Foundation
import Testing
@testable import TigerDuck

private func course(_ term: String, _ code: String, credits: Int?, grade: String, status: GradeStatus = .graded) -> CourseGrade {
    CourseGrade(
        index: nil, term: term, code: code, name: code, credits: credits, creditType: .normal,
        grade: grade, status: status, remark: "", geDimension: nil, distanceLearning: false
    )
}

struct NTUSTGradePointsTests {
    @Test func lettersFollowTheOfficialTable() {
        #expect(NTUSTGradePoints.points(forGrade: "A+") == 4.3)
        #expect(NTUSTGradePoints.points(forGrade: " b- ") == 2.7)
        #expect(NTUSTGradePoints.points(forGrade: "Ｃ＋") == 2.3)
        #expect(NTUSTGradePoints.points(forGrade: "X") == 0)
    }

    @Test func numbersFallBackToThePercentBands() {
        #expect(NTUSTGradePoints.points(forGrade: "90") == 4.3)
        #expect(NTUSTGradePoints.points(forGrade: "84") == 3.7)
        #expect(NTUSTGradePoints.points(forGrade: "59") == 1.0)
        #expect(NTUSTGradePoints.points(forGrade: "12") == 0)
    }

    @Test func nonGradesCarryNoPoints() {
        #expect(NTUSTGradePoints.points(forGrade: "通過") == nil)
        #expect(NTUSTGradePoints.points(forGrade: "成績未到") == nil)
        #expect(NTUSTGradePoints.points(forGrade: "") == nil)
    }

    @Test func gpaIsCreditWeightedOverGradedCoursesOnly() {
        let courses = [
            course("1142", "A", credits: 3, grade: "A+"),          // 4.3 × 3
            course("1142", "B", credits: 1, grade: "C"),           // 2.0 × 1
            course("1142", "C", credits: 2, grade: "成績未到", status: .pending),
            course("1142", "D", credits: 1, grade: "通過", status: .passed),
            course("1142", "E", credits: 0, grade: "A"),
            course("1142", "F", credits: nil, grade: "A"),
        ]
        let gpa = NTUSTGradePoints.gpa(of: courses)
        #expect(gpa != nil && abs(gpa! - (4.3 * 3 + 2.0) / 4) < 1e-9)
        #expect(NTUSTGradePoints.gpa(of: [course("1142", "C", credits: 2, grade: "成績未到", status: .pending)]) == nil)
    }
}

struct GPATrendPointTests {
    @Test func publishedRankingWinsAndUnrankedTermGetsProvisionalPoint() {
        let report = ScoreReport(
            student: "B11315000", currentTerm: "1142",
            rankings: [SemesterRanking(
                term: "1141",
                semester: RankingStats(classRank: 3, deptRank: 10, gpa: 3.9),
                cumulative: RankingStats(classRank: 4, deptRank: 12, gpa: 3.85)
            )],
            courses: [
                course("1141", "A", credits: 3, grade: "A"),        // official row exists; grade math ignored
                course("1142", "B", credits: 2, grade: "A+"),       // 4.3 × 2
                course("1142", "C", credits: 2, grade: "B"),        // 3.0 × 2
                course("1142", "D", credits: 3, grade: "成績未到", status: .pending),
                course("1151", "E", credits: 3, grade: "成績未到", status: .pending),  // nothing graded → no point
            ],
            creditSummary: .empty
        )
        let trend = GPATrendPoint.trend(for: report)
        #expect(trend.map(\.term) == ["1141", "1142"])
        #expect(trend[0].isProvisional == false)
        #expect(trend[0].semester.gpa == 3.9)
        #expect(trend[1].isProvisional)
        #expect(trend[1].semester.classRank == nil)
        #expect(abs(trend[1].semester.gpa! - 3.65) < 1e-9)
        // Cumulative estimate spans every graded course so far: (4.0×3 + 4.3×2 + 3.0×2) / 7
        #expect(abs(trend[1].cumulative.gpa! - (4.0 * 3 + 4.3 * 2 + 3.0 * 2) / 7) < 1e-9)
    }
}
