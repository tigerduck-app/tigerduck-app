import Foundation
import os

/// Course colours and names, each while its switch is on and no edit of it is queued here.
@MainActor
struct CourseOverridesReconciler: CategoryReconciler {
    let category = "course_overrides"
    unowned let app: AppState

    func reconcile(_ pass: FullSyncPass) -> Bool {
        let colors = pass.taken.contains("course_colors")
        let names = pass.taken.contains("course_names")
        guard colors || names else {
            AppLogger.sync.info("[syncOverrides] skipping course overrides — switched off or conflict check pending")
            return false
        }
        guard !pass.courseOverrides.isEmpty else { return false }
        return app.applyCourseOverrides(
            pass.courseOverrides, coursesArray: pass.coursesArray, colors: colors, names: names,
            holdingColors: pass.heldCourseOverrides.colors, holdingNames: pass.heldCourseOverrides.names
        )
    }
}
