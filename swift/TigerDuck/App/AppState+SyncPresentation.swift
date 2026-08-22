// Sync/conflict presentation types — split out of AppState.swift.
//
// `SyncConflictItem` and `SyncSource` back the stored `syncConflicts` /
// `lastSyncSource` properties that have to stay on the class itself
// (Observation tracking, and extensions can't hold stored properties);
// this file only holds the type declarations and the read-only
// `isSyncLocalOnly` derivation over them. Conflict *resolution* logic
// lives in AppState+Conflicts.swift.

import SwiftUI
import SwiftData
import Defaults
import os

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

    var isSyncLocalOnly: Bool { Defaults[.cloudSyncEnabled] && lastSyncSource == .local }

}
