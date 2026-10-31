import Foundation

/// The school's terms and course numbers, as the course screens offer and check them.
nonisolated enum SchoolTerms {
    /// The term in session today, or the one the calendar estimates.
    static var current: String { CourseSelectionService.currentSemesterCode() }

    /// The terms the class table offers, newest first.
    static func available() -> [String] { SemesterCatalog.availableSemesters() }

    /// The term picked before, or else the newest term on offer, or else the current one.
    static func selected(storedPick: String?) -> String {
        SemesterCatalog.selectedSemester(storedPick: storedPick)
    }

    static func isCourseNo(_ text: Substring) -> Bool { CourseSelectionService.isCourseNo(text) }
}
