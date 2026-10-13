import Foundation

/// Produces the canonical course list: school-portal courses merged with
/// user-added ones, deletions removed, custom names overlaid. Skip state
/// (`SDCourse.skippedDates`) is per-date, so consumers check it against the
/// date in question.
///
/// One place lets `LiveActivityScenarioResolver` and the reminder scheduler
/// work from what the class table shows, without `ClassTableViewModel`'s
/// selection state.
struct CanonicalCourseProvider {
    private let cache: DataCache

    init(cache: DataCache = .shared) {
        self.cache = cache
    }

    /// Returns the canonical course list from the current cache.
    func currentCourses() -> [SDCourse] {
        let semester = CourseSelectionService.currentSemesterCode()
        return Self.merge(
            primary: cache.loadCourses(semester: semester),
            userAdded: cache.loadUserAddedCourses(semester: semester),
            semester: semester,
            deletedCourseNos: Set(cache.loadDeletedCourseNos()),
            customNames: cache.loadCourseCustomNamesFlat()
        )
    }

    /// Merge function, exposed for unit testing.
    ///
    /// `SDCourse` is a SwiftData `@Model`, a reference type. The custom-name
    /// overlay sets the `@Transient` `customName`, so `courseName` is never
    /// mutated and no override reaches persistence. Render `displayName` downstream.
    ///
    /// `deletedCourseNos` is the raw tombstone set (see `CourseTombstone`);
    /// `semester` scopes which entries apply.
    static func merge(
        primary: [SDCourse],
        userAdded: [SDCourse],
        semester: String,
        deletedCourseNos: Set<String>,
        customNames: [String: String]
    ) -> [SDCourse] {
        var merged = primary
        for course in userAdded where !merged.contains(where: { $0.courseNo == course.courseNo }) {
            merged.append(course)
        }
        merged.removeAll { CourseTombstone.isHidden($0.courseNo, semester: semester, in: deletedCourseNos) }
        for course in merged {
            course.customName = customNames[course.courseNo]
        }
        return merged
    }
}
