// Cached-course relabeling sweep — split out of AppState.swift.
//
// Triggered by the course/classroom-abbreviation and Mandarin-display
// toggles' `didSet` (still on the class itself, since the toggles are
// stored properties). Walks the per-semester course cache plus the
// user-added courses and rewrites display labels in place. `relabelTask`
// — the in-flight-task guard this cancels/reassigns — stays a stored
// property on `AppState` for the same reason; only the sweep logic moved
// here, so both `relabelAllCachedCourses` and `relabelTask` widened from
// `private` to internal.

import SwiftUI
import Defaults

extension AppState {

    /// Re-derive course/classroom labels for every cached semester using the
    /// current toggle settings, then post `dataDidUpdate` so visible views
    /// reload from the freshly relabeled cache. Lives on `AppState` so the
    /// relabel still runs when no `ClassTableViewModel` is alive (e.g., the
    /// user toggled in Settings without ever opening the Class Table tab).
    ///
    /// Runs on a detached task so disk I/O (up to four cached semesters plus
    /// user-added courses, plus a first-call JSON parse inside
    /// ``NameAbbrService``) does not block the UI thread when the toggle is
    /// flipped from a Settings view. Rapid toggling cancels the previous task
    /// so the latest settings always win the save race.
    func relabelAllCachedCourses() {
        relabelTask?.cancel()
        // `Task.detached` lets the loop body yield to the runtime between
        // iterations, so a long relabel sweep doesn't pin the MainActor.
        // The actual disk/SwiftData work hops to MainActor per iteration
        // because `DataCache` and `NameAbbrService.relabelInPlace` touch
        // SwiftData-managed types that are themselves MainActor-isolated.
        relabelTask = Task.detached(priority: .userInitiated) {
            let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
            let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
            let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

            var anyChanged = false
            var code = CourseSelectionService.currentSemesterCode()
            var consecutiveEmpty = 0
            for _ in 0..<AppConstants.cachedSemesterRelabelDepth {
                if Task.isCancelled { return }
                // Snapshot `code` into a `let` so the Sendable closure passed
                // to `MainActor.run` captures an immutable value — Swift 6
                // rejects capturing the mutating outer `var` from a
                // concurrently-executing context.
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
                    // Re-check cancellation inside the MainActor body: a
                    // newer toggle can have cancelled this task while it
                    // was queued for the main actor, and persisting now
                    // would clobber the newer task's save with stale
                    // toggle values captured at the top of this closure.
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
