import Foundation

enum LiveActivitySnapshotPurgeMigration {
    static let legacySnapshotKey = "LA-current-snapshot-v1"

    private static let doneKey = "LiveActivitySnapshotPurgeMigration.v1.done"

    static func runIfNeeded(
        appGroup: UserDefaults? = AppUserDefaults.suite("group.org.ntust.app.TigerDuck")
    ) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        appGroup?.removeObject(forKey: legacySnapshotKey)
        AppUserDefaults.standard.removeObject(forKey: legacySnapshotKey)
        AppUserDefaults.standard.set(true, forKey: doneKey)
    }
}
