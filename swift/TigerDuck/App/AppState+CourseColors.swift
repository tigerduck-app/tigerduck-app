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
}
