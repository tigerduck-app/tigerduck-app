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

/// One term on the GPA trend: the school's published ranking, or — while
/// the ranking is not out yet — a GPA computed from the grades that have
/// arrived so far. Grades land course by course, so a provisional point
/// moves until the ranking replaces it.
struct GPATrendPoint: Equatable, Sendable, Identifiable {
    var term: String
    var semester: RankingStats
    var cumulative: RankingStats
    var isProvisional: Bool

    var id: String { term }

    init(ranking: SemesterRanking) {
        term = ranking.term
        semester = ranking.semester
        cumulative = ranking.cumulative
        isProvisional = false
    }

    init(term: String, semesterGPA: Double, cumulativeGPA: Double?) {
        self.term = term
        semester = RankingStats(classRank: nil, deptRank: nil, gpa: semesterGPA)
        cumulative = RankingStats(classRank: nil, deptRank: nil, gpa: cumulativeGPA)
        isProvisional = true
    }

    /// Chronological trend for `report`: every published ranking, plus a
    /// provisional point for each term that has graded courses but no
    /// ranking (or a ranking without a GPA) yet.
    static func trend(for report: ScoreReport) -> [GPATrendPoint] {
        let coursesByTerm = Dictionary(grouping: report.courses, by: \.term)
        let rankings = Dictionary(report.rankings.map { ($0.term, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(coursesByTerm.keys).union(rankings.keys).sorted().compactMap { term in
            if let ranking = rankings[term], ranking.semester.gpa != nil {
                return GPATrendPoint(ranking: ranking)
            }
            guard let semesterGPA = NTUSTGradePoints.gpa(of: coursesByTerm[term] ?? []) else { return nil }
            return GPATrendPoint(
                term: term,
                semesterGPA: semesterGPA,
                cumulativeGPA: NTUSTGradePoints.gpa(of: report.courses.filter { $0.term <= term })
            )
        }
    }
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
