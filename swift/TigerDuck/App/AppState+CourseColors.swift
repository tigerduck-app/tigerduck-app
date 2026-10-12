// "Reassign course colors" lives on `AppState` because the iPhone's Other settings and the Mac's
// Appearance tab both offer it. A second copy would most likely forget the cloud half, and the
// user's devices would then disagree on colours until the next full sync.

import Defaults
import Foundation

extension AppState {
    /// Course colours follow course sync both ways: they stay on only while course sync
    /// is on, and turning course sync on brings them back. `SyncContentSettingsView` (iOS)
    /// and `MacTigerSyncSettingsView` (macOS) call this from their `syncCourses` change
    /// handlers, so the disabled colours row cannot read on while `applyCourseOverrides`
    /// keeps applying server colours. It lives here, built for both platforms, because
    /// each view builds for one only. Static and taking a `Bool` so a test can call it
    /// without `Defaults` or a view; this codebase has no SwiftUI view inspection.
    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool) -> Bool {
        coursesNowOn
    }

    /// Rebuild every course's colour from scratch with the unique-colour
    /// algorithm, then broadcast so Home, the class table, the widgets and
    /// the Live Activity all pick up the new palette.
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

    /// PATCHes a colour pick: the picked course, and the new colour of each course the pick
    /// moved off it (`changed`, from `TigerDuckTheme.setColor`), which the server would otherwise
    /// keep on the picked colour too. A course with no Moodle id, a manual one, has no override.
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

    /// The picked course's own id first, then the cached terms', newest first, then the manual and
    /// merged rows: a row merged from another device's upload carries a Moodle id too.
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
