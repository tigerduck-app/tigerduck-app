import Foundation

enum LiveActivitySnapshotPurgeMigration {
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
