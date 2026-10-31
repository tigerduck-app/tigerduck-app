import Foundation
import os

/// The courses themselves: the newest school roster with the user's own adds and hides.
@MainActor
struct CourseRosterReconciler: CategoryReconciler {
    static let category = "courses"
    unowned let app: AppState

    func reconcile(_ pass: FullSyncPass) -> Bool {
        defer { AppServiceBridge.answerRosterRequests(in: pass.json, authService: app.authService) }
        guard pass.taken.contains("courses") else {
            if pass.policy.pendingChecks.contains("courses") {
                AppLogger.sync.info("[syncOverrides] skipping course sync — conflict check pending")
            }
            return false
        }
        return app.reconcileCourses(
            serverRows: pass.coursesArray, tombstones: pass.json["course_tombstones"] as? [[String: Any]] ?? [],
            deleting: pass.courseDeletes, adding: pass.courseAdds, fetchedAt: pass.fetchedAt
        )
    }
}
