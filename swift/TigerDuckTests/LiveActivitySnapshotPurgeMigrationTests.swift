// `doneKey` mirrors the migration's flag literal, private per
// swift/TigerDuck/Services/Migrations/AGENTS.md. The flag is real, process-wide state, so the
// suite is `.serialized` and `init` clears it first.
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "LiveActivitySnapshotPurgeMigration.v1.done"

@Suite(.serialized)
struct LiveActivitySnapshotPurgeMigrationTests {
    init() {
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    @Test func deletesTheLeftSnapshotOnce() {
        let suite = "LiveActivitySnapshotPurgeMigrationTests.\(UUID().uuidString)"
        let appGroup = UserDefaults(suiteName: suite)!
        defer {
            UserDefaults().removePersistentDomain(forName: suite)
            UserDefaults.standard.removeObject(forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey)
            UserDefaults.standard.removeObject(forKey: doneKey)
        }
        appGroup.set(Data("snapshot".utf8), forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey)
        UserDefaults.standard.set(Data("fallback".utf8), forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey)

        LiveActivitySnapshotPurgeMigration.runIfNeeded(appGroup: appGroup)

        #expect(appGroup.data(forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey) == nil)
        #expect(UserDefaults.standard.data(forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey) == nil)

        // Done: a later run leaves the key alone, whatever wrote it.
        appGroup.set(Data("later".utf8), forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey)
        LiveActivitySnapshotPurgeMigration.runIfNeeded(appGroup: appGroup)
        #expect(appGroup.data(forKey: LiveActivitySnapshotPurgeMigration.legacySnapshotKey) != nil)
    }
}
