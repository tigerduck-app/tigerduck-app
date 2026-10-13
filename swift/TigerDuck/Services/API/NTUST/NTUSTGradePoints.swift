import Foundation

/// NTUST letter-grade points from Appendix Table 1 of the school's student academic grade
/// guidelines: the column for students admitted from academic year 105 on (A+ = 4.3).
/// Transcripts have carried letter grades since academic year 100; the percentage bands
/// below are the same table's percentage ranges, for the odd numeric entry.
///
/// ponytail: students admitted 100–104 had A+ = 4.0. They have long
/// graduated; if one ever shows up, key the table off the student id year.
nonisolated enum NTUSTGradePoints {
    static let byLetter: [String: Double] = [
        "A+": 4.3, "A": 4.0, "A-": 3.7,
        "B+": 3.3, "B": 3.0, "B-": 2.7,
        "C+": 2.3, "C": 2.0, "C-": 1.7,
        "D": 1.0, "E": 0.0, "X": 0.0,
    ]

    /// Grade points for a transcript grade cell, or nil when the cell is
    /// not a grade (pass/fail, a grade not yet posted, empty).
    static func points(forGrade raw: String) -> Double? {
        // Full-width letters and signs ("Ｂ＋") come through some exports;
        // fold them to ASCII before matching.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let grade = (trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed).uppercased()
        if let points = byLetter[grade] { return points }
        guard let score = Double(grade) else { return nil }
        switch score {
        case 90...: return 4.3
        case 85..<90: return 4.0
        case 80..<85: return 3.7
        case 77..<80: return 3.3
        case 73..<77: return 3.0
        case 70..<73: return 2.7
        case 67..<70: return 2.3
        case 63..<67: return 2.0
        case 60..<63: return 1.7
        case 50..<60: return 1.0
        default: return 0.0
        }
    }

    /// Credit-weighted average over the courses that already have a
    /// grade; nil while nothing is gradable yet. Pass/fail, exempted,
    /// withdrawn and pending rows carry no grade points and drop out.
    /// ponytail: every graded course counts, including `.notCounted` credits.
    /// The school's inclusion rule is unpublished; adjust here if the
    /// official figure disagrees.
    static func gpa(of courses: [CourseGrade]) -> Double? {
        var weighted = 0.0
        var credits = 0.0
        for course in courses where course.status == .graded {
            guard let credit = course.credits, credit > 0,
                  let points = points(forGrade: course.grade) else { continue }
            weighted += points * credit
            credits += credit
        }
        return credits > 0 ? weighted / credits : nil
    }
}
