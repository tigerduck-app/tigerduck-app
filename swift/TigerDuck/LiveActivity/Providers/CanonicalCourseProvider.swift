import Foundation

struct CanonicalCourseProvider {
    private let cache: DataCache

    init(cache: DataCache = .shared) {
        self.cache = cache
    }

    func currentCourses(semester: String = CourseSelectionService.currentSemesterCode()) -> [SDCourse] {
        Self.merge(
            primary: cache.loadCourses(semester: semester),
            userAdded: cache.loadUserAddedCourses(semester: semester),
            semester: semester,
            deletedCourseNos: Set(cache.loadDeletedCourseNos()),
            customNames: cache.loadCourseCustomNamesFlat()
        )
    }

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
