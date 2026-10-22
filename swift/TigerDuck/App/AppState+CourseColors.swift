import Defaults
import Foundation

extension AppState {
    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool) -> Bool {
        coursesNowOn
    }

    @MainActor
    func reassignAllCourseColors() {
        let courses = CanonicalCourseProvider().currentCourses()
        TigerDuckTheme.reassignAll(courseNos: courses.map(\.courseNo))
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        guard Defaults[.cloudSyncEnabled] else { return }
        let colorMap = TigerDuckTheme.snapshot()
        for course in courses {
            guard let moodleId = course.moodleIdNumber,
                  let hex = colorMap[course.courseNo]
            else { continue }
            syncCourseOverride(
                moodleCourseId: moodleId,
                colorHex: String(format: "#%06X", hex)
            )
        }
    }

    @MainActor
    func syncColorPick(_ hex: UInt32, for picked: SDCourse, changed: [String: UInt32]) {
        guard Defaults[.cloudSyncEnabled] else { return }
        var colors = changed
        colors[picked.courseNo] = hex & 0xFFFFFF
        let moodleIds = colors.count > 1
            ? Self.moodleIdsByCourseNo(
                picked: picked,
                termCourses: SemesterCatalog.availableSemesters().flatMap { DataCache.shared.loadCourses(semester: $0) },
                userAdded: DataCache.shared.loadUserAddedCourses()
            )
            : Self.moodleIdsByCourseNo(picked: picked, termCourses: [], userAdded: [])
        for override in Self.courseColorOverrides(colors, moodleIds: moodleIds) {
            syncCourseOverride(moodleCourseId: override.moodleId, colorHex: override.colorHex)
        }
    }

    static func moodleIdsByCourseNo(
        picked: SDCourse,
        termCourses: [SDCourse],
        userAdded: [SDCourse]
    ) -> [String: String] {
        var ids: [String: String] = [:]
        for course in [picked] + termCourses + userAdded where ids[course.courseNo] == nil {
            ids[course.courseNo] = course.moodleIdNumber
        }
        return ids
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
