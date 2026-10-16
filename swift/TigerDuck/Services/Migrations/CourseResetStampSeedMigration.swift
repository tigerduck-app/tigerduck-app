import Defaults
import Foundation

/// One-shot migration: lets the first full sync since the update apply a full course reset made on
/// another device after this one last synced on 2.3.0 or earlier. Those versions kept this device's
/// clock at each full sync in `lastCourseSyncAt`. Since 2.4.0 a sync compares `courses_reset_at`
/// with the last one a sync read, and with none read yet only records it, which would skip such a
/// reset for good. Keep while a device can still arrive from 2.3.0 or earlier.
enum CourseResetStampSeedMigration {
    private static let doneKey = "CourseResetStampSeedMigration.v1.done"
    private static let legacyKey = "lastCourseSyncAt"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        let lastOldSync = UserDefaults.standard.object(forKey: legacyKey) as? Date
        UserDefaults.standard.removeObject(forKey: legacyKey)
        // Only for the account signed in at the update, which the update records as synced, and
        // before a full sync on this version records the reset it reads. A sign-out clears both
        // keys, but no version cleared the old stamp, which can be another account's.
        guard let lastOldSync, Defaults[.lastSeenCoursesResetAt] == nil,
              !Defaults[.categoriesSyncedOnce].isEmpty else { return }
        Defaults[.lastSeenCoursesResetAt] = lastOldSync
    }
}
