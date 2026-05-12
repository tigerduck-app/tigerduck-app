import Foundation

// MARK: - Score Report (root)

/// Structured representation of the NTUST StuScoreQueryServ "DisplayAll"
/// page. Mirrors the Python reference parser (`html_score_parser.py`) 1:1 so
/// server-side and on-device output stay swappable.
struct ScoreReport: Codable, Equatable, Sendable {
    var student: String
    var currentTerm: String
    var rankings: [SemesterRanking]
    var courses: [CourseGrade]
    var creditSummary: CreditSummary

    static let empty = ScoreReport(
        student: "",
        currentTerm: "",
        rankings: [],
        courses: [],
        creditSummary: .empty
    )
}

// MARK: - Rankings

struct SemesterRanking: Codable, Equatable, Sendable, Identifiable {
    var term: String
    var semester: RankingStats
    var cumulative: RankingStats

    var id: String { term }
}

struct RankingStats: Codable, Equatable, Sendable {
    var classRank: Int?
    var deptRank: Int?
    var gpa: Double?
}

// MARK: - Courses

struct CourseGrade: Codable, Equatable, Sendable, Identifiable {
    var index: Int?
    var term: String
    var code: String
    var name: String
    var credits: Int?
    var creditType: CreditType
    var grade: String
    var status: GradeStatus
    var remark: String
    var geDimension: String?
    var distanceLearning: Bool

    /// Composite key — NTUST can legitimately reissue the same code across
    /// terms when a student retakes, so `code` alone is not unique.
    var id: String { "\(term)-\(code)-\(index ?? -1)" }

    /// The school backend returns pass/fail text in its own language
    /// ("通過"/"不通過"), so this must be derived from raw payload values
    /// rather than UI localization.
    var isPassStatusPassed: Bool {
        let normalized = grade.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return true }

        let failedMarkers: Set<String> = ["不通過", "未通過", "FAIL", "FAILED"]
        if failedMarkers.contains(normalized.uppercased()) || failedMarkers.contains(normalized) {
            return false
        }
        return true
    }
}

enum CreditType: String, Codable, Equatable, Sendable, CaseIterable {
    case normal
    case educationProgram = "education_program"
    case notCounted = "not_counted"
    case notRequired = "not_required"
    case notEarned = "not_earned"
    case unknown
}

enum GradeStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case graded
    case pending
    case passed
    case withdrew
    case exempted
    case unknown
}

// MARK: - Credit Summary

struct CreditSummary: Codable, Equatable, Sendable {
    var earned: CreditBreakdown
    var enrolled: CreditBreakdown
    var total: CreditBreakdown

    static let empty = CreditSummary(
        earned: .zero, enrolled: .zero, total: .zero
    )
}

struct CreditBreakdown: Codable, Equatable, Sendable {
    var inPerson: Int
    var distance: Int
    var total: Int

    static let zero = CreditBreakdown(inPerson: 0, distance: 0, total: 0)
}
