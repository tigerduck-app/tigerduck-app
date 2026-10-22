import Foundation
import Defaults

extension AppState {

    struct SyncConflictItem: Identifiable {
        let id: String
        let kind: String
        let label: String
        let localStatus: String
        let serverStatus: String

        var localLabel: String { Self.statusLabel(localStatus) }
        var serverLabel: String { Self.statusLabel(serverStatus) }

        private static func statusLabel(_ status: String) -> String {
            switch status {
            case "ignored", "archived": return String(localized: "sync_conflict_status_ignored")
            case "locally_completed": return String(localized: "sync_conflict_status_completed")
            default: return String(localized: "sync_conflict_status_none")
            }
        }
    }

    enum SyncSource { case none, backend, local }

}
