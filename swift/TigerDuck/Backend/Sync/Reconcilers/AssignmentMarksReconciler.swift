import Foundation
import os

@MainActor
struct AssignmentMarksReconciler: CategoryReconciler {
    static let category = "assignments"
    unowned let resolver: SyncConflicts
    var assignments: AssignmentStore = .shared

    init(app: AppEnvironment) {
        resolver = app.conflicts
    }

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
        var safeArchived = Self.mergedMarks(
            server: pass.marks.archived.subtracting(conflictIds), local: currentArchived, protected: pass.protected
        )
        var safeCompleted = Self.mergedMarks(
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
            assignments.replaceArchivedAssignmentIds(safeArchived, for: pass.signIn)
            changed = true
        }
        if safeCompleted != currentCompleted {
            assignments.replaceLocallyCompletedAssignmentIds(safeCompleted, for: pass.signIn)
            changed = true
        }
        AppLogger.sync.info("applied: \(safeArchived.count, privacy: .public) archived, \(safeCompleted.count, privacy: .public) completed, \(conflicts.count, privacy: .public) conflicts pending")
        if !conflicts.isEmpty {
            resolver.syncConflicts = conflicts
        }
        return changed
    }

    private func assignmentTitles() -> [String: String] {
        Dictionary(
            assignments.loadAssignments().map { ($0.assignmentId, $0.displayTitle) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func conflicts(
        server: ServerMarks, localArchived: Set<String>, localCompleted: Set<String>,
        protected: Set<String>, titles: [String: String]
    ) -> [SyncConflicts.SyncConflictItem] {
        let ids = server.archived.union(server.completed).union(localArchived).union(localCompleted)
        return ids.sorted().compactMap { id -> SyncConflicts.SyncConflictItem? in
            guard !protected.contains(id) else { return nil }
            let serverStatus = server.archived.contains(id) ? "ignored"
                : server.completed.contains(id) ? "locally_completed" : "none"
            let localStatus = localArchived.contains(id) ? "ignored"
                : localCompleted.contains(id) ? "locally_completed" : "none"
            guard serverStatus != localStatus, localStatus != "none", serverStatus != "none" else { return nil }
            return SyncConflicts.SyncConflictItem(
                id: id, kind: String(localized: "live_activity_status_assignment_short"),
                label: titles[id] ?? "ID \(id)", localStatus: localStatus, serverStatus: serverStatus
            )
        }
    }

    static func keepServerSide(
        read: () async throws -> ServerMarks,
        protected: () async -> Set<String>,
        for signIn: SignIn,
        assignments: AssignmentStore
    ) async {
        guard let server = try? await read() else {
            AppLogger.sync.info("[syncConflicts] server marks unreadable; marks left as they are")
            return
        }
        let protected = await protected()
        assignments.replaceArchivedAssignmentIds(Self.mergedMarks(
            server: server.archived, local: assignments.loadArchivedAssignmentIds(), protected: protected
        ), for: signIn)
        assignments.replaceLocallyCompletedAssignmentIds(Self.mergedMarks(
            server: server.completed, local: assignments.loadLocallyCompletedAssignmentIds(), protected: protected
        ), for: signIn)
    }

    nonisolated static func mergedMarks(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>
    ) -> Set<String> {
        server.subtracting(protected).union(local.intersection(protected))
    }

    nonisolated static func assignmentMarksToClear(server: Set<String>, local: Set<String>) -> Set<String> {
        server.subtracting(local)
    }
}
