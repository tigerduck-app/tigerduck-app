import Foundation
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class MarkConflicts {
    var items: [SyncConflicts.SyncConflictItem] = []
    @ObservationIgnored private weak var app: AppEnvironment?

    init(app: AppEnvironment) {
        self.app = app
    }

    var alertMessage: String {
        let lines = items.map { item in
            "• " + String(format: String(localized: "sync_conflict_item_header"), item.kind, item.label)
                + "\n  " + String(format: String(localized: "sync_conflict_item_detail"), item.localLabel, item.serverLabel)
        }
        return ([String(localized: "sync_conflict_message")] + lines).joined(separator: "\n")
    }

    func resolve(keepLocal: Bool) {
        defer { items = [] }
        guard let app else { return }
        let signIn = app.authService.session.currentSignIn
        if keepLocal {
            for c in items {
                app.edits.syncAssignmentOverride(moodleId: c.id, status: c.localStatus, for: signIn)
            }
        } else {
            let coordinator = app.cloudSyncCoordinator
            let push = app.pushCoordinator
            Task { [weak self] in
                await AssignmentMarksReconciler.keepServerSide(
                    read: { ServerMarks(try await push.fetchFullSync()) },
                    protected: { [weak self] in
                        await coordinator.pendingAssignmentOverrideIds().union(self?.app?.localEdits.pendingOverrides ?? [])
                    },
                    for: signIn,
                    assignments: .shared
                )
            }
        }
    }

    var alertIsPresented: Binding<Bool> { Self.alertIsPresented(Bindable(self).items) }

    static func alertIsPresented(_ conflicts: Binding<[SyncConflicts.SyncConflictItem]>) -> Binding<Bool> {
        Binding(
            get: { !conflicts.wrappedValue.isEmpty },
            set: { isPresented in
                guard !isPresented, !conflicts.wrappedValue.isEmpty else { return }
                AppLogger.sync.info("[syncConflicts] alert closed unanswered, marks left as they are")
                conflicts.wrappedValue = []
            }
        )
    }
}
