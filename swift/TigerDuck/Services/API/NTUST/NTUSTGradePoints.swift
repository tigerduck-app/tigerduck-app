import Foundation

nonisolated enum NTUSTGradePoints {
    static let byLetter: [String: Double] = [
        "A+": 4.3, "A": 4.0, "A-": 3.7,
        "B+": 3.3, "B": 3.0, "B-": 2.7,
        "C+": 2.3, "C": 2.0, "C-": 1.7,
        "D": 1.0, "E": 0.0, "X": 0.0,
    ]

    static func points(forGrade raw: String) -> Double? {
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
