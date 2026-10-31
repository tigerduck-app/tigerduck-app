import Defaults
import Foundation
import os

/// The courses whose assignments the user hides, against the snapshot's.
@MainActor
struct CourseIgnoresReconciler: CategoryReconciler {
    let category = "course_ignores"
    unowned let app: AppState

    func reconcile(_ pass: FullSyncPass) -> Bool {
        guard pass.marksLeftFor == nil, let server = pass.serverIgnoredCourses, Defaults[.syncCourses] else {
            return false
        }
        return app.applyIgnoredCourses(
            server, decided: AppState.serverDecidedCourses(pass.courseOverrides),
            coursesArray: pass.coursesArray, protected: pass.protected, deleting: pass.courseDeletes,
            fetchedAt: pass.fetchedAt
        )
    }
}
