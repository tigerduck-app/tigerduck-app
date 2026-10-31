import Defaults
import Foundation

extension AppState {
    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool) -> Bool {
        coursesNowOn
    }

    @MainActor
    func reassignAllCourseColors() {
        let semester = CourseSelectionService.currentSemesterCode()
        let courses = CanonicalCourseProvider().currentCourses(semester: semester)
        TigerDuckTheme.reassignAll(courseNos: courses.map(\.courseNo))
        guard Defaults[.cloudSyncEnabled] else { return }
        let colorMap = TigerDuckTheme.snapshot()
        for course in courses {
            guard let hex = colorMap[course.courseNo] else { continue }
            syncCourseOverride(
                moodleCourseId: Self.colorIdentity(of: course, semester: semester),
                colorHex: String(format: "#%06X", hex)
            )
        }
    }

    @MainActor
    func syncColorPick(_ hex: UInt32, for picked: SDCourse, changed: [String: UInt32]) {
        guard Defaults[.cloudSyncEnabled] else { return }
        var colors = changed
        colors[picked.courseNo] = hex & 0xFFFFFF
        let others = colors.count > 1
        let identities = Self.courseIdentities(
            picked: picked,
            termCourses: others
                ? SemesterCatalog.availableSemesters().map { ($0, CourseStore.shared.loadCourses(semester: $0)) } : [],
            userAdded: others ? CourseStore.shared.loadUserAddedCourses() : []
        )
        for override in Self.courseColorOverrides(colors, moodleIds: identities) {
            syncCourseOverride(moodleCourseId: override.moodleId, colorHex: override.colorHex)
        }
    }

    /// How a colour edit names each course, preferring a row with a Moodle id where one course
    /// number has several.
    static func courseIdentities(
        picked: SDCourse,
        termCourses: [(semester: String, courses: [SDCourse])],
        userAdded: [SDCourse]
    ) -> [String: String] {
        let named = [(picked.semester, picked)]
            + termCourses.flatMap { term in term.courses.map { (term.semester, $0) } }
            + userAdded.map { ($0.semester, $0) }
        var ids: [String: String] = [:]
        for (semester, course) in named where ids[course.courseNo] == nil && course.moodleIdNumber?.isEmpty == false {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        for (semester, course) in named where ids[course.courseNo] == nil {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        return ids
    }

    /// The Moodle id number, or the term and the number of a course without one; an empty term is
    /// read as the current one.
    static func colorIdentity(of course: SDCourse, semester: String) -> String {
        OutboxSender.identity(
            semester: semester.isEmpty ? CourseSelectionService.currentSemesterCode() : semester,
            courseNo: course.courseNo, moodleIdNumber: course.moodleIdNumber
        )
    }

    nonisolated static func courseColorOverrides(
        _ colors: [String: UInt32],
        moodleIds: [String: String]
    ) -> [(moodleId: String, colorHex: String)] {
        colors.keys.sorted().compactMap { courseNo in
            guard let moodleId = moodleIds[courseNo], let hex = colors[courseNo] else { return nil }
            return (moodleId, String(format: "#%06X", hex))
        }
    }
}
