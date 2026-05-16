import Foundation

/// Produces the "canonical" list of courses to reason about: school-portal
/// courses merged with user-added entries, deletions removed, and custom
/// names overlaid. Skip state (`SDCourse.skippedDates`) is per-date and
/// left to consumers to evaluate against the date in question.
///
/// Keeping this logic in one place lets `LiveActivityScenarioResolver` and
/// the reminder scheduler operate on the same source of truth that the
/// class table UI already shows, without pulling in `ClassTableViewModel`'s
/// selection state.
struct CanonicalCourseProvider {
    private let cache: DataCache

    init(cache: DataCache = .shared) {
        self.cache = cache
    }

    /// Returns the canonical course list from the current cache.
    func currentCourses() -> [SDCourse] {
        Self.merge(
            primary: cache.loadCourses(semester: CourseSelectionService.currentSemesterCode()),
            userAdded: cache.loadUserAddedCourses(),
            deletedCourseNos: Set(cache.loadDeletedCourseNos()),
            customNames: cache.loadCourseCustomNames()
        )
    }

    /// Merge function, exposed for unit testing.
    ///
    /// NOTE: `SDCourse` is a SwiftData `@Model` (reference type). The
    /// custom-name overlay sets `customName` (a `@Transient` SwiftData
    /// property) so the canonical `courseName` is never mutated and no
    /// override leaks into persistence. Render `displayName` downstream.
    static func merge(
        primary: [SDCourse],
        userAdded: [SDCourse],
        deletedCourseNos: Set<String>,
        customNames: [String: String]
    ) -> [SDCourse] {
        var merged = primary
        for course in userAdded where !merged.contains(where: { $0.courseNo == course.courseNo }) {
            merged.append(course)
        }
        merged.removeAll { deletedCourseNos.contains($0.courseNo) }
        for course in merged {
            course.customName = customNames[course.courseNo]
        }
        return merged
    }
}
