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
    /// Spec §6's course-sync → course-colours dependency: colours can only
    /// stay on while course sync is also on. `SyncContentSettingsView`
    /// (iOS) and `MacAccountSettingsView` (macOS) each call this from
    /// their own `syncCourses` change handler, so a user turning courses
    /// off can't leave the now-`.disabled` colours row stuck reading ON
    /// while `applyCourseOverrides` (`AppState+BackendSync.swift`) keeps
    /// applying server colours underneath it.
    ///
    /// Lives here — not on either settings view — because it must compile
    /// for both platforms: this file is on both platforms'
    /// `INCLUDED_SOURCE_FILE_NAMES` allowlists (`project.pbxproj`), while
    /// `SyncContentSettingsView.swift` is iOS-only (excluded from the
    /// macOS build entirely, not merely unreached at runtime) and
    /// `MacAccountSettingsView.swift` is macOS-only. `static` and a
    /// function of the raw `Bool`s, rather than logic embedded only in an
    /// `onChange` closure, so a test can drive it directly without
    /// touching `Defaults` or rendering a view — this codebase has no
    /// SwiftUI view-inspection facility.
    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool, coloursCurrentlyOn: Bool) -> Bool {
        coursesNowOn ? coloursCurrentlyOn : false
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
