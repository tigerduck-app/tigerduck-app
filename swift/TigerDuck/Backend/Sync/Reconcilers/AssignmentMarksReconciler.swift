import Foundation
import os

/// The marks of a snapshot against this device's: a mark on one side only is taken, one queued
/// here is kept, and one the two sides disagree on is asked about.
@MainActor
struct AssignmentMarksReconciler: CategoryReconciler {
    let category = "assignments"
    unowned let app: AppState
    var assignments: AssignmentStore = .shared

    func reconcile(_ pass: FullSyncPass) -> Bool {
        if let reason = pass.marksLeftFor {
            AppLogger.sync.info("[syncOverrides] skipping assignment overrides — \(reason.rawValue, privacy: .public)")
            return false
        }
        let conflicts = Self.conflicts(
            server: pass.marks, localArchived: pass.localArchived, localCompleted: pass.localCompleted,
            protected: pass.protected, titles: assignmentTitles()
        )
        let conflictIds = Set(conflicts.map(\.id))
        let currentArchived = assignments.loadArchivedAssignmentIds()
        let currentCompleted = assignments.loadLocallyCompletedAssignmentIds()
        var safeArchived = AppState.mergedMarks(
            server: pass.marks.archived.subtracting(conflictIds), local: currentArchived, protected: pass.protected
        )
        var safeCompleted = AppState.mergedMarks(
            server: pass.marks.completed.subtracting(conflictIds), local: currentCompleted, protected: pass.protected
        )
        for conflict in conflicts {
            switch conflict.localStatus {
            case "ignored", "archived": safeArchived.insert(conflict.id)
            case "locally_completed": safeCompleted.insert(conflict.id)
            default: break
            }
        }
        var changed = false
        if safeArchived != currentArchived {
            assignments.replaceArchivedAssignmentIds(safeArchived)
            changed = true
        }
        if safeCompleted != currentCompleted {
            assignments.replaceLocallyCompletedAssignmentIds(safeCompleted)
            changed = true
        }
        AppLogger.sync.info("applied: \(safeArchived.count, privacy: .public) archived, \(safeCompleted.count, privacy: .public) completed, \(conflicts.count, privacy: .public) conflicts pending")
        if !conflicts.isEmpty {
            app.syncConflicts = conflicts
        }
        return changed
    }

    private func assignmentTitles() -> [String: String] {
        Dictionary(
            assignments.loadAssignments().map { ($0.assignmentId, $0.displayTitle) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The marks both sides hold and disagree on; a mark queued here is not one.
    static func conflicts(
        server: ServerMarks, localArchived: Set<String>, localCompleted: Set<String>,
        protected: Set<String>, titles: [String: String]
    ) -> [AppState.SyncConflictItem] {
        let ids = server.archived.union(server.completed).union(localArchived).union(localCompleted)
        return ids.sorted().compactMap { id -> AppState.SyncConflictItem? in
            guard !protected.contains(id) else { return nil }
            let serverStatus = server.archived.contains(id) ? "ignored"
                : server.completed.contains(id) ? "locally_completed" : "none"
            let localStatus = localArchived.contains(id) ? "ignored"
                : localCompleted.contains(id) ? "locally_completed" : "none"
            guard serverStatus != localStatus, localStatus != "none", serverStatus != "none" else { return nil }
            return AppState.SyncConflictItem(
                id: id, kind: String(localized: "live_activity_status_assignment_short"),
                label: titles[id] ?? "ID \(id)", localStatus: localStatus, serverStatus: serverStatus
            )
        }
    }

    /// Keeps the server's side of the marks the user was asked about. The backend is read again
    /// first: another device may have changed a mark since the question was asked. A sign-out
    /// meanwhile leaves the next account's marks alone.
    static func keepServerSide(
        read: () async throws -> ServerMarks,
        protected: () async -> Set<String>,
        isCurrent: () -> Bool,
        assignments: AssignmentStore
    ) async {
        guard let server = try? await read() else {
            AppLogger.sync.info("[syncConflicts] server marks unreadable; marks left as they are")
            return
        }
        let protected = await protected()
        guard isCurrent() else { return }
        assignments.replaceArchivedAssignmentIds(AppState.mergedMarks(
            server: server.archived, local: assignments.loadArchivedAssignmentIds(), protected: protected
        ))
        assignments.replaceLocallyCompletedAssignmentIds(AppState.mergedMarks(
            server: server.completed, local: assignments.loadLocallyCompletedAssignmentIds(), protected: protected
        ))
    }
}
