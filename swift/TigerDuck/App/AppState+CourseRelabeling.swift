// Relabels cached courses when a course or classroom abbreviation or Mandarin-display toggle
// changes. Stored properties stay on the class: the toggles with their `didSet`, and `relabelTask`.
// The sweep rewrites the per-semester course cache and the user-added courses in place.

import SwiftUI
import Defaults

extension AppState {

    /// Re-derive course and classroom labels for every cached semester from the
    /// current toggles, then post `dataDidUpdate` so visible views reload. Lives
    /// on `AppState` so it runs even when no `ClassTableViewModel` exists.
    ///
    /// Runs on a detached task so the disk I/O (up to four cached semesters plus
    /// user-added courses, and ``NameAbbrService``'s first-call JSON parse) does
    /// not block the UI when a Settings toggle flips. A new call cancels the
    /// previous task so the latest settings win the save race.
    func relabelAllCachedCourses() {
        relabelTask?.cancel()
        // Detached so a long sweep yields between iterations instead of pinning the main actor.
        // Each iteration's disk and SwiftData work hops to the main actor, because `DataCache` and
        // `NameAbbrService.relabelInPlace` touch MainActor-isolated SwiftData types.
        relabelTask = Task.detached(priority: .userInitiated) {
            let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
            let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
            let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

            var anyChanged = false
            var code = CourseSelectionService.currentSemesterCode()
            var consecutiveEmpty = 0
            for _ in 0..<AppConstants.cachedSemesterRelabelDepth {
                if Task.isCancelled { return }
                // A `let` copy for the Sendable `MainActor.run` closure: Swift 6 rejects
                // capturing the mutating outer `var` from concurrently executing code.
                let semesterCode = code
                let iter = await MainActor.run { () -> (changed: Bool, wasEmpty: Bool) in
                    let courses = DataCache.shared.loadCourses(semester: semesterCode)
                    if courses.isEmpty { return (false, true) }
                    let changed = NameAbbrService.shared.relabelInPlace(
                        courses,
                        courseAbbrEnabled: courseAbbrEnabled,
                        classroomAbbrEnabled: classroomAbbrEnabled,
                        classroomMandarinDisplay: classroomMandarinDisplay
                    )
                    // Re-check cancellation on the main actor: a newer toggle may have cancelled
                    // this task while it waited there, and saving now would overwrite the newer
                    // task's save with the stale toggle values captured above.
                    if changed && !Task.isCancelled {
                        DataCache.shared.saveCourses(courses, semester: semesterCode)
                    }
                    return (changed, false)
                }
                if iter.wasEmpty {
                    consecutiveEmpty += 1
                    // Two empty semesters in a row means we've walked past any
                    // data the user has fetched; further iterations just hit
                    // disk for nothing.
                    if consecutiveEmpty >= 2 { break }
                } else {
                    consecutiveEmpty = 0
                }
                if iter.changed { anyChanged = true }
                code = CourseSelectionService.previousSemesterCode(code)
            }

            // User-added courses live in their own file, outside the per-semester
            // fetch cache, so the loop above never sees them. Relabel separately
            // so manually-added Mandarin classrooms also honor the display toggle.
            if Task.isCancelled { return }
            let userChanged = await MainActor.run { () -> Bool in
                let userAdded = DataCache.shared.loadUserAddedCourses()
                guard !userAdded.isEmpty else { return false }
                let changed = NameAbbrService.shared.relabelInPlace(
                    userAdded,
                    courseAbbrEnabled: courseAbbrEnabled,
                    classroomAbbrEnabled: classroomAbbrEnabled,
                    classroomMandarinDisplay: classroomMandarinDisplay
                )
                // Same rationale as the per-semester save above: skip the
                // write if a newer relabel has already superseded this one.
                if changed && !Task.isCancelled {
                    DataCache.shared.saveUserAddedCourses(userAdded)
                }
                return changed
            }
            if userChanged { anyChanged = true }

            if anyChanged && !Task.isCancelled {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: AppConstants.dataDidUpdate, object: nil
                    )
                }
            }
        }
    }

}
