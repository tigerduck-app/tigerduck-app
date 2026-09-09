// Course-colour reassignment — the one action behind "Reassign course
// colors" in Settings.
//
// On `AppState` rather than in the view that offers the button because
// two views now offer it: the iPhone's Other settings and the Mac's
// Appearance tab. The cloud half below is the part a second copy would
// be least likely to remember, and the colours would then disagree
// between the user's devices until the next full sync.

import Defaults
import Foundation

extension AppState {
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
