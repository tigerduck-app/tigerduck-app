import SwiftUI

extension View {
    func syncConflictAlert(_ app: AppEnvironment) -> some View {
        alert(
            String(localized: "sync_conflict_title"),
            isPresented: app.conflicts.alertIsPresented
        ) {
            Button(String(localized: "sync_conflict_use_server")) { app.conflicts.resolveSyncConflicts(keepLocal: false) }
            Button(String(localized: "sync_conflict_use_local")) { app.conflicts.resolveSyncConflicts(keepLocal: true) }
        } message: {
            Text(app.conflicts.syncConflictAlertMessage)
        }
    }
}
