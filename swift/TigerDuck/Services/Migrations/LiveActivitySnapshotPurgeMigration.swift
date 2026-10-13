import Foundation

/// One-shot migration: deletes the Live Activity snapshot the removed `SharedSnapshotStore`
/// left in the App Group defaults. Nothing reads it any more, and nothing clears it at sign-out
/// as `LiveActivityCoordinator.endAll()` did, so the last class or assignment shown would stay.
/// The store fell back to `.standard` when the group was unreachable, so both are cleared.
enum LiveActivitySnapshotPurgeMigration {
    /// The removed store's key, copied because the type is gone.
    static let legacySnapshotKey = "LA-current-snapshot-v1"

    private static let doneKey = "LiveActivitySnapshotPurgeMigration.v1.done"

    static func runIfNeeded(
        appGroup: UserDefaults? = UserDefaults(suiteName: "group.org.ntust.app.TigerDuck")
    ) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        appGroup?.removeObject(forKey: legacySnapshotKey)
        UserDefaults.standard.removeObject(forKey: legacySnapshotKey)
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
